import Foundation

/// One destination's limit, from shared/presets.json (the same file the website reads).
public struct Preset: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    /// The job in the person's words: "Compress for Discord".
    public let title: String
    /// The platform's name alone ("Discord"), for buttons with little room. nil falls back to the title.
    public let short: String?
    public let limitBytes: Int64?
    public let limitLabel: String?
    /// The limit covers everything in one message, not each file (Gmail and Outlook count every
    /// attachment in the email together). Matters when several files go at once.
    public let perMessage: Bool?
    public let media: [String]?
    public let confidence: String?
    public let notes: String?
    /// The platform's own help page for the limit. nil for generic sizes ("Under 25 MB").
    public let source: String?
    public let checked: String?

    public var appliesToVideo: Bool { media?.contains("video") ?? true }
    public var appliesToPhoto: Bool { media?.contains("photo") ?? true }
    public var limitIsPerMessage: Bool { perMessage ?? false }
}

public struct PresetCatalog: Codable, Sendable {
    public let version: Int
    public let checked: String?
    public let presets: [Preset]
}

public enum Presets {
    public static func load(from bundle: Bundle = .shrinkCore) throws -> PresetCatalog {
        guard let url = bundle.url(forResource: "presets", withExtension: "json") else {
            throw ShrinkError.couldNotRead("presets.json is missing from the app.")
        }
        return try JSONDecoder().decode(PresetCatalog.self, from: Data(contentsOf: url))
    }

    /// Every preset, in the file's order. Empty only if the bundled file is broken (a test catches that).
    public static let all: [Preset] = (try? load().presets) ?? []
}

extension Bundle {
    public static let shrinkCore = Bundle(for: BundleToken.self)
}

private final class BundleToken {}
