import ImageIO
import Photos
import ShrinkCore
import UIKit

/// Clean up photos, the doing: Live Photos picked for "just the photo" get a still copy first (saved
/// with the same date, place, favorite and albums, then checked as Photos hands it back), then one
/// iOS prompt sends everything picked, and the Live Photos whose stills passed, to Recently Deleted.
/// A Live Photo never goes unless its still passed the check.
enum CleanupRun {
    case idle
    /// Saving still photos for Live Photos.
    case working(done: Int, count: Int)
    /// Waiting on iOS's "Allow Shrink to delete…?".
    case deleting
    case finished(CleanupSummary)
    case failed(String)
}

struct CleanupSummary {
    let deleted: Int
    let stills: Int
    let freedBytes: Int64
    /// iOS asked and the answer was no: nothing was deleted.
    let declined: Bool
    let problems: [String]
}

extension PhotoCleanup {
    var isRunShowing: Bool {
        if case .idle = run { return false }
        return true
    }

    /// From the check screen.
    func startCleanup() {
        guard !isRunShowing, runTask == nil else { return }
        let plan = planned
        guard plan.count > 0 else {
            run = .failed("Your free 5 GB is used up. Shrink Pro removes the limit.")
            return
        }
        runTask = Task { [weak self] in
            await self?.perform(plan)
            self?.runTask = nil
        }
    }

    /// Back to the list (from a failure before anything happened).
    func cancelRun() {
        run = .idle
    }

    /// The finished screen closed: back to Home.
    func closeRun() {
        if case .finished(let summary) = run { lastRunFreed = summary.freedBytes } else { lastRunFreed = 0 }
        run = .idle
        requestsHome = true
    }

    private func perform(_ plan: Planned) async {
        var problems: [String] = []
        var converted: [CleanupItem] = []
        if !plan.stills.isEmpty {
            // Each still sits beside its Live Photo until the end.
            let needed = plan.stills.reduce(Int64(0)) { $0 + max(0, $1.bytes - $1.stillSaving) } + 100_000_000
            if let storage = StorageInfo.current(), storage.freeBytes < needed {
                run = .failed("Your iPhone is too full to save the still photos. Empty Recently Deleted in Photos, then try again.")
                return
            }
            UIApplication.shared.isIdleTimerDisabled = true
            for (index, item) in plan.stills.enumerated() {
                run = .working(done: index, count: plan.stills.count)
                do {
                    _ = try await Self.makeStill(of: item.id)
                    converted.append(item)
                } catch {
                    problems.append(error.localizedDescription)
                }
            }
            UIApplication.shared.isIdleTimerDisabled = false
        }
        let deletes = plan.deletes
        guard !deletes.isEmpty || !converted.isEmpty else {
            run = .finished(CleanupSummary(deleted: 0, stills: 0, freedBytes: 0, declined: false, problems: problems))
            return
        }
        // iOS only shows its delete prompt over an open app.
        while UIApplication.shared.applicationState != .active {
            try? await Task.sleep(for: .milliseconds(500))
        }
        run = .deleting
        let ids = deletes.map(\.id) + converted.map(\.id)
        let going = Set(ids)
        let carry = keeperFor.filter { going.contains($0.key) && !going.contains($0.value) }
        do {
            try await Self.delete(ids, carryingOverTo: carry)
            let freed = deletes.reduce(Int64(0)) { $0 + $1.bytes } + converted.reduce(Int64(0)) { $0 + $1.stillSaving }
            FreeAllowance.use(freed)
            await removeFromPiles(going)
            run = .finished(CleanupSummary(deleted: deletes.count, stills: converted.count, freedBytes: freed,
                                           declined: false, problems: problems))
        } catch {
            let declined = (error as? PHPhotosError)?.code == .userCancelled
            if !declined { problems.insert(error.localizedDescription, at: 0) }
            // The stills are saved: their Live Photos wait in Free up space's "still in your library"
            // row, so they're never turned into stills twice.
            if !converted.isEmpty {
                freeUp.pendingOriginals += converted.map { PendingOriginal(id: $0.id, savedBytes: $0.stillSaving) }
                await removeFromPiles(Set(converted.map(\.id)))
            }
            run = .finished(CleanupSummary(deleted: 0, stills: converted.count, freedBytes: 0, declined: true,
                                           problems: problems))
        }
    }

    // MARK: - Photos

