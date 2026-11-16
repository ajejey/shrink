import PhotosUI
import ShrinkCore
import SwiftUI

/// First screen: pick where it's going, pick the video or photo, get a file that fits.
/// The biggest text is the job ("Compress for Discord", "Convert a photo to JPG"), never a number.
struct HomeView: View {
    @State private var chosen: Destination?
    @State private var showPicker = false
    @State private var showTypedLimit = false
    /// The typed limit was entered: open the picker once its sheet has gone.
    @State private var pickAfterLimit = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var removeLocation = true
    @State private var job = ShrinkJob()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Destination.presets) { destination in
                        row(destination.title, detail: detail(for: destination)) { pick(for: destination) }
                    }
                    row("Type your own size limit", detail: "For a form or site that says its limit") {
                        showTypedLimit = true
                    }
                } header: {
                    Text("Where is it going?")
                }
                Section {
                    row(Destination.jpg.title, detail: "iPhone photos that open on Windows, Android and websites") {
                        pick(for: .jpg)
                    }
                } header: {
                    Text("Photos")
                }
                Section {
                    Toggle("Remove location before sharing", isOn: $removeLocation)
                }
            }
            .navigationTitle("Shrink a video or photo")
            .photosPicker(isPresented: $showPicker, selection: $pickedItem,
                          matching: chosen?.pickerFilter ?? .videos, preferredItemEncoding: .current)
            .onChange(of: pickedItem) { _, item in
                guard let item, let destination = chosen else { return }
                pickedItem = nil
                job.open(item: item, destination: destination, removeLocation: removeLocation)
            }
            .sheet(isPresented: $showTypedLimit, onDismiss: {
                if pickAfterLimit {
                    pickAfterLimit = false
                    showPicker = true
                }
            }) {
                TypedLimitView { limit in
                    chosen = .typed(limit)
                    pickAfterLimit = true
                }
            }
            // A full, solid screen: the first demo's half sheet let the destination list show through.
            .fullScreenCover(isPresented: $job.isShowing) {
                ShrinkJobView(job: job)
            }
        }
    }

    private func pick(for destination: Destination) {
        chosen = destination
        showPicker = true
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
        if !destination.takesVideos { parts.append("Photos") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
