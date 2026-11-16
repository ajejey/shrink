import SwiftUI

@main
struct ShrinkApp: App {
    /// CI opens the app with `-screenshot shrinking` (or trim, done, failed, settings, places) to
    /// photograph each screen without running a real job. A person opening the app never passes it.
    private let screenshot = UserDefaults.standard.string(forKey: "screenshot")

    var body: some Scene {
        WindowGroup {
            switch screenshot {
            case nil:
                HomeView()
            case "settings"?:
                SettingsView()
            case "places"?:
                NavigationStack {
                    DestinationList(kind: nil, showsHeader: false) { _ in }
                        .navigationTitle("Where is it going?")
                }
            case let state?:
                ShrinkJobView(job: .preview(state))
                    .environment(\.canReportProblem, true)
            }
        }
    }
}
