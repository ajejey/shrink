import Foundation

/// Settings and small memories that the app and the share sheet both read. They share one App Group
/// once signing includes it; until then (and on the unsigned simulator) each keeps its own copy.
enum AppSettings {
    static let defaults = UserDefaults(suiteName: "group.com.useshrink.app") ?? .standard
    static let removeLocationKey = "removeLocation"

    /// On unless the person turns it off in Settings: what they send goes out without the place it was taken.
    static var removeLocation: Bool {
        defaults.object(forKey: removeLocationKey) as? Bool ?? true
    }

    static let proKey = "proUnlocked"

    /// Shrink Pro as the app last saw it in the App Store's records. The app writes it (Store.swift);
    /// the share sheet reads it from here, since it has no store of its own.
    static var isPro: Bool { defaults.bool(forKey: proKey) }

    static func setPro(_ on: Bool) {
        if defaults.bool(forKey: proKey) != on { defaults.set(on, forKey: proKey) }
    }
}

/// The places someone sent to most recently, shown as one-tap buttons on Home.
enum RecentPlaces {
    private static let key = "recentPlaces"

    /// Shown until someone has sent something: the biggest jobs in the search data.
    static var popular: [Destination] {
        ["discord", "gmail", "whatsapp"].compactMap { Destination.find(id: $0) }
    }

    /// Most recent first, at most three.
    static func load() -> [Destination] {
        (AppSettings.defaults.stringArray(forKey: key) ?? []).compactMap { Destination.find(id: $0) }
    }

    /// Presets and "Convert a photo to JPG" only; a typed limit is a one-off.
    static func remember(_ destination: Destination) {
        guard Destination.find(id: destination.id) != nil else { return }
        var ids = AppSettings.defaults.stringArray(forKey: key) ?? []
        ids.removeAll { $0 == destination.id }
        ids.insert(destination.id, at: 0)
        AppSettings.defaults.set(Array(ids.prefix(3)), forKey: key)
    }
}

/// Apple's review prompt, only right after something worked: the 2nd finished file, then every 10th.
/// Apple itself shows it at most three times a year, whatever we ask. Never after an error or a price.
enum ReviewPrompt {
    private static let key = "finishedFiles"

    /// Counts one finished file. True when this is a good moment to ask.
    static func recordSuccess() -> Bool {
        let count = AppSettings.defaults.integer(forKey: key) + 1
        AppSettings.defaults.set(count, forKey: key)
        return count == 2 || (count > 2 && count % 10 == 0)
    }
}
