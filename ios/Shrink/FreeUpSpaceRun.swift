import AVFoundation
import Photos
import ShrinkCore
import UIKit

/// Free up space, the shrinking itself: one video at a time, each smaller copy checked, saved with the
/// original's date, place, favorite and albums, then checked again as Photos hands it back. Then one
/// iOS prompt moves the originals to Recently Deleted. No original goes unless its copy passed both checks.
///
/// The batch is a saved queue. On iOS 26 iPhone may let it keep going after the person leaves Shrink
/// (ContinuedRun). If it's interrupted anyway (Shrink closed, iPhone stopped it, a call), the video it
/// was on is not counted, and the batch waits on a "Shrinking paused" screen for "Keep going".
extension FreeUpSpace {
    enum Run {
        case idle
        case working(Working)
        /// Interrupted with videos left: waiting for Keep going or Stop here.
        case paused(Paused)
        /// Waiting on iOS's "Allow Shrink to delete…?".
        case movingOriginals
        case finished(RunSummary)
        case tooFull(TooFull)
        case failed(String)
    }

    enum CancelReason {
        /// The person tapped Stop: the rest are dropped, the finished ones still go through.
        case stop
        /// iPhone ended the background run: the rest wait for Keep going.
        case pause
    }

    struct Working {
        var index: Int
        var count: Int
        var progress: Double
        var video: LibraryVideo
        /// Photos is fetching the original from iCloud first.
        var downloading: Bool
    }

    struct Paused {
        let done: Int
        let count: Int
    }

    struct RunSummary {
        let shrunk: Int
        let freedBytes: Int64
        /// iOS asked to delete the originals and the person said no: copies saved, nothing freed yet.
        let originalsKept: Bool
        /// Already about as small as they can be; left alone.
        let skipped: Int
        let problems: [String]
        /// Of the originals moved, how many were photos (Live Photos whose stills photo cleanup saved).
        var photos = 0
    }

    struct TooFull {
        let neededBytes: Int64
        let freeBytes: Int64
        /// The biggest saving that does fit right now, if any.
        let fitsOne: LibraryVideo?
    }

    /// Room to work beyond the copies themselves (Photos, the encoder, the system).
    static let workingRoom: Int64 = 300_000_000

    var isRunShowing: Bool {
        if case .idle = run { return false }
        return true
    }

    /// From "Check before shrinking". Checks the free allowance and the room on the iPhone first.
    func startShrinking() {
        guard !isRunShowing else { return }
        let list = plannedVideos
        guard !list.isEmpty else {
            run = .failed("Your free 5 GB is used up. Shrink Pro removes the limit.")
            return
        }
        // The copies sit beside the originals until the end, so they all need room at once.
        let needed = list.reduce(Int64(0)) { $0 + $1.estimatedBytes } + Self.workingRoom
        if let storage = StorageInfo.current(), storage.freeBytes < needed {
            let fits = list.sorted { $0.saving > $1.saving }
                .first { $0.estimatedBytes + Self.workingRoom <= storage.freeBytes }
            run = .tooFull(TooFull(neededBytes: needed, freeBytes: storage.freeBytes, fitsOne: fits))
            return
        }
        begin(list)
    }

    /// From "iPhone too full": just the one that fits.
    func shrinkOnly(_ video: LibraryVideo) {
        run = .idle
        picked = [video.id]
        begin([video])
    }

    /// Stops after the current video; the ones already finished still go through.
    func stop() {
        cancelReason = .stop
        runTask?.cancel()
    }

    /// Back to the list without having started (too full, or nothing to do).
    func cancelRun() {
        run = .idle
    }

    /// The finished screen closed: back to Home.
    func closeRun() {
        if case .finished(let summary) = run { lastRunFreed = summary.freedBytes } else { lastRunFreed = 0 }
        run = .idle
        requestsHome = true
    }

    /// When the app opens: a batch that was cut short (Shrink closed mid-way) shows as paused.
    /// Also clears copies-in-progress left behind by it.
    func restoreInterruptedRun() {
        guard !isPreview, case .idle = run, runTask == nil else { return }
        Self.removeLeftoverFiles()
        guard let queue, !queue.videos.isEmpty else {
            self.queue = nil
            return
        }
        run = .paused(Paused(done: queue.done, count: queue.total))
    }

    /// "Keep going" on the paused screen. Asks iPhone again for a background run (it needs the tap).
    func keepGoing() {
        guard case .paused = run, queue != nil else { return }
        work()
    }

