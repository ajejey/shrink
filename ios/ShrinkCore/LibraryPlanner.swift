import Foundation

/// Free up space: how a video kept in the library is shrunk, and how much that should save.
/// The copy stays in Photos, so it can use HEVC and keep HDR; it just carries fewer bits.
public enum LibraryPlanner {
    /// How big the copy's picture is.
    public enum Size: String, CaseIterable, Sendable {
        /// 1080p: looks the same on a phone and saves the most. The default.
        case hd = "1080p"
        /// Keeps 4K videos 4K. Saves less.
        case keep4K = "4K"

        public var maxLongSide: Int {
            switch self {
            case .hd: return 1920
            case .keep4K: return 3840
            }
        }
    }

    /// A video saving less than this isn't worth the wait or the extra copy in Recently Deleted.
    public static let smallestSavingBytes: Int64 = 50_000_000
    /// ...and it must lose at least this share of its size.
    public static let smallestSavingShare = 0.3
    /// Sound is copied as it is; iPhone's own AAC runs at about this.
    public static let audioBitsPerSecond = 192_000

    /// Width and height of the copy: the source's shape, no longer than the size's long side, even numbers.
    public static func outputDimensions(width: Int, height: Int, size: Size) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (2, 2) }
        let scale = min(1, Double(size.maxLongSide) / Double(max(width, height)))
        func even(_ value: Int) -> Int { max(2, Int((Double(value) * scale / 2).rounded()) * 2) }
        return (even(width), even(height))
    }

    /// Picture bitrate for the copy. About what iPhone's own HEVC uses for 1080p at 30 fps (4.5 Mbps),
    /// scaled with the number of pixels (a little less than in proportion) and the frame rate.
    /// H.264 needs about 60% more for the same look.
    public static func videoBitsPerSecond(width: Int, height: Int, frameRate: Double, hevc: Bool) -> Int {
        let pixels = Double(max(width, 2) * max(height, 2))
        let fps = min(max(frameRate.isFinite ? frameRate : 30, 15), 60)
        let rate = 4_500_000 * pow(pixels / 2_073_600, 0.75) * pow(fps / 30, 0.5)
        return Int((hevc ? rate : rate * 1.6).rounded())
    }

    /// About how big the copy of a video will be.
    public static func estimatedBytes(durationSeconds: Double, width: Int, height: Int, frameRate: Double,
                                      size: Size, hevc: Bool) -> Int64 {
        let out = outputDimensions(width: width, height: height, size: size)
        let video = videoBitsPerSecond(width: out.width, height: out.height, frameRate: frameRate, hevc: hevc)
        let bits = Double(video + audioBitsPerSecond) * max(durationSeconds, 0)
        return Int64((bits / 8 * 1.02).rounded())   // ~2% for the container
    }

    /// Worth listing: saves at least 50 MB and at least 30% of the video.
    public static func isWorthShrinking(originalBytes: Int64, estimatedBytes: Int64) -> Bool {
        let saving = originalBytes - estimatedBytes
        return saving >= smallestSavingBytes && Double(saving) >= Double(originalBytes) * smallestSavingShare
    }
}
