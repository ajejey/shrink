import AppIntents
import SwiftUI

/// "Shrink a video for Discord" and "Free up space", in Siri and Spotlight with no setup.
/// Each opens the app at the right place: the Photos picker for that destination, or Free up space.
struct ShrinkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShrinkVideoIntent(),
            phrases: [
                "Shrink a video for \(\.$place) with \(.applicationName)",
                "Compress a video for \(\.$place) with \(.applicationName)",
            ],
            shortTitle: "Shrink a video",
            systemImageName: "arrow.down.right.and.arrow.up.left"
        )
        AppShortcut(
            intent: FreeUpSpaceIntent(),
            phrases: [
                "Free up space with \(.applicationName)",
                "Free up storage with \(.applicationName)",
            ],
            shortTitle: "Free up space",
            systemImageName: "gauge.with.needle"
        )
    }
}

/// The places Siri and Spotlight can name.
enum ShortcutPlace: String, AppEnum {
    case discord
    case gmail
    case outlook
    case whatsapp
    case imessage
    case googleForms = "google-forms"
    case under10MB = "under-10mb"
    case under25MB = "under-25mb"

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Place"
    static var caseDisplayRepresentations: [ShortcutPlace: DisplayRepresentation] = [
        .discord: "Discord",
        .gmail: "Gmail",
        .outlook: "Outlook",
        .whatsapp: "WhatsApp",
        .imessage: "iMessage",
        .googleForms: "a Google Form",
        .under10MB: "under 10 MB",
        .under25MB: "under 25 MB",
    ]
}

struct ShrinkVideoIntent: AppIntent {
    static var title: LocalizedStringResource = "Shrink a video"
    static var description = IntentDescription("Make a video fit where it's going: Discord, email, WhatsApp and more.")
    static var openAppWhenRun = true

    @Parameter(title: "Place")
    var place: ShortcutPlace

    @MainActor
    func perform() async throws -> some IntentResult {
        ShortcutRouter.shared.request = .send(place.rawValue)
        return .result()
    }
}

struct FreeUpSpaceIntent: AppIntent {
    static var title: LocalizedStringResource = "Free up space"
    static var description = IntentDescription("Find the videos taking the most room and shrink them.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        ShortcutRouter.shared.request = .freeUp
        return .result()
    }
}

/// Hands a shortcut to Home, which opens the right screen.
@Observable
@MainActor
final class ShortcutRouter {
    static let shared = ShortcutRouter()

    enum Request: Equatable {
        /// A destination's id from presets.json.
        case send(String)
        case freeUp
    }

    var request: Request?
}