    /// One iOS prompt for all of them. In the same change, each copy that stays joins the albums of the
    /// duplicates that go, and becomes a favorite if one of them was, so no album loses a picture.
    nonisolated private static func delete(_ ids: [String], carryingOverTo keepers: [String: String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard assets.count > 0 else { return }
        var keeperAssets: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: Array(Set(keepers.values)), options: nil)
            .enumerateObjects { asset, _, _ in keeperAssets[asset.localIdentifier] = asset }
        var albumsFor: [String: [PHAssetCollection]] = [:]
        var favorites: Set<String> = []
        assets.enumerateObjects { asset, _, _ in
            guard let keeperID = keepers[asset.localIdentifier], let keeper = keeperAssets[keeperID] else { return }
            PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
                .enumerateObjects { album, _, _ in
                    if album.canPerform(.addContent) { albumsFor[keeperID, default: []].append(album) }
                }
            if asset.isFavorite && !keeper.isFavorite { favorites.insert(keeperID) }
        }
        let albumsToJoin = albumsFor, newFavorites = favorites, keepersByID = keeperAssets
        try await PHPhotoLibrary.shared().performChanges {
            for (keeperID, albums) in albumsToJoin {
                guard let keeper = keepersByID[keeperID] else { continue }
                for album in albums {
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([keeper] as NSArray)
                }
            }
            for keeperID in newFavorites {
                guard let keeper = keepersByID[keeperID] else { continue }
                PHAssetChangeRequest(for: keeper).isFavorite = true
            }
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }

    /// Saves the Live Photo's photo on its own (the edited version if it was edited) as a new library
    /// item with the same date, place, favorite, hidden state and albums, and checks it. Returns its id.
    nonisolated static func makeStill(of id: String) async throws -> String {
        guard let original = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw CleanupError("A Live Photo is no longer in your library.")
        }
        let resources = PHAssetResource.assetResources(for: original)
        guard let photo = resources.first(where: { $0.type == .fullSizePhoto })
                ?? resources.first(where: { $0.type == .photo }) else {
            throw CleanupError("Photos has no still photo for a Live Photo, so it was left as it is.")
        }
        let name = photo.originalFilename.isEmpty ? "Photo.HEIC" : photo.originalFilename
        let ext = (name as NSString).pathExtension.isEmpty ? "HEIC" : (name as NSString).pathExtension
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Shrink-still-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: file) }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: photo, toFile: file, options: options) { error in
                if let error {
                    done.resume(throwing: CleanupError("A Live Photo couldn't be read: \(error.localizedDescription)"))
                } else {
                    done.resume()
                }
            }
        }
        guard canOpen(file) else { throw CleanupError("A Live Photo's still photo couldn't be opened, so it was left as it is.") }

        let albums = PHAssetCollection.fetchAssetCollectionsContaining(original, with: .album, options: nil)
        let created = CreatedStill()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let resourceOptions = PHAssetResourceCreationOptions()
            resourceOptions.originalFilename = name
            request.addResource(with: .photo, fileURL: file, options: resourceOptions)
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
        }
        guard let stillID = created.id else { throw CleanupError("Photos didn't save a still photo.") }
        try checkStill(stillID, against: original)
        return stillID
    }

    /// The still, as Photos hands it back: a photo (not a Live Photo), the same size, and it opens.
    nonisolated private static func checkStill(_ id: String, against original: PHAsset) throws {
        guard let still = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
              still.mediaType == .image else {
            throw CleanupError("Photos doesn't show a still photo it saved, so its Live Photo stays.")
        }
        guard !still.mediaSubtypes.contains(.photoLive) else {
            throw CleanupError("A still photo came out as a Live Photo, so the original stays.")
        }
        let sameSize = (still.pixelWidth == original.pixelWidth && still.pixelHeight == original.pixelHeight)
            || (still.pixelWidth == original.pixelHeight && still.pixelHeight == original.pixelWidth)
        guard sameSize else {
            throw CleanupError("A still photo isn't the same size as its Live Photo, so the Live Photo stays.")
        }
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.isNetworkAccessAllowed = false
        options.version = .current
        let opens = Carried(false)
        PHImageManager.default().requestImageDataAndOrientation(for: still, options: options) { data, _, _, _ in
            guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return }
            opens.value = Self.thumbnail(source) != nil
        }
        guard opens.value else { throw CleanupError("A still photo didn't open from Photos, so its Live Photo stays.") }
    }

    nonisolated private static func canOpen(_ file: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            return false
        }
        return thumbnail(source) != nil
    }

    nonisolated private static func thumbnail(_ source: CGImageSource) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ] as CFDictionary)
    }
}

struct CleanupError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Carries the new still's id out of Photos' change block.
private final class CreatedStill: @unchecked Sendable {
    var id: String?
}
