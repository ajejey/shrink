import AVFoundation
import CoreGraphics

/// What a finished copy has to match before its original may go, read from the video it was made from.
public struct CopyExpectation: Sendable, Equatable {
    /// The whole video's length, in seconds.
    public let duration: Double
    /// How long the picture runs.
    public let videoDuration: Double
    /// How long the sound runs, or nil when the original has none.
    public let audioDuration: Double?
    /// Average brightness (0 to 1) of the original's middle frame, so a copy whose picture came out
    /// black is caught. Nil when it couldn't be read.
    public let brightness: Double?

    public init(duration: Double, videoDuration: Double, audioDuration: Double?, brightness: Double?) {
        self.duration = duration
        self.videoDuration = videoDuration
        self.audioDuration = audioDuration
        self.brightness = brightness
    }
}

/// Free up space's safety check. A copy replaces its original only if it plays, has its picture from
/// start to end, has sound when the original did, and is the same length (within half a second).
/// It runs on the finished file, and again on the copy as Photos hands it back after saving.
public enum CopyCheck {
    /// How far the copy's length may be from the original's.
    public static let tolerance = 0.5
    /// Below this the original counts as dark, and a dark copy is expected.
    static let darkOriginal = 0.08
    /// A copy this dark, from an original that isn't, came out black.
    static let blackCopy = 0.02

    public static func expectation(for source: AVAsset) async throws -> CopyExpectation {
        let duration = try await source.load(.duration).seconds
        guard let video = try await source.loadTracks(withMediaType: .video).first else { throw ShrinkError.noVideo }
        let videoDuration = try await video.load(.timeRange).duration.seconds
        var audioDuration: Double?
        if let audio = try await source.loadTracks(withMediaType: .audio).first {
            let seconds = try await audio.load(.timeRange).duration.seconds
            // An empty sound track is no sound to keep.
            if seconds.isFinite, seconds > 0.05 { audioDuration = seconds }
        }
        let brightness = try? await Self.brightness(of: source, at: videoDuration / 2)
        return CopyExpectation(duration: duration, videoDuration: videoDuration, audioDuration: audioDuration,
                               brightness: brightness)
    }

    /// Throws `ShrinkError.copyCheckFailed` with what's wrong, in plain words.
    public static func verify(_ copy: AVAsset, matches expected: CopyExpectation) async throws {
        func failed(_ why: String) -> ShrinkError { .copyCheckFailed(why) }

        guard (try? await copy.load(.isPlayable)) == true else { throw failed("The copy won't play.") }
        guard let length = try? await copy.load(.duration).seconds, length.isFinite,
              abs(length - expected.duration) <= tolerance else {
            throw failed("The copy isn't the same length as the original.")
        }
        guard let video = try? await copy.loadTracks(withMediaType: .video).first,
              let pictureRange = try? await video.load(.timeRange) else {
            throw failed("The copy has no picture.")
        }
        // The picture may run to the end of the sound, but never stop early.
        guard pictureRange.duration.seconds >= expected.videoDuration - tolerance else {
            throw failed("The copy's picture stops early.")
        }
        if let audioDuration = expected.audioDuration {
            guard let audio = try? await copy.loadTracks(withMediaType: .audio).first,
                  let soundRange = try? await audio.load(.timeRange),
                  abs(soundRange.duration.seconds - audioDuration) <= tolerance else {
                throw failed("The copy's sound is missing or cut short.")
            }
        }

        // Its picture decodes at the start, the middle and the end.
        let pictureLength = pictureRange.duration.seconds
        let start = pictureRange.start.seconds
        for offset in [min(0.2, pictureLength / 2), pictureLength / 2, max(0, pictureLength - 0.3)] {
            guard (try? await frame(of: copy, at: start + offset, size: 64)) != nil else {
                throw failed("The copy's picture can't be shown.")
            }
        }
        if let original = expected.brightness, original > darkOriginal {
            let copyBrightness = try? await brightness(of: copy, at: start + pictureLength / 2)
            if let copyBrightness, copyBrightness < blackCopy {
                throw failed("The copy's picture came out black.")
            }
        }
    }

    // MARK: - Frames

    private static func frame(of asset: AVAsset, at seconds: Double, size: CGFloat) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: size, height: size)
        // Close to the moment asked for, so a picture that breaks off partway is noticed.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 3, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        return try await generator.image(at: CMTime(seconds: max(0, seconds), preferredTimescale: 600)).image
    }

    /// The average of a small version of the frame, 0 (black) to 1 (white).
    static func brightness(of asset: AVAsset, at seconds: Double) async throws -> Double {
        let image = try await frame(of: asset, at: seconds, size: 32)
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { throw ShrinkError.couldNotRead("Its picture can't be measured.") }
        var total = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            total += Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2])
        }
        return Double(total) / Double(side * side * 3 * 255)
    }
}
