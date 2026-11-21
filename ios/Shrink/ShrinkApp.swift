import SwiftUI

@main
struct ShrinkApp: App {
    /// CI opens the app with `-screenshot shrinking` (or trim, done, failed, settings, places, freeup-…) to
    /// photograph each screen without running a real job. A person opening the app never passes it.
    private let screenshot = UserDefaults.standard.string(forKey: "screenshot")
    #if DEBUG
    /// CI's Free up space end-to-end test (E2EHooks.swift). Debug builds only.
    private let e2e = UserDefaults.standard.string(forKey: "e2e")
    #endif

    init() {
        // The Sending options screenshot shows some options picked (saved, as a person would).
        if screenshot == "options" {
            SendingOptions(usesWholeLimit: true, format: .hevc, pictureSize: .hd).save()
        }
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let e2e {
                E2EView(mode: e2e)
            } else {
                screen.environment(\.proScreen, .app)
            }
            #else
            screen.environment(\.proScreen, .app)
            #endif
        }
    }

    @ViewBuilder private var screen: some View {
        switch screenshot {
        case nil:
            HomeView()
        case "settings"?:
            SettingsView()
        case "freeup-home"?:
            Self.homePreview()
        case "cleanup-intro"?:
            NavigationStack { PhotoCleanupScreen(model: .preview(access: .notAsked)) }
        case "cleanup-piles"?:
            NavigationStack { PhotoCleanupScreen(model: .preview()) }
        case "cleanup-looking"?:
            NavigationStack { PhotoCleanupScreen(model: .preview(looking: true)) }
        case "cleanup-screenshots"?:
            NavigationStack { PileView(model: .preview(), kind: .screenshots) }
        case "cleanup-similar"?:
            NavigationStack { PileView(model: .preview(), kind: .similar) }
        case "cleanup-live"?:
            NavigationStack { PileView(model: .preview(), kind: .livePhotos) }
        case "cleanup-swipe"?:
            SwipeReview(model: .preview(), kind: .screenshots)
        case "cleanup-check"?:
            NavigationStack { PhotoCleanupCheck(model: .preview()) }
        case "cleanup-working"?, "cleanup-done"?, "cleanup-declined"?:
            PhotoCleanupRunView(model: .previewRun(screenshot ?? ""))
        case "freeup-intro"?:
            NavigationStack { FreeUpSpaceScreen(model: .preview(access: .notAsked)) }
        case "freeup-pick"?:
            NavigationStack { FreeUpSpaceScreen(model: .preview()) }
        case "freeup-check"?:
            NavigationStack { FreeUpSpaceCheck(model: .preview()) }
        case "freeup-over"?:
            NavigationStack { FreeUpSpaceScreen(model: .preview(pickAll: true)) }
        case "pro"?:
            ProView(preview: .preview())
        case "pro-several"?:
            ProView(reason: .several, preview: .preview())
        case "options"?:
            NavigationStack { SendingOptionsView(previewPro: true) }
        case "options-free"?:
            NavigationStack { SendingOptionsView(previewPro: false) }
        case let state? where state.hasPrefix("batch-"):
            BatchSendView(model: .preview(state))
        case "freeup-working"?, "freeup-done"?, "freeup-kept"?, "freeup-full"?, "freeup-paused"?:
            FreeUpSpaceRunView(model: .previewRun(screenshot ?? ""))
        case "places"?:
            NavigationStack {
                DestinationList(kind: nil, showsHeader: false) { _ in }
                    .navigationTitle("Where is it going?")
            }
        case "report"?:
            ReportProblemView(report: ProblemReport(job: "Compress for Discord (20 MB)",
                                                    problem: "The video couldn't be read."))
        case "report-sent"?:
            ReportProblemView(report: ProblemReport(), showsSent: true)
        case let state? where state.hasPrefix("quick-"):
            QuickJobView(job: .preview(state))
        case let state?:
            ShrinkJobView(job: .preview(state))
        }
    }

    /// Home after both scans, sharing one frozen Free up space.
    @MainActor private static func homePreview() -> HomeView {
        let freeUp = FreeUpSpace.preview()
        return HomeView(freeUp: freeUp, cleanup: .preview(freeUp: freeUp))
    }
}
