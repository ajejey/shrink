#if DEBUG
import AVFoundation
import CoreLocation
import Photos
import SwiftUI

/// CI only, and only in Debug builds (never in the App Store build): sets up and reads back the
/// simulator's Photos library for the end-to-end tests (ShrinkUITests/FreeUpSpaceE2ETests and
/// PhotoCleanupE2ETests, the freeup-on-photos job in .github/workflows/ios.yml).
///
///   -e2e prepare          gives every video its own date, makes the one with a place (or the 1080p one,
///                         given a place) a favorite in an album called "Trips", then writes
///                         Documents/e2e-before.json
///   -e2e report           writes Documents/e2e-after.json
///   -e2e prepare-photos   adds the photo cleanup test's photos (E2EPhotos.swift), then writes
///                         Documents/e2e-photos-before.json
///   -e2e report-photos    writes Documents/e2e-photos-after.json
///
/// scripts/check-freeup-e2e.mjs and scripts/check-cleanup-e2e.mjs compare them.
struct E2EView: View {
    let mode: String
    @State private var status = "E2E working"

    var body: some View {
        Text(status)
            .font(.title)
            .padding()
            .accessibilityIdentifier("e2e-status")
            .task { status = await E2EHooks.run(mode) }
    }
}

enum E2EHooks {
    static func run(_ mode: String) async -> String {
        let access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard access == .authorized else { return "E2E failed: no full Photos access (\(access.rawValue))" }
        do {
            let facts: [[String: Any]]
            let name: String
            switch mode {
            case "prepare-photos":
                try await E2EPhotos.prepare()
                facts = E2EPhotos.describe()
                name = "e2e-photos-before.json"
            case "report-photos":
                facts = E2EPhotos.describe()
                name = "e2e-photos-after.json"
            case "prepare":
                try await prepare()
                facts = await describeLibrary()
                name = "e2e-before.json"
            default:
                facts = await describeLibrary()
                name = "e2e-after.json"
            }
            let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
            let data = try JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: folder.appendingPathComponent(name))
            return "E2E done: \(facts.count) items"
        } catch {
            return "E2E failed: \(error.localizedDescription)"
        }
    }

    private static func videos() -> [PHAsset] {
        var list: [PHAsset] = []
        PHAsset.fetchAssets(with: .video, options: nil).enumerateObjects { asset, _, _ in list.append(asset) }
        return list.sorted { $0.localIdentifier < $1.localIdentifier }
    }

    private static func prepare() async throws {
        let list = videos()
        guard !list.isEmpty else { throw E2EError("The library has no videos.") }
        let placed = list.first { $0.location != nil }
            ?? list.first { $0.pixelWidth == 1920 && $0.pixelHeight == 1080 }
            ?? list[0]
        let base = Date(timeIntervalSince1970: 1_748_772_000)   // 1 June 2025
        try await PHPhotoLibrary.shared().performChanges {
            // Distinct dates, so each copy can be matched to its original afterwards.
            for (index, asset) in list.enumerated() {
                PHAssetChangeRequest(for: asset).creationDate = base.addingTimeInterval(Double(index) * 86_400 * 9)
            }
            let request = PHAssetChangeRequest(for: placed)
            if placed.location == nil {
                request.location = CLLocation(latitude: 48.8584, longitude: 2.2945)
            }
            request.isFavorite = true
            PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "Trips")
                .addAssets([placed] as NSArray)
        }
    }

    private static func describeLibrary() async -> [[String: Any]] {
        var facts: [[String: Any]] = []
        for asset in videos() {
            var item: [String: Any] = [
                "id": asset.localIdentifier,
                "created": asset.creationDate?.timeIntervalSince1970 ?? 0,
                "duration": asset.duration,
                "pixelWidth": asset.pixelWidth,
                "pixelHeight": asset.pixelHeight,
                "favorite": asset.isFavorite,
                "hidden": asset.isHidden,
            ]
            if let location = asset.location {
                item["latitude"] = location.coordinate.latitude
                item["longitude"] = location.coordinate.longitude
            }
            var albums: [String] = []
            PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
                .enumerateObjects { album, _, _ in albums.append(album.localizedTitle ?? "") }
            item["albums"] = albums.sorted()
            item["bytes"] = PHAssetResource.assetResources(for: asset).reduce(Int64(0)) { sum, resource in
                sum + ((resource.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0)
            }
            if let video = await avAsset(asset) {
                let tracks = (try? await video.loadTracks(withMediaType: .video)) ?? []
                if let track = tracks.first,
                   let loaded = try? await track.load(.naturalSize, .preferredTransform, .mediaCharacteristics,
                                                      .formatDescriptions) {
                    let upright = loaded.0.applying(loaded.1)
                    item["uprightWidth"] = Int(abs(upright.width).rounded())
                    item["uprightHeight"] = Int(abs(upright.height).rounded())
                    item["hdr"] = loaded.2.contains(.containsHDRVideo)
                    if let format = loaded.3.first {
                        let code = CMFormatDescriptionGetMediaSubType(format)
                        item["codec"] = String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) },
                                               encoding: .ascii) ?? "\(code)"
                    }
                }
                let audio = (try? await video.loadTracks(withMediaType: .audio)) ?? []
                item["hasAudio"] = !audio.isEmpty
            }
            facts.append(item)
        }
        return facts
    }

    private static func avAsset(_ asset: PHAsset) async -> AVAsset? {
        let options = PHVideoRequestOptions()
        options.version = .current
        options.isNetworkAccessAllowed = false
        return await withCheckedContinuation { done in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { video, _, _ in
                done.resume(returning: video)
            }
        }
    }
}

struct E2EError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
#endif