    /// "Stop here" on the paused screen: the rest are dropped; the finished ones go through.
    func stopHere() {
        guard case .paused = run else { return }
        queue?.videos = []
        Task { await finishBatch() }
    }

    private func begin(_ list: [LibraryVideo]) {
        queue = RunQueue(videos: list, total: list.count, skipped: 0, problems: [], size: size.rawValue)
        work()
    }

    /// Runs the queue from where it is.
    private func work() {
        guard let first = queue, let video = first.videos.first else {
            Task { await finishBatch() }
            return
        }
        watchAppState()
        cancelReason = nil
        UIApplication.shared.isIdleTimerDisabled = true
        run = .working(Working(index: first.done, count: first.total, progress: 0, video: video, downloading: false))
        continued = ContinuedRun.start(subtitle: Self.subtitle(first.done, of: first.total)) { [weak self] in
            // iPhone ended the background run (or its stop button was tapped): pause, don't drop anything.
            guard let self else { return }
            self.cancelReason = self.cancelReason ?? .pause
            self.runTask?.cancel()
        }
        let hevc = LibraryEncoderSupport.hevc
        runTask = Task { [weak self] in
            guard let self else { return }
            while var current = self.queue, let video = current.videos.first {
                if Task.isCancelled { break }
                let size = LibraryPlanner.Size(rawValue: current.size) ?? .hd
                self.run = .working(Working(index: current.done, count: current.total, progress: 0, video: video,
                                            downloading: false))
                self.continued?.update(fraction: Double(current.done) / Double(max(current.total, 1)),
                                       subtitle: Self.subtitle(current.done, of: current.total))
                self.leftDuringVideo = UIApplication.shared.applicationState != .active
                do {
                    let copyBytes = try await self.shrinkOne(video, size: size, hevc: hevc)
                    // Remembered (across launches) the moment its copy passes, so it's never shrunk twice.
                    self.pendingOriginals.append(PendingOriginal(id: video.id, savedBytes: max(0, video.bytes - copyBytes)))
                    current.videos.removeFirst()
                } catch ShrinkError.cancelled {
                    break
                } catch is CancellationError {
                    break
                } catch ShrinkError.notSmaller {
                    current.skipped += 1
                    current.videos.removeFirst()
                } catch let failure as SavedCopyFailed {
                    current.problems.append(failure.localizedDescription)
                    current.videos.removeFirst()
                } catch {
                    if self.leftDuringVideo || UIApplication.shared.applicationState != .active {
                        // Interrupted, not broken: this video waits, untouched, for Keep going.
                        self.cancelReason = .pause
                        break
                    }
                    current.problems.append(error.localizedDescription)
                    current.videos.removeFirst()
                }
                self.queue = current
            }
            self.runTask = nil
            UIApplication.shared.isIdleTimerDisabled = false
            if let queue = self.queue, !queue.videos.isEmpty, self.cancelReason != .stop {
                self.pause()
            } else {
                self.queue?.videos = []
                await self.finishBatch()
            }
        }
    }

    private func pause() {
        continued?.finish(success: false, subtitle: "Paused. Open Shrink to keep going.")
        continued = nil
        guard let queue else { return }
        run = .paused(Paused(done: queue.done, count: queue.total))
    }

    /// Every video tried (or the rest dropped): one iOS prompt for the originals whose copies passed.
    private func finishBatch() async {
        let skipped = queue?.skipped ?? 0
        let problems = queue?.problems ?? []
        queue = nil
        UIApplication.shared.isIdleTimerDisabled = false
        if pendingOriginals.isEmpty {
            continued?.finish(success: true, subtitle: "Done")
            continued = nil
            run = .finished(RunSummary(shrunk: 0, freedBytes: 0, originalsKept: false, skipped: skipped,
                                       problems: problems))
            return
        }
        continued?.finish(success: true, subtitle: "Copies saved. Open Shrink to finish.")
        continued = nil
        // iOS only shows its delete prompt over an open app.
        while UIApplication.shared.applicationState != .active {
            try? await Task.sleep(for: .milliseconds(500))
        }
        await moveOriginals(skipped: skipped, problems: problems)
    }

    private static func subtitle(_ done: Int, of total: Int) -> String {
        "Video \(min(done + 1, total)) of \(total)"
    }

