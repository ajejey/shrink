import AppIntents
import SwiftUI

/// "Shrink a video for Discord", "Free up space", "Clean up photos" and the quick extras ("Make a GIF"),
/// in Siri and Spotlight with no setup. Each opens the app at the right place: the Photos picker for
/// that destination or extra, Free up space, or Clean up photos.
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
        AppShortcut(
            intent: CleanUpPhotosIntent(),
            phrases: [
                "Clean up photos with \(.applicationName)",
                "Delete duplicate photos with \(.applicationName)",
                "Delete screenshots with \(.applicationName)",
            ],
            shortTitle: "Clean up photos",
            systemImageName: "photo.stack"
        )
        AppShortcut(
            intent: MakeGIFIntent(),
            phrases: [
                "Make a GIF with \(.applicationName)",
                "Turn a video into a GIF with \(.applicationName)",
                "Make a GIF from a Live Photo with \(.applicationName)",
            ],
            shortTitle: "Make a GIF",
            systemImageName: "square.stack.3d.forward.dottedline"
        )
        AppShortcut(
            intent: MuteVideoIntent(),
            phrases: [
                "Mute a video with \(.applicationName)",
                "Remove the sound from a video with \(.applicationName)",
            ],
            shortTitle: "Mute a video",
            systemImageName: "speaker.slash"
        )
        AppShortcut(
            intent: GetSoundIntent(),
            phrases: [
                "Get the sound from a video with \(.applicationName)",
                "Extract the audio from a video with \(.applicationName)",
            ],
            shortTitle: "Get the sound",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: SaveFrameIntent(),
            phrases: [
                "Save a frame from a video with \(.applicationName)",
                "Get a photo from a video with \(.applicationName)",
            ],
            shortTitle: "Save a frame",
            systemImageName: "photo"
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

struct CleanUpPhotosIntent: AppIntent {
    static var title: LocalizedStringResource = "Clean up photos"
    static var description = IntentDescription("Sort out duplicates, screenshots, blurry shots and other photos you may not need.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        ShortcutRouter.shared.request = .cleanUp
        return .result()
    }
}

struct MakeGIFIntent: AppIntent {
    static var title: LocalizedStringResource = "Make a GIF"
    static var description = IntentDescription("Turn part of a video or a Live Photo into a GIF.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        ShortcutRouter.shared.request = .quick("gif")
        return .result()
    }
}

struct MuteVideoIntent: AppIntent {
    static var title: LocalizedStringResource = "Mute a video"
    static var description = IntentDescription("Make a copy of a video with no sound.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        ShortcutRouter.shared.request = .quick("mute")
        return .result()
    }
}

struct GetSoundIntent: AppIntent {
    static var title: LocalizedStringResource = "Get the sound from a video"
    static var description = IntentDescription("Save a video's sound as an audio file.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        ShortcutRouter.shared.request = .quick("sound")
        return .result()
    }
}

struct SaveFrameIntent: AppIntent {
    static var title: LocalizedStringResource = "Save a frame as a photo"
    static var description = IntentDescription("Pick a moment in a video and save it to Photos.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        ShortcutRouter.shared.request = .quick("frame")
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
        case cleanUp
        /// A quick extra: QuickJob.Kind's raw value ("gif", "mute", "sound", "frame").
        case quick(String)
    }

    var request: Request?
}
