import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Vision

/// What photo cleanup learns from a picture's pixels and file: its fingerprints for duplicates, its
/// Vision feature print for similar shots, Vision's quality score, and whether a camera made it.
public enum PhotoLook {
    public enum LookError: LocalizedError {
        case noResult
        public var errorDescription: String? { "Vision returned nothing for this picture." }
    }

    /// A 64-bit difference hash: the picture shrunk to 9×8 grey pixels, one bit per pair of
    /// neighbours. The same pixels always give the same hash.
    public static func differenceHash(_ image: CGImage) -> UInt64? {
        let width = 9, height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var hash: UInt64 = 0
        for row in 0..<height {
            for column in 0..<(width - 1) {
                hash <<= 1
                if pixels[row * width + column] > pixels[row * width + column + 1] { hash |= 1 }
            }
        }
        return hash
    }

    /// How many of the 64 bits differ.
    public static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// The size plus a SHA-256 of every pixel (8-bit RGBA, sRGB): equal only for the very same picture.
    public static func pixelHash(_ image: CGImage) -> String? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let digest = SHA256.hash(data: pixels)
        return "\(width)x\(height)-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The picture's Vision feature print (for similar shots).
    public static func featureVector(_ image: CGImage,
                                     orientation: CGImagePropertyOrientation = .up) throws -> FeatureVector {
        let request = VNGenerateImageFeaturePrintRequest()
        #if targetEnvironment(simulator)
        // The simulator has no Neural Engine.
        request.usesCPUOnly = true
        #endif
        try VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:]).perform([request])
        guard let observation = request.results?.first else { throw LookError.noResult }
        let count = observation.elementCount
        let values: [Float]
        switch observation.elementType {
        case .float:
            values = observation.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(count)) }
        case .double:
            values = observation.data.withUnsafeBytes {
                $0.bindMemory(to: Double.self).prefix(count).map { Float($0) }
            }
        default:
            throw LookError.noResult
        }
        guard let vector = FeatureVector(values: values) else { throw LookError.noResult }
        return vector
    }

    /// Vision's view of a photo: how good it looks (−1 to 1) and whether it's a utility picture
    /// (a receipt, a whiteboard, a document).
    public struct Quality: Sendable, Hashable {
        public let score: Float
        public let isUtility: Bool

        public init(score: Float, isUtility: Bool) {
            self.score = score
            self.isUtility = isUtility
        }
    }

    /// Nil before iOS 18, which doesn't have the request.
    public static func quality(_ image: CGImage, orientation: CGImagePropertyOrientation = .up) throws -> Quality? {
        guard #available(iOS 18.0, *) else { return nil }
        let request = VNCalculateImageAestheticsScoresRequest()
        try VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:]).perform([request])
        guard let result = request.results?.first else { throw LookError.noResult }
        return Quality(score: result.overallScore, isUtility: result.isUtility)
    }

    /// Whether the file names the camera that took it (make, model or lens). Pictures saved from chats
    /// and the web, memes and downloads, don't.
    public static func hasCameraDetails(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return false
        }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let names = [tiff?[kCGImagePropertyTIFFMake], tiff?[kCGImagePropertyTIFFModel],
                     exif?[kCGImagePropertyExifLensModel], exif?[kCGImagePropertyExifLensMake]]
        return names.contains { name in
            guard let text = name as? String else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// The full picture in a file, for `pixelHash`.
    public static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
}
