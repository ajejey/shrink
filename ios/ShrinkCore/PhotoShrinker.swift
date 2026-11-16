import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct PhotoShrinkResult {
    public let url: URL
    public let bytes: Int64
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let quality: Double
}

/// Turns any photo (HEIC, JPEG, PNG) into a JPEG that plays everywhere, optionally under a size
/// limit ("under 100 KB" for forms). Keeps the best quality that fits, then shrinks the picture if needed.
public enum PhotoShrinker {
    static let lowestQuality = 0.35
    static let highestQuality = 0.92
    static let smallestLongSide = 320

    public static func shrink(
        imageAt source: URL,
        to output: URL,
        targetBytes: Int64?,
        removeLocation: Bool = true
    ) throws -> PhotoShrinkResult {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw ShrinkError.couldNotRead("This doesn't look like a photo.") }

        let metadata = keptProperties(properties, removeLocation: removeLocation)
        var longSide = max(width, height)
        var smallestTried: Int64 = 0

        while true {
            guard let image = render(imageSource, longSide: longSide) else {
                throw ShrinkError.couldNotRead("The picture can't be decoded.")
            }
            switch bestEncoding(of: image, metadata: metadata, targetBytes: targetBytes) {
            case .fits(let data, let quality):
                do { try data.write(to: output, options: .atomic) } catch {
                    throw ShrinkError.couldNotWrite(error.localizedDescription)
                }
                return PhotoShrinkResult(
                    url: output, bytes: Int64(data.count),
                    pixelWidth: image.width, pixelHeight: image.height, quality: quality
                )
            case .tooBig(let bytes):
                smallestTried = bytes
            case .failed:
                throw ShrinkError.couldNotWrite("The JPEG encoder failed.")
            }
            let next = Int(Double(longSide) * 0.8)
            guard next >= smallestLongSide else { throw ShrinkError.stillTooBig(bytes: smallestTried) }
            longSide = next
        }
    }

    /// The picture upright (orientation applied), no larger than longSide.
    static func render(_ source: CGImageSource, longSide: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func encode(_ image: CGImage, quality: Double, metadata: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        var properties = metadata
        properties[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    enum Encoding {
        case fits(Data, quality: Double)
        case tooBig(bytes: Int64)
        case failed
    }

    /// The highest quality that fits at this size.
    static func bestEncoding(of image: CGImage, metadata: [CFString: Any], targetBytes: Int64?) -> Encoding {
        guard let target = targetBytes else {
            guard let data = encode(image, quality: 0.9, metadata: metadata) else { return .failed }
            return .fits(data, quality: 0.9)
        }
        guard let top = encode(image, quality: highestQuality, metadata: metadata) else { return .failed }
        if top.count <= target { return .fits(top, quality: highestQuality) }
        guard let bottom = encode(image, quality: lowestQuality, metadata: metadata) else { return .failed }
        if bottom.count > target { return .tooBig(bytes: Int64(bottom.count)) }

        var best = (data: bottom, quality: lowestQuality)
        var low = lowestQuality, high = highestQuality
        for _ in 0..<6 {
            let mid = (low + high) / 2
            guard let data = encode(image, quality: mid, metadata: metadata) else { break }
            if data.count <= target {
                best = (data, mid)
                low = mid
            } else {
                high = mid
            }
        }
        return .fits(best.data, quality: best.quality)
    }

    /// Camera details and the date taken; GPS only when the person chose to keep location.
    static func keptProperties(_ properties: [CFString: Any], removeLocation: Bool) -> [CFString: Any] {
        var kept: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = nil
            exif[kCGImagePropertyExifPixelYDimension] = nil
            kept[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            kept[kCGImagePropertyTIFFDictionary] = tiff
        }
        if !removeLocation, let gps = properties[kCGImagePropertyGPSDictionary] {
            kept[kCGImagePropertyGPSDictionary] = gps
        }
        return kept
    }
}
