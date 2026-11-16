import SwiftUI

/// Settings: Pro, the location switch, help and privacy.
struct SettingsView: View {
    private var store: Store { .shared }
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.removeLocationKey, store: AppSettings.defaults) private var removeLocation = true
    @State private var showPro = false

    var body: some View {
        NavigationStack {
            List {
                Section("Shrink Pro") {
                    if store.isPro {
                        Label("Pro is on: Free up space has no limit", systemImage: "checkmark.seal.fill")
                    } else {
                        Button {
                            showPro = true
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Get Pro").font(.headline)
                                Text("Free up space with no limit")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button("Restore purchase") {
                            Task { await store.restore() }
                        }
                        .disabled(store.purchasing)
                    }
                }

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
                    NavigationLink {
                        PrivacyView(showsDone: false)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Privacy policy")
                            Text("Everything happens on your iPhone. Nothing is uploaded.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    LabeledContent("Version", value: ProblemReport.appVersion)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showPro) { ProView() }
            .alert("Shrink Pro", isPresented: Binding(get: { store.message != nil && !showPro },
                                                      set: { if !$0 { store.message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(store.message ?? "")
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
