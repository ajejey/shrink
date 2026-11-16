import AVFoundation
import Photos
import ShrinkCore
import UIKit

/// Free up space, the shrinking itself: one video at a time while the app is open, each smaller copy
/// saved with the original's date, place, favorite and albums; then one iOS prompt moves the originals
/// to Recently Deleted. Nothing is deleted before the copy is safely in the library.
extension FreeUpSpace {
    enum Run {
        case idle
        case working(Working)
        /// Waiting on iOS's "Allow Shrink to delete…?".
        case movingOriginals
        case finished(RunSummary)
        case tooFull(TooFull)
        case failed(String)
    }

    struct Working {
        var index: Int
        var count: Int
        var progress: Double
        var video: LibraryVideo
        /// Photos is fetching the original from iCloud first.
        var downloading: Bool
    }

    struct RunSummary {
        let shrunk: Int
        let freedBytes: Int64
        /// iOS asked to delete the originals and the person said no: copies saved, nothing freed yet.
        let originalsKept: Bool
        /// Already about as small as they can be; left alone.
        let skipped: Int
        let problems: [String]
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

    private func begin(_ list: [LibraryVideo]) {
        UIApplication.shared.isIdleTimerDisabled = true
        let size = self.size
        let hevc = LibraryEncoderSupport.hevc
        run = .working(Working(index: 0, count: list.count, progress: 0, video: list[0], downloading: false))
        runTask = Task { [weak self] in
            guard let self else { return }
            var skipped = 0
            var problems: [String] = []
            for (index, video) in list.enumerated() {
                if Task.isCancelled { break }
                self.run = .working(Working(index: index, count: list.count, progress: 0, video: video, downloading: false))
                do {
                    let copyBytes = try await self.shrinkOne(video, size: size, hevc: hevc)
                    // Remembered (across launches) the moment its copy is saved, so it's never shrunk twice.
                    self.pendingOriginals.append(PendingOriginal(id: video.id, savedBytes: max(0, video.bytes - copyBytes)))
                } catch ShrinkError.cancelled {
                    break
                } catch is CancellationError {
                    break
                } catch ShrinkError.notSmaller {
                    skipped += 1
                } catch {
                    problems.append(error.localizedDescription)
                }
            }
            UIApplication.shared.isIdleTimerDisabled = false
            if self.pendingOriginals.isEmpty {
                self.run = .finished(RunSummary(shrunk: 0, freedBytes: 0, originalsKept: false,
                                                skipped: skipped, problems: problems))
                return
            }
            await self.moveOriginals(skipped: skipped, problems: problems)
        }
    }

    /// One video: fetch it (from iCloud if needed), shrink it, save the copy. Returns the copy's size.
    private func shrinkOne(_ video: LibraryVideo, size: LibraryPlanner.Size, hevc: Bool) async throws -> Int64 {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [video.id], options: nil).firstObject else {
            throw ShrinkError.couldNotRead("It's no longer in your library.")
        }
        let source = try await Self.loadVideo(asset) { [weak self] fraction in
            Task { @MainActor in self?.update(downloading: fraction < 1) }
        }
        try Task.checkCancellation()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("Shrink-library-\(UUID().uuidString).mov")
        // Photos moves the file in when it saves the copy; anything left here is a failed attempt.
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try await LibraryShrinker().shrink(
            asset: source, to: output, options: .init(size: size, hevc: hevc, originalBytes: video.bytes)
        ) { [weak self] value in
            Task { @MainActor in self?.update(progress: value) }
        }
        try Task.checkCancellation()
        let copyID = try await Self.saveCopy(result.url, like: asset)
        ShrunkCopies.add(copyID)
        return result.bytes
    }

    private func update(progress: Double? = nil, downloading: Bool? = nil) {
        guard case .working(var working) = run else { return }
        if let progress {
            working.progress = progress
            working.downloading = false
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
            try await Self.deleteAssets(assets)
            let freed = waiting.reduce(Int64(0)) { $0 + $1.savedBytes }
            FreeAllowance.use(freed)
            pendingOriginals = []
            removeFromList(Set(ids))
            run = .finished(RunSummary(shrunk: waiting.count, freedBytes: freed, originalsKept: false,
                                       skipped: skipped, problems: problems))
        } catch {
            removeFromList(Set(ids))
            run = .finished(RunSummary(shrunk: waiting.count, freedBytes: 0, originalsKept: true,
                                       skipped: skipped, problems: problems))
        }
    }

    // MARK: - Photos

    /// The video as it looks now (with any edits), from iCloud if that's where it is.
    nonisolated private static func loadVideo(_ asset: PHAsset,
                                              onDownload: @escaping (Double) -> Void) async throws -> AVAsset {
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
