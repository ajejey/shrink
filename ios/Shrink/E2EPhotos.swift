#if DEBUG
import AVFoundation
import CoreLocation
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

/// CI only, Debug builds only: the photos for the Clean up photos end-to-end test
/// (ShrinkUITests/PhotoCleanupE2ETests), each on its own day so scripts/check-cleanup-e2e.mjs can tell
/// them apart:
///
///   1 March 2025  a camera photo (kept)
///   2 March       a picture saved from a chat, no camera details (kept)
///   3 March       the same picture twice: one a favorite (stays), one in an album "Wedding" (goes; the
///                 one that stays must join "Wedding")
///   4 March       a Live Photo with a place, a favorite, in an album "Trips" (becomes a still)
enum E2EPhotos {
    static let firstDay = Date(timeIntervalSince1970: 1_740_826_800)   // 1 March 2025, 11:00 UTC
    private static let day: TimeInterval = 86_400

    static func prepare() async throws {
        let folder = FileManager.default.temporaryDirectory
        let camera = folder.appendingPathComponent("e2e-camera.jpg")
        let download = folder.appendingPathComponent("e2e-download.jpg")
        let duplicate = folder.appendingPathComponent("e2e-duplicate.jpg")
        let livePhoto = folder.appendingPathComponent("e2e-live.jpg")
        let liveVideo = folder.appendingPathComponent("e2e-live.mov")
        let identifier = UUID().uuidString
        try writeJPEG(picture(seed: 1), cameraDetails: true, to: camera)
        try writeJPEG(picture(seed: 2), cameraDetails: false, to: download)
        try writeJPEG(picture(seed: 3), cameraDetails: true, to: duplicate)
        try writeJPEG(picture(seed: 4), cameraDetails: true, contentIdentifier: identifier, to: livePhoto)
        try await writeLiveVideo(picture(seed: 4), identifier: identifier, to: liveVideo)

        let first = firstDay, day = day
        try await PHPhotoLibrary.shared().performChanges {
            func add(_ url: URL, on date: Date) -> PHAssetCreationRequest {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: url, options: nil)
                request.creationDate = date
                return request
            }
            _ = add(camera, on: first)
            _ = add(download, on: first.addingTimeInterval(day))
            add(duplicate, on: first.addingTimeInterval(2 * day)).isFavorite = true
            if let copy = add(duplicate, on: first.addingTimeInterval(2 * day)).placeholderForCreatedAsset {
                PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "Wedding")
                    .addAssets([copy] as NSArray)
            }
            let live = PHAssetCreationRequest.forAsset()
            live.addResource(with: .photo, fileURL: livePhoto, options: nil)
            live.addResource(with: .pairedVideo, fileURL: liveVideo, options: nil)
            live.creationDate = first.addingTimeInterval(3 * day)
            live.isFavorite = true
            live.location = CLLocation(latitude: 48.8584, longitude: 2.2945)
            if let placeholder = live.placeholderForCreatedAsset {
                PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "Trips")
                    .addAssets([placeholder] as NSArray)
            }
        }
    }

    /// Every photo in the library and what makes it the person's own.
    static func describe() -> [[String: Any]] {
        var facts: [[String: Any]] = []
        PHAsset.fetchAssets(with: .image, options: nil).enumerateObjects { asset, _, _ in
            var item: [String: Any] = [
                "id": asset.localIdentifier,
                "created": asset.creationDate?.timeIntervalSince1970 ?? 0,
                "favorite": asset.isFavorite,
                "hidden": asset.isHidden,
                "live": asset.mediaSubtypes.contains(.photoLive),
                "screenshot": asset.mediaSubtypes.contains(.photoScreenshot),
                "pixelWidth": asset.pixelWidth,
                "pixelHeight": asset.pixelHeight,
            ]
            if let location = asset.location {
                item["latitude"] = location.coordinate.latitude
                item["longitude"] = location.coordinate.longitude
            }
            var albums: [String] = []
            PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
                .enumerateObjects { album, _, _ in albums.append(album.localizedTitle ?? "") }
            item["albums"] = albums.sorted()
            let resources = PHAssetResource.assetResources(for: asset)
            item["bytes"] = resources.reduce(Int64(0)) { sum, resource in
                sum + ((resource.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0)
            }
            item["resources"] = resources.map { "\($0.type.rawValue)" }
            facts.append(item)
        }
        return facts
    }

    // MARK: - Making the files

    /// A made-up scene: a gradient and coloured shapes, different for each seed.
    private static func picture(seed: Int, width: Int = 1440, height: Int = 1080) -> CGImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height),
                                               format: { let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format }())
        let image = renderer.image { context in
            let hue = CGFloat(seed * 67 % 360) / 360
            UIColor(hue: hue, saturation: 0.5, brightness: 0.9, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for index in 0..<10 {
                UIColor(hue: CGFloat((seed * 31 + index * 47) % 360) / 360, saturation: 0.7, brightness: 0.6, alpha: 1).setFill()
                let size = CGFloat(120 + (index * 53 + seed * 17) % 260)
                let rect = CGRect(x: CGFloat((index * 211 + seed * 97) % width), y: CGFloat((index * 157 + seed * 61) % height),
                                  width: size, height: size * 0.8)
                if index % 2 == 0 { context.cgContext.fillEllipse(in: rect) } else { context.fill(rect) }
            }
        }
        return image.cgImage!
    }

    private static func writeJPEG(_ image: CGImage, cameraDetails: Bool, contentIdentifier: String? = nil,
                                  to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw E2EError("Couldn't write a test photo.")
        }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if cameraDetails {
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "Apple",
                                                          kCGImagePropertyTIFFModel: "iPhone 15 Pro"]
        }
        if let contentIdentifier {
            // What pairs a Live Photo's photo with its video.
            properties[kCGImagePropertyMakerAppleDictionary] = ["17": contentIdentifier]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw E2EError("Couldn't finish a test photo.") }
    }

    /// The Live Photo's moving part: two seconds of the same scene with a block sliding across, carrying
    /// the photo's content identifier and the moment the photo was taken.
    private static func writeLiveVideo(_ image: CGImage, identifier: String, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let id = AVMutableMetadataItem()
        id.key = "com.apple.quicktime.content.identifier" as NSString
        id.keySpace = .quickTimeMetadata
        id.value = identifier as NSString
        id.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = [id]

        let width = 960, height = 720
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        video.expectsMediaDataInRealTime = false
        let frames = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(video)

        let specification: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: "com.apple.metadata.datatype.int8",
        ]
        var format: CMFormatDescription?
        _ = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [specification] as CFArray, formatDescriptionOut: &format)
        let stillTime = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: format)
        let stillTimeAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: stillTime)
        writer.add(stillTime)

        guard writer.startWriting() else { throw E2EError(writer.error?.localizedDescription ?? "Couldn't write the Live Photo video.") }
        writer.startSession(atSourceTime: .zero)
        let mark = AVMutableMetadataItem()
        mark.key = "com.apple.quicktime.still-image-time" as NSString
        mark.keySpace = .quickTimeMetadata
        mark.value = 0 as NSNumber
        mark.dataType = "com.apple.metadata.datatype.int8"
        stillTimeAdaptor.append(AVTimedMetadataGroup(
            items: [mark], timeRange: CMTimeRange(start: CMTime(value: 1, timescale: 1), duration: CMTime(value: 1, timescale: 30))))
        stillTime.markAsFinished()

        for frame in 0..<60 {
            while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferCGImageCompatibilityKey: true,
                                 kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer)
            guard let buffer else { throw E2EError("Couldn't make a video frame.") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                       bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
                context.fill(CGRect(x: frame * 12, y: 300, width: 90, height: 90))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            frames.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30))
        }
        video.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw E2EError(writer.error?.localizedDescription ?? "The Live Photo video didn't finish.")
        }
    }
}
#endif
