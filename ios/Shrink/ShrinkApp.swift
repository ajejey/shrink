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

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let e2e {
                E2EView(mode: e2e)
            } else {
                screen
            }
            #else
            screen
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
            HomeView(freeUp: .preview())
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
        case let state?:
            ShrinkJobView(job: .preview(state))
        }
    }
}
