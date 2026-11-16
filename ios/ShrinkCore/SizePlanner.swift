import Foundation

/// How to encode a video so the finished file lands under a size limit.
public struct SizePlan: Equatable, Sendable {
    /// Average video bitrate to ask the encoder for.
    public var videoBitsPerSecond: Int
    /// AAC bitrate, or 0 when there's no sound to keep.
    public var audioBitsPerSecond: Int
    /// Longest side of the output picture in pixels. Never larger than the source.
    public var maxLongSide: Int
    /// Frames per second the output is capped at.
    public var maxFrameRate: Double
}

/// The arithmetic behind "fit this video under N bytes". Pure, so it's tested without any video.
public enum SizePlanner {
    /// Share of the limit we aim at. The rest absorbs the MP4 container and encoder overshoot.
    public static let safety = 0.92
    /// Below this the picture turns to mush, so we ask the person to trim instead.
    public static let minimumVideoBitsPerSecond = 120_000
    /// Bitrate that looks decent at 1920 px and 30 fps in H.264. Other sizes scale with pixel count.
    static let decentBitsAt1920 = 3_000_000.0
    static let standardLongSides = [3840, 2560, 1920, 1280, 960, 854, 640, 480]

    /// Bitrate a picture with this long side needs to look decent at this frame rate.
    public static func decentBitsPerSecond(longSide: Int, frameRate: Double = 30) -> Double {
        let scale = Double(longSide) / 1920
        return decentBitsAt1920 * scale * scale * max(frameRate, 1) / 30
    }

    /// The plan for one video, or nil when it's too long to fit and still be watchable.
    public static func plan(
        targetBytes: Int64,
        durationSeconds: Double,
        hasAudio: Bool,
        sourceLongSide: Int,
        sourceFrameRate: Double,
        sourceVideoBitsPerSecond: Int? = nil
    ) -> SizePlan? {
        guard targetBytes > 0, durationSeconds > 0, sourceLongSide > 0 else { return nil }
        let total = Double(targetBytes) * 8 * safety / durationSeconds
        let audio = hasAudio ? audioBitsPerSecond(forTotal: total) : 0
        var video = Int(total) - audio
        // Never spend more than the source had (with room for H.264 being less efficient than HEVC).
        if let source = sourceVideoBitsPerSecond, source > 0 { video = min(video, source) }
        guard video >= minimumVideoBitsPerSecond else { return nil }

        // Keep 60 fps only when the budget can carry it; otherwise every frame gets twice the bits at 30.
        let sourceRate = sourceFrameRate > 0 ? sourceFrameRate : 30
        let keepsHighRate = Double(video) >= decentBitsPerSecond(longSide: min(sourceLongSide, 1920), frameRate: sourceRate)
        let frameRate = (sourceRate > 31 && !keepsHighRate) ? 30 : min(sourceRate, 60)

        // The largest picture the budget can make look decent. Never upscale.
        let candidates = [sourceLongSide] + standardLongSides.filter { $0 < sourceLongSide }
        let longSide = candidates.first { Double(video) >= decentBitsPerSecond(longSide: $0, frameRate: frameRate) }
            ?? candidates[candidates.count - 1]

        return SizePlan(videoBitsPerSecond: video, audioBitsPerSecond: audio, maxLongSide: longSide, maxFrameRate: frameRate)
    }

    /// Stereo AAC: 128 kbps normally, less when the whole budget is small.
    static func audioBitsPerSecond(forTotal total: Double) -> Int {
        switch total {
        case 1_500_000...: return 128_000
        case 600_000..<1_500_000: return 96_000
        default: return 64_000
        }
    }

    /// Overshoot beyond which we stop trusting a lower bitrate alone. Grainy or busy footage (night
    /// video, confetti, water) hits the encoder's quality floor, and then only fewer pixels make it smaller.
    static let resolutionDropOvershoot = 1.15
    static let smallestLongSide = 320

    /// After an encode came out too big: the plan for one more try, or nil if it can't get small enough.
    public static func corrected(_ plan: SizePlan, deliveredBytes: Int64, targetBytes: Int64, durationSeconds: Double) -> SizePlan? {
        guard deliveredBytes > 0, durationSeconds > 0, plan.videoBitsPerSecond > 0 else { return nil }
        let audio = Double(plan.audioBitsPerSecond)
        let deliveredVideo = Double(deliveredBytes) * 8 / durationSeconds - audio
        let overshoot = max(deliveredVideo / Double(plan.videoBitsPerSecond), 1)
        let wantedVideo = Double(targetBytes) * 8 * safety / durationSeconds - audio
        let video = min(Int(wantedVideo / overshoot * 0.97), Int(Double(plan.videoBitsPerSecond) * 0.9))
        guard video >= minimumVideoBitsPerSecond else { return nil }
        var next = plan
        next.videoBitsPerSecond = video

        if overshoot > resolutionDropOvershoot {
            // At the floor, size follows pixel count: cut pixels by the overshoot, then snap to a standard size.
            let wanted = Int(Double(plan.maxLongSide) / overshoot.squareRoot() * 0.95)
            let snapped = standardLongSides.first { $0 <= wanted } ?? wanted
            let longSide = max(smallestLongSide, min(snapped, plan.maxLongSide - 2))
            guard longSide < plan.maxLongSide else { return nil }
            next.maxLongSide = longSide
        }
        return next
    }
}
