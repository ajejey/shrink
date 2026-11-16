import Foundation

/// Everything that can stop a shrink, in words a person can act on.
public enum ShrinkError: LocalizedError, Equatable {
    case noVideo
    case tooLongToFit
    case couldNotRead(String)
    case couldNotWrite(String)
    case stillTooBig(bytes: Int64)
    case trimTooShort
    /// A photo limit so small that even a small, low-quality copy is over it.
    case limitTooSmall
    /// Free up space: the copy came out no smaller than the original, so it isn't worth replacing.
    case notSmaller
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notSmaller:
            return "This video is already about as small as it can be. It was left as it is."
        case .limitTooSmall:
            return "That limit is too small for a photo. Even a small, low-quality copy is bigger. Try a bigger limit."
        case .trimTooShort:
            return "The part you picked is too short. Drag the ends further apart."
        case .noVideo:
            return "This file has no video in it."
        case .tooLongToFit:
            return "This video is too long to fit under that size and still be watchable. Trim it shorter and try again."
        case .couldNotRead(let why):
            return "Couldn't read this file. \(why)"
        case .couldNotWrite(let why):
            return "Couldn't make the smaller file. \(why)"
        case .stillTooBig:
            return "Couldn't get this under the limit. Trim it shorter and try again."
        case .cancelled:
            return "Stopped."
        }
    }
}
