import AVFoundation
import Photos
import ShrinkCore
import SwiftUI

/// Free up space: finds the videos in the library worth shrinking, keeps the person's picks, and
/// (FreeUpSpaceRun.swift) shrinks them, saves the copies and sends the originals to Recently Deleted.
@Observable
@MainActor
final class FreeUpSpace {
    enum Access { case notAsked, denied, limited, full }
    enum Scan { case notStarted, running(checked: Int, total: Int), finished }

    var access: Access = FreeUpSpace.currentAccess()
    var scan: Scan = .notStarted
    /// The shrinking itself, once started from "Check before shrinking".
    var run: Run = .idle
    var runTask: Task<Void, Never>?
    /// Originals whose copies are saved but which are still in the library (iOS asked, they said no).
    /// Kept across launches so they're never shrunk twice, and Home can offer to move them.
    var pendingOriginals: [PendingOriginal] {
        get { pendingList }
        set {
            pendingList = newValue
            PendingStore.save(newValue)
        }
    }
    private var pendingList: [PendingOriginal] = PendingStore.load()
    /// The batch being shrunk: what's left, and what happened so far. Saved after every video, so a
    /// batch stopped by closing the app (or by iPhone) carries on with "Keep going".
    var queue: RunQueue? {
        get { queueValue }
        set {
            queueValue = newValue
            RunQueue.save(newValue)
        }
    }
    private var queueValue: RunQueue? = RunQueue.load()
    /// iOS 26's background run for the current batch, when iPhone allowed one.
    var continued: ContinuedRun?
    /// Why the run task was cancelled: Stop (the rest are dropped) or a pause (they wait).
    @ObservationIgnored var cancelReason: CancelReason?
    /// Set when Shrink leaves the screen during a video, so a failure then means "interrupted", not "broken".
    @ObservationIgnored var leftDuringVideo = false
    @ObservationIgnored var appStateObservers: [NSObjectProtocol] = []
    /// Set when a finished run closes: Home pops back to itself (and may ask for a review).
    var requestsHome = false
    /// What the last finished run freed, read by Home when it closes.
    var lastRunFreed: Int64 = 0
    /// Worth shrinking at the current size, biggest first.
    private(set) var videos: [LibraryVideo] = []
    var picked: Set<String> = []
    /// What the videos filmed since the last scan could free.
    private(set) var newSinceLastTime: Int64 = 0
    /// 1080p or Keep 4K, remembered. Changing it changes every estimate.
    var size: LibraryPlanner.Size {
        get { sizeChoice }
        set {
            sizeChoice = newValue
            AppSettings.defaults.set(newValue.rawValue, forKey: Self.sizeKey)
            refilter()
        }
    }

    private var sizeChoice: LibraryPlanner.Size = FreeUpSpace.savedSize()
    /// Everything the scan found with a known size, before deciding what's worth it.
    private var scanned: [ScannedVideo] = []
    /// A frozen copy for CI screenshots: never reads the library or the real access.
    private(set) var isPreview = false
    nonisolated private static let sizeKey = "freeUpSize"
    nonisolated private static let lastScanKey = "lastLibraryScan"

    nonisolated private static func savedSize() -> LibraryPlanner.Size {
        LibraryPlanner.Size(rawValue: AppSettings.defaults.string(forKey: sizeKey) ?? "") ?? .hd
    }

    var totalSaving: Int64 { videos.reduce(0) { $0 + $1.saving } }
    var pickedVideos: [LibraryVideo] { videos.filter { picked.contains($0.id) } }
    var pickedSaving: Int64 { pickedVideos.reduce(0) { $0 + $1.saving } }
    var allPicked: Bool { !videos.isEmpty && picked.count == videos.count }
    /// What a run will shrink: everything picked with Pro, otherwise what fits in the free allowance.
    var plannedVideos: [LibraryVideo] { FreeAllowance.fitting(pickedVideos) }
    var plannedSaving: Int64 { plannedVideos.reduce(0) { $0 + $1.saving } }
    /// Picked more than the free allowance covers (and no Pro).
    var isOverAllowance: Bool { !Store.shared.isPro && pickedSaving > FreeAllowance.leftBytes }

    func toggle(_ id: String) {
        if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
    }

    func pickAll() { picked = Set(videos.map(\.id)) }
    func clearPicks() { picked.removeAll() }

    /// After a run: what was shrunk leaves the list (its copy is excluded from later scans).
    func removeFromList(_ ids: Set<String>) {
        scanned.removeAll { ids.contains($0.id) }
        picked.subtract(ids)
        refilter()
    }

    // MARK: - Access

    func refreshAccess() {
        guard !isPreview else { return }
        access = Self.currentAccess()
    }

    /// When Home shows: re-read access (it may have changed in Settings) and scan once it's allowed.
    func refreshAndScanIfNeeded() async {
        refreshAccess()
        guard access == .full || access == .limited, case .notStarted = scan else { return }
        await scanLibrary()
    }

