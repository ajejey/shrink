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

/// Shrink Pro's sending options that change the plan. `.standard` is what everyone gets without Pro.
/// Every planner call takes one, so no caller can quietly fall back to the standard numbers.
public struct SizeChoices: Equatable, Sendable {
    /// Use the whole limit: aim closer to it, and redo a pass that lands well under it.
    public var exactSize: Bool
    /// Long side of the picture (never above the source's). nil picks the sharpest that fits.
    public var longSide: Int?
    /// Keep 60 fps even when the limit is tight: smoother motion, softer frames.
    public var keepsHighFrameRate: Bool
    /// HEVC instead of H.264: about two thirds of the bits for the same look, plays in fewer places.
    public var hevc: Bool

    public init(exactSize: Bool = false, longSide: Int? = nil, keepsHighFrameRate: Bool = false, hevc: Bool = false) {
        self.exactSize = exactSize
        self.longSide = longSide
        self.keepsHighFrameRate = keepsHighFrameRate
        self.hevc = hevc
    }

    public static let standard = SizeChoices()

    /// Share of the limit to aim at. The rest absorbs the MP4 container and encoder overshoot.
    public var aim: Double { exactSize ? SizePlanner.exactAim : SizePlanner.safety }

    /// Bits this codec needs for the same look, relative to H.264.
    public var bitsFactor: Double { hevc ? 0.65 : 1 }
}

/// The arithmetic behind "fit this video under N bytes". Pure, so it's tested without any video.
public enum SizePlanner {
    /// Share of the limit we aim at normally. The rest absorbs the MP4 container and encoder overshoot.
    public static let safety = 0.92
    /// Share of the limit "Use the whole limit" aims at.
    public static let exactAim = 0.97
    /// "Use the whole limit" is happy with a file at least this share of the limit.
    public static let exactFloor = 0.95
    /// Below this the picture turns to mush, so we ask the person to trim instead.
    public static let minimumVideoBitsPerSecond = 120_000
    /// Bitrate that looks decent at 1920 px and 30 fps in H.264. Other sizes scale with pixel count.
    static let decentBitsAt1920 = 3_000_000.0
    static let standardLongSides = [3840, 2560, 1920, 1280, 960, 854, 640, 480]

