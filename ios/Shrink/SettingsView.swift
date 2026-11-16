import SwiftUI

/// Settings: the location switch, help and privacy. Pro and Free up space join this list when they ship.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.removeLocationKey, store: AppSettings.defaults) private var removeLocation = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Remove location before sharing", isOn: $removeLocation)
                } header: {
                    Text("Sending")
                } footer: {
                    Text("Videos and photos you send go out without the place they were taken.")
                }

                if let url = ProblemReport().mailtoURL {
                    Section("Help") {
                        Link(destination: url) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Report a problem")
                                Text("Opens an email with the details filled in")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Privacy") {
                    Text("Everything happens on your iPhone. Your videos and photos are never uploaded.")
                }

                Section {
                    LabeledContent("Version", value: ProblemReport.appVersion)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