    func requestAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        access = Self.access(for: status)
    }

    nonisolated static func currentAccess() -> Access {
        access(for: PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    nonisolated private static func access(for status: PHAuthorizationStatus) -> Access {
        switch status {
        case .authorized: return .full
        case .limited: return .limited
        case .notDetermined: return .notAsked
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    // MARK: - Scan

    /// Reads every video's size and date (no pixels), so it takes seconds even for thousands.
    func scanLibrary() async {
        guard !isPreview, access == .full || access == .limited else { return }
        if case .running = scan { return }
        scan = .running(checked: 0, total: 0)
        let excluded = ShrunkCopies.ids.union(pendingOriginals.map(\.id))
        let found = await Task.detached(priority: .userInitiated) {
            Self.readLibrary(excluding: excluded) { checked, total in
                Task { @MainActor [weak self] in self?.scan = .running(checked: checked, total: total) }
            }
        }.value
        scanned = found
        refilter()
        let lastScan = AppSettings.defaults.object(forKey: Self.lastScanKey) as? Date
        newSinceLastTime = lastScan.map { since in
            videos.filter { ($0.created ?? .distantPast) > since }.reduce(0) { $0 + $1.saving }
        } ?? 0
        AppSettings.defaults.set(Date(), forKey: Self.lastScanKey)
        picked = picked.intersection(videos.map(\.id))
        scan = .finished
    }

    private func refilter() {
        let hevc = LibraryEncoderSupport.hevc
        videos = scanned.compactMap { video in
            let estimate = LibraryPlanner.estimatedBytes(
                durationSeconds: video.duration, width: video.width, height: video.height,
                frameRate: 30, size: size, hevc: hevc
            )
            guard LibraryPlanner.isWorthShrinking(originalBytes: video.bytes, estimatedBytes: estimate) else { return nil }
            return LibraryVideo(id: video.id, created: video.created, duration: video.duration,
                                bytes: video.bytes, estimatedBytes: estimate)
        }
        .sorted { $0.bytes > $1.bytes }
        picked = picked.intersection(videos.map(\.id))
    }

    /// Off the main thread: every video's size from its files' records.
    nonisolated private static func readLibrary(excluding: Set<String>,
                                                progress: @escaping (Int, Int) -> Void) -> [ScannedVideo] {
        let assets = PHAsset.fetchAssets(with: .video, options: nil)
        let total = assets.count
        var found: [ScannedVideo] = []
        for index in 0..<total {
            if index % 100 == 0 { progress(index, total) }
            let asset = assets.object(at: index)
            // Slow motion and Cinematic videos carry edits a plain copy would lose; ours are already small.
            if asset.mediaSubtypes.contains(.videoHighFrameRate) || asset.mediaSubtypes.contains(.videoCinematic) {
                continue
            }
            if excluding.contains(asset.localIdentifier) { continue }
            // Photos doesn't publish file sizes; each resource record carries one under "fileSize".
            let bytes = PHAssetResource.assetResources(for: asset).reduce(Int64(0)) { sum, resource in
                sum + ((resource.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0)
            }
            guard bytes > 0, asset.duration > 0 else { continue }
            found.append(ScannedVideo(id: asset.localIdentifier, created: asset.creationDate,
                                      duration: asset.duration, bytes: bytes,
                                      width: asset.pixelWidth, height: asset.pixelHeight))
        }
        progress(total, total)
        return found
    }

    // MARK: - Screenshots

    /// Free up space frozen in one state, for CI screenshots. No library is read.
    static func preview(access: Access = .full, pickAll: Bool = false) -> FreeUpSpace {
        let model = FreeUpSpace()
        model.isPreview = true
        model.access = access
        model.scan = access == .notAsked ? .notStarted : .finished
        let day: TimeInterval = 86_400
        let samples: [(Double, Int64, TimeInterval)] = [
            (252, 1_800_000_000, 120), (185, 1_400_000_000, 330), (168, 1_200_000_000, 20),
            (130, 980_000_000, 100), (112, 850_000_000, 180), (95, 720_000_000, 400),
        ]
        model.scanned = samples.enumerated().map { index, sample in
            ScannedVideo(id: "preview-\(index)", created: Date(timeIntervalSinceNow: -sample.2 * day),
                         duration: sample.0, bytes: sample.1, width: 3840, height: 2160)
        }
        model.refilter()
        model.picked = pickAll ? Set(model.videos.map(\.id)) : ["preview-0", "preview-1", "preview-2"]
        model.newSinceLastTime = 2_400_000_000
        return model
    }
}

/// A video worth shrinking: how big it is now and about how big the copy will be.
struct LibraryVideo: Identifiable, Hashable, Codable {
    /// The Photos library's id for it.
    let id: String
    let created: Date?
    let duration: Double
    let bytes: Int64
    let estimatedBytes: Int64
    var saving: Int64 { max(0, bytes - estimatedBytes) }
}

/// What the scan reads about each video.
private struct ScannedVideo: Sendable {
    let id: String
    let created: Date?
    let duration: Double
    let bytes: Int64
    let width: Int
    let height: Int
}

/// Copies Shrink made, so they're never offered for shrinking again.
enum ShrunkCopies {
    private static let key = "shrunkCopies"
    static var ids: Set<String> { Set(AppSettings.defaults.stringArray(forKey: key) ?? []) }
    static func add(_ id: String) {
        AppSettings.defaults.set(Array(ids.union([id])), forKey: key)
    }
}

/// The iPhone's own storage, as Settings shows it.
struct StorageInfo {
    let freeBytes: Int64
    let totalBytes: Int64

    static func current() -> StorageInfo? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                              .volumeTotalCapacityKey]),
              let free = values.volumeAvailableCapacityForImportantUsage,
              let total = values.volumeTotalCapacity, total > 0 else { return nil }
        return StorageInfo(freeBytes: free, totalBytes: Int64(total))
    }
}

/// Whether this iPhone can write HEVC (every iPhone since the 7 can). Without it, copies are H.264.
enum LibraryEncoderSupport {
    static let hevc = AVOutputSettingsAssistant.availableOutputSettingsPresets().contains(.hevc1920x1080)
}
