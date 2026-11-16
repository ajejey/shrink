import SwiftUI

/// "Where is it going?": the destinations, "Type your own size limit", "Convert a photo to JPG" and the
/// location switch. Used by the app's home screen and by the share sheet.
struct DestinationList: View {
    enum Kind { case video, photo }

    /// What's being shrunk, when it's already known (the share sheet). nil in the app, where the
    /// Photos picker comes after the destination.
    let kind: Kind?
    @Binding var removeLocation: Bool
    let onPick: (Destination) -> Void

    @State private var showTypedLimit = false
    @State private var typed: Destination?

    var body: some View {
        List {
            Section {
                ForEach(destinations) { destination in
                    row(destination.title, detail: detail(for: destination)) { onPick(destination) }
                }
                row("Type your own size limit", detail: "For a form or site that says its limit") {
                    showTypedLimit = true
                }
            } header: {
                Text("Where is it going?")
            }
            if kind != .video {
                Section {
                    row(Destination.jpg.title, detail: "iPhone photos that open on Windows, Android and websites") {
                        onPick(.jpg)
                    }
                } header: {
                    Text("Photos")
                }
            }
            Section {
                Toggle("Remove location before sharing", isOn: $removeLocation)
            }
        }
        .sheet(isPresented: $showTypedLimit, onDismiss: {
            // Carry on once the sheet has gone, so the next screen isn't presented over a closing one.
            if let typed {
                self.typed = nil
                onPick(typed)
            }
        }) {
            TypedLimitView { limit in typed = .typed(limit) }
        }
    }

    private var destinations: [Destination] {
        switch kind {
        case .video: return Destination.presets.filter(\.takesVideos)
        case .photo: return Destination.presets.filter(\.takesPhotos)
        case nil: return Destination.presets
        }
    }

    private func row(_ title: String, detail: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .foregroundStyle(.primary)
    }

    /// "Fits under 20 MB", unless the title already says it ("Under 10 MB"); photos-only says so.
    private func detail(for destination: Destination) -> String? {
        var parts: [String] = []
        if let label = destination.limitLabel, !destination.title.contains(label) {
            parts.append("Fits under \(label)")
        }
        if kind == nil, !destination.takesVideos { parts.append("Photos") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