    /// Notes when Shrink leaves the screen (another app, a call, the lock button) during a video.
    private func watchAppState() {
        guard appStateObservers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            appStateObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.leftDuringVideo = true
                }
            })
        }
    }

    /// Copies in progress when the app was closed. Each can be gigabytes.
    private static func removeLeftoverFiles() {
        let folder = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(copyFilePrefix) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    private static let copyFilePrefix = "Shrink-library-"

    /// One video: fetch it (from iCloud if needed), shrink and check it, save the copy, then check the
    /// copy Photos hands back. Returns the copy's size. Throws if any check fails: the original stays.
    private func shrinkOne(_ video: LibraryVideo, size: LibraryPlanner.Size, hevc: Bool) async throws -> Int64 {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [video.id], options: nil).firstObject else {
            throw ShrinkError.couldNotRead("It's no longer in your library.")
        }
        let source = try await Self.loadVideo(asset) { [weak self] fraction in
            Task { @MainActor in self?.update(downloading: fraction < 1) }
        }
        try Task.checkCancellation()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.copyFilePrefix)\(UUID().uuidString).mov")
        // Photos moves the file in when it saves the copy; anything left here is a failed attempt.
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try await LibraryShrinker().shrink(
            asset: source, to: output, options: .init(size: size, hevc: hevc, originalBytes: video.bytes)
        ) { [weak self] value in
            Task { @MainActor in self?.update(progress: value) }
        }
        try Task.checkCancellation()
        // From here the copy is in the library, so finish even if Stop is tapped: a stopped check
        // would leave a saved copy whose original is never moved, and shrink it again next time.
        let check = Task.detached { () async throws -> String in
            let copyID = try await Self.saveCopy(result.url, like: asset)
            await MainActor.run { ShrunkCopies.add(copyID) }
            do {
                try await Self.checkSavedCopy(copyID, matches: result.expectation)
            } catch {
                throw SavedCopyFailed(underlying: error)
            }
            return copyID
        }
        _ = try await check.value
        return result.bytes
    }

    private func update(progress: Double? = nil, downloading: Bool? = nil) {
        guard case .working(var working) = run else { return }
        if let progress {
            working.progress = progress
            working.downloading = false
            continued?.update(fraction: (Double(working.index) + progress) / Double(max(working.count, 1)),
                              subtitle: Self.subtitle(working.index, of: working.count))
        }
        if let downloading { working.downloading = downloading }
        run = .working(working)
    }

    /// One iOS prompt for every original whose copy is saved. If they say no, the copies stay and
    /// the originals wait (Home offers to try again).
    func moveOriginals(skipped: Int = 0, problems: [String] = []) async {
        let waiting = pendingOriginals
        let ids = waiting.map(\.id)
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard assets.count > 0 else {
            // Already gone (deleted in Photos meanwhile): nothing left to move.
            pendingOriginals = []
            run = .finished(RunSummary(shrunk: waiting.count, freedBytes: 0, originalsKept: false,
                                       skipped: skipped, problems: problems))
            return
        }
        run = .movingOriginals
        do {
            var photos = 0
            assets.enumerateObjects { asset, _, _ in if asset.mediaType == .image { photos += 1 } }
            try await Self.deleteAssets(assets)
            let freed = waiting.reduce(Int64(0)) { $0 + $1.savedBytes }
            FreeAllowance.use(freed)
            pendingOriginals = []
            removeFromList(Set(ids))
            run = .finished(RunSummary(shrunk: waiting.count, freedBytes: freed, originalsKept: false,
                                       skipped: skipped, problems: problems, photos: photos))
        } catch {
            removeFromList(Set(ids))
            run = .finished(RunSummary(shrunk: waiting.count, freedBytes: 0, originalsKept: true,
                                       skipped: skipped, problems: problems))
        }
    }

    // MARK: - Photos

    /// The video as it looks now (with any edits), from iCloud if that's where it is.
    nonisolated private static func loadVideo(_ asset: PHAsset,
                                              onDownload: @escaping (Double) -> Void = { _ in }) async throws -> AVAsset {
        let options = PHVideoRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.progressHandler = { progress, _, _, _ in onDownload(progress) }
        return try await withCheckedThrowingContinuation { done in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { video, _, info in
                if let video {
                    done.resume(returning: video)
                } else {
                    let error = info?[PHImageErrorKey] as? Error
                    done.resume(throwing: ShrinkError.couldNotRead(
                        error?.localizedDescription ?? "Photos couldn't hand over this video."
                    ))
                }
            }
        }
    }

    /// The saved copy, found in Photos and read back from it, must still match its original.
    nonisolated private static func checkSavedCopy(_ id: String, matches expected: CopyExpectation) async throws {
        guard let saved = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
              saved.mediaType == .video else {
            throw ShrinkError.copyCheckFailed("Photos doesn't show the copy.")
        }
        let copy: AVAsset
        do {
            copy = try await loadVideo(saved)
        } catch {
            throw ShrinkError.copyCheckFailed("Photos can't open the copy.")
        }
        try await CopyCheck.verify(copy, matches: expected)
    }

    /// Saves the copy as a new library item with the original's date, place, favorite, hidden state and albums.
    nonisolated private static func saveCopy(_ url: URL, like original: PHAsset) async throws -> String {
        let albums = PHAssetCollection.fetchAssetCollectionsContaining(original, with: .album, options: nil)
        let created = CreatedID()
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                request.addResource(with: .video, fileURL: url, options: options)
                request.creationDate = original.creationDate
                request.location = original.location
                request.isFavorite = original.isFavorite
                request.isHidden = original.isHidden
                guard let placeholder = request.placeholderForCreatedAsset else { return }
                created.id = placeholder.localIdentifier
                albums.enumerateObjects { album, _, _ in
                    guard album.canPerform(.addContent) else { return }
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                }
            }, completionHandler: { success, error in
                if success {
                    done.resume()
                } else {
                    done.resume(throwing: ShrinkError.couldNotWrite(
                        error?.localizedDescription ?? "Photos didn't save the smaller copy."
                    ))
                }
            })
        }
        guard let id = created.id else { throw ShrinkError.couldNotWrite("Photos didn't save the smaller copy.") }
        return id
    }

    /// iOS shows its own "Allow Shrink to delete…?" for these. They go to Recently Deleted.
    nonisolated private static func deleteAssets(_ assets: PHFetchResult<PHAsset>) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(assets)
            }, completionHandler: { success, error in
                if success {
                    done.resume()
                } else {
                    done.resume(throwing: error ?? ShrinkError.cancelled)
                }
            })
        }
    }
}

