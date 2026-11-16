import SwiftUI

@main
struct ShrinkApp: App {
    /// CI opens the app with `-screenshot shrinking` (or done, failed) to photograph each screen
    /// without running a real job. A person opening the app never passes it.
    private let screenshot = UserDefaults.standard.string(forKey: "screenshot")

    var body: some Scene {
        WindowGroup {
            if let screenshot {
                ShrinkJobView(job: .preview(screenshot))
            } else {
                HomeView()
            }
        }
    }
}
