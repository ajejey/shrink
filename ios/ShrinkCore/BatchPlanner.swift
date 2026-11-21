import Foundation

/// How several files share one place's limit when they're sent at once (Shrink Pro).
/// Each file under the limit (Discord, WhatsApp), or all of them together under it (one email, where
/// Gmail and Outlook count every attachment). Pure, so it's tested without any video.
public enum BatchPlanner {
    public struct Item: Equatable, Sendable {
        /// nil for a photo.
        public var seconds: Double?
        public var hasAudio: Bool
        public var longSide: Int
        public var frameRate: Double

        public static func video(seconds: Double, hasAudio: Bool, longSide: Int, frameRate: Double) -> Item {
            Item(seconds: seconds, hasAudio: hasAudio, longSide: longSide, frameRate: frameRate)
        }

        public static func photo(longSide: Int) -> Item {
            Item(seconds: nil, hasAudio: false, longSide: longSide, frameRate: 0)
        }
    }

    public enum Fit: Equatable, Sendable {
        case sharp
        /// Fits, but the picture will look soft.
        case soft
        case doesNotFit
    }

    /// One file's part of the limit.
    public struct Share: Equatable, Sendable {
        /// The size this file must come in under. nil means no limit (making photos into JPGs).
        public var targetBytes: Int64?
        public var fit: Fit
    }

    /// Most of an email that photos may take when they travel with videos, and the most one photo
    /// needs to stay sharp as a JPEG.
    static let photosPartOfEmail = 0.5
    static let sharpPhotoBytes: Int64 = 1_500_000
    /// Below this a photo can't be made small enough (PhotoShrinker's smallest copy is about this size).
    static let smallestPhotoBytes: Int64 = 30_000

    /// Each item's share, in the same order. `limit` nil means no limit (JPG only).
    public static func shares(for items: [Item], limit: Int64?, together: Bool, choices: SizeChoices) -> [Share] {
        guard let limit else { return items.map { _ in Share(targetBytes: nil, fit: .sharp) } }
        guard together else { return items.map { share($0, target: limit, choices: choices) } }

        let photoCount = items.filter { $0.seconds == nil }.count
        let totalSeconds = items.compactMap(\.seconds).reduce(0, +)
        let photoTarget: Int64
        if totalSeconds > 0 {
            let room = Int64(Double(limit) * photosPartOfEmail) / Int64(max(photoCount, 1))
            photoTarget = min(sharpPhotoBytes, room)
        } else {
            photoTarget = limit / Int64(max(photoCount, 1))
        }
        let videoBudget = limit - photoTarget * Int64(photoCount)
        return items.map { item in
            guard let seconds = item.seconds else { return share(item, target: photoTarget, choices: choices) }
            // Videos split what's left by length, so every second gets the same bits.
            let target = totalSeconds > 0 ? Int64(Double(videoBudget) * seconds / totalSeconds) : 0
            return share(item, target: target, choices: choices)
        }
    }

    /// One file against its own target.
    static func share(_ item: Item, target: Int64, choices: SizeChoices) -> Share {
        guard let seconds = item.seconds else {
            return Share(targetBytes: target, fit: target >= smallestPhotoBytes ? .sharp : .doesNotFit)
        }
        guard target > 0, seconds > 0 else { return Share(targetBytes: target, fit: .doesNotFit) }
        let fits = SizePlanner.longestSeconds(targetBytes: target, hasAudio: item.hasAudio, sourceLongSide: item.longSide,
                                              sourceFrameRate: item.frameRate, sharp: false, choices: choices)
        let sharp = SizePlanner.longestSeconds(targetBytes: target, hasAudio: item.hasAudio, sourceLongSide: item.longSide,
                                               sourceFrameRate: item.frameRate, sharp: true, choices: choices)
        let fit: Fit = seconds <= sharp ? .sharp : (seconds <= fits ? .soft : .doesNotFit)
        return Share(targetBytes: target, fit: fit)
    }
}