/// A Free up space batch, saved after every video so it can carry on after Shrink is closed.
struct RunQueue: Codable {
    /// Still to shrink, in order. The first is the one being worked on.
    var videos: [LibraryVideo]
    let total: Int
    var skipped: Int
    var problems: [String]
    /// LibraryPlanner.Size's raw value, as chosen when the batch started.
    let size: String

    var done: Int { total - videos.count }

    private static let key = "freeUpQueue"

    static func load() -> RunQueue? {
        guard let data = AppSettings.defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RunQueue.self, from: data)
    }

    static func save(_ queue: RunQueue?) {
        if let queue, let data = try? JSONEncoder().encode(queue) {
            AppSettings.defaults.set(data, forKey: key)
        } else {
            AppSettings.defaults.removeObject(forKey: key)
        }
    }
}

/// An original whose smaller copy is saved, and the space it frees once it's gone.
struct PendingOriginal: Hashable {
    let id: String
    let savedBytes: Int64
}

/// Originals waiting to be moved, kept across launches.
enum PendingStore {
    private static let key = "pendingOriginals"

    static func load() -> [PendingOriginal] {
        let stored = AppSettings.defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        return stored.map { PendingOriginal(id: $0.key, savedBytes: Int64($0.value)) }
    }

    static func save(_ list: [PendingOriginal]) {
        let stored = Dictionary(list.map { ($0.id, Int($0.savedBytes)) }, uniquingKeysWith: { first, _ in first })
        AppSettings.defaults.set(stored, forKey: key)
    }
}

/// The copy is in the library but failed its second check. Never retried (that would save a second
/// copy); the original stays and it's reported.
private struct SavedCopyFailed: LocalizedError {
    let underlying: Error
    var errorDescription: String? { underlying.localizedDescription }
}

/// Carries the new item's id out of Photos' change block.
private final class CreatedID: @unchecked Sendable {
    var id: String?
}

extension FreeAllowance {
    /// The picked videos that fit in what's left of the free allowance, biggest first. All of them with Pro.
    @MainActor static func fitting(_ videos: [LibraryVideo]) -> [LibraryVideo] {
        let sorted = videos.sorted { $0.bytes > $1.bytes }
        guard !Store.shared.isPro else { return sorted }
        var left = leftBytes
        var list: [LibraryVideo] = []
        for video in sorted where video.saving <= left {
            list.append(video)
            left -= video.saving
        }
        return list
    }
}