    /// Bitrate a picture with this long side needs to look decent at this frame rate (in H.264).
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
        sourceVideoBitsPerSecond: Int? = nil,
        choices: SizeChoices
    ) -> SizePlan? {
        guard targetBytes > 0, durationSeconds > 0, sourceLongSide > 0 else { return nil }
        let total = Double(targetBytes) * 8 * choices.aim / durationSeconds
        let audio = hasAudio ? audioBitsPerSecond(forTotal: total) : 0
        let budget = Int(total) - audio
        // The floor is about the limit, not the source: a source that already has fewer bits than
        // this (a still screen recording) fits fine at its own rate.
        guard budget >= minimumVideoBitsPerSecond else { return nil }
        var video = budget
        // Never spend more than the source had (with room for H.264 being less efficient than HEVC).
        if let source = sourceVideoBitsPerSecond, source > 0 { video = min(video, source) }
        // The limit isn't what holds it back: keep the source's own size and frame rate.
        let cappedBySource = video < budget

        let sourceRate = sourceFrameRate > 0 ? sourceFrameRate : 30
        let chosenSide = choices.longSide.map { max(2, min($0, sourceLongSide)) }
        func decent(_ longSide: Int, _ frameRate: Double) -> Double {
            decentBitsPerSecond(longSide: longSide, frameRate: frameRate) * choices.bitsFactor
        }

        // Keep 60 fps only when the budget can carry it; otherwise every frame gets twice the bits at 30.
        let frameRate: Double
        if cappedBySource || choices.keepsHighFrameRate {
            frameRate = min(sourceRate, 60)
        } else {
            let keepsHighRate = Double(video) >= decent(min(chosenSide ?? sourceLongSide, 1920), sourceRate)
            frameRate = (sourceRate > 31 && !keepsHighRate) ? 30 : min(sourceRate, 60)
        }

        // The largest picture the budget can make look decent. Never upscale.
        let longSide: Int
        if let chosenSide {
            longSide = chosenSide
        } else if cappedBySource {
            longSide = sourceLongSide
        } else {
            let candidates = [sourceLongSide] + standardLongSides.filter { $0 < sourceLongSide }
            longSide = candidates.first { Double(video) >= decent($0, frameRate) } ?? candidates[candidates.count - 1]
        }

        return SizePlan(videoBitsPerSecond: video, audioBitsPerSecond: audio, maxLongSide: longSide, maxFrameRate: frameRate)
    }

    /// The longest a video can be and still fit under `targetBytes`: at all (the same floor `plan`
    /// uses), or looking sharp (decent bitrate at up to 720p or the chosen picture size, or the
    /// source's size if smaller). The trim screen and the batch check use these to say what fits.
    public static func longestSeconds(
        targetBytes: Int64, hasAudio: Bool, sourceLongSide: Int, sourceFrameRate: Double, sharp: Bool,
        choices: SizeChoices
    ) -> Double {
        guard targetBytes > 0 else { return 0 }
        let budget = Double(targetBytes) * 8 * choices.aim
        if !sharp {
            // The smallest total plan() accepts: the video floor plus the smallest audio.
            return budget / Double(minimumVideoBitsPerSecond + (hasAudio ? 64_000 : 0))
        }
        let side = choices.longSide.map { min($0, sourceLongSide) } ?? min(sourceLongSide, 1280)
        let rate = choices.keepsHighFrameRate ? min(max(sourceFrameRate, 1), 60) : 30
        let video = decentBitsPerSecond(longSide: max(1, side), frameRate: rate) * choices.bitsFactor
        return budget / (video + (hasAudio ? 128_000 : 0))
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
    public static func corrected(
        _ plan: SizePlan, deliveredBytes: Int64, targetBytes: Int64, durationSeconds: Double, choices: SizeChoices
    ) -> SizePlan? {
        guard deliveredBytes > 0, durationSeconds > 0, plan.videoBitsPerSecond > 0 else { return nil }
        let audio = Double(plan.audioBitsPerSecond)
        let deliveredVideo = Double(deliveredBytes) * 8 / durationSeconds - audio
        let overshoot = max(deliveredVideo / Double(plan.videoBitsPerSecond), 1)
        let wantedVideo = Double(targetBytes) * 8 * choices.aim / durationSeconds - audio
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

    /// Use the whole limit: after an encode came out well under the limit, the plan for one fuller
    /// try, or nil when there's nothing to gain (it already spends what the source had).
    public static func filled(
        _ plan: SizePlan, deliveredBytes: Int64, targetBytes: Int64, durationSeconds: Double,
        choices: SizeChoices, maxVideoBitsPerSecond: Int?
    ) -> SizePlan? {
        guard deliveredBytes > 0, durationSeconds > 0, plan.videoBitsPerSecond > 0 else { return nil }
        let audio = Double(plan.audioBitsPerSecond)
        let deliveredVideo = Double(deliveredBytes) * 8 / durationSeconds - audio
        guard deliveredVideo > 0 else { return nil }
        // How much of what we asked for the encoder actually used (under 1 when it undershot).
        let used = deliveredVideo / Double(plan.videoBitsPerSecond)
        let wantedVideo = Double(targetBytes) * 8 * choices.aim / durationSeconds - audio
        var video = Int(wantedVideo / used)
        // At most double in one step, and never past what the source had.
        video = min(video, plan.videoBitsPerSecond * 2)
        if let cap = maxVideoBitsPerSecond, cap > 0 { video = min(video, cap) }
        guard Double(video) > Double(plan.videoBitsPerSecond) * 1.02 else { return nil }
        var next = plan
        next.videoBitsPerSecond = video
        return next
    }
}
