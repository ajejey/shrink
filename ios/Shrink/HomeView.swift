import PhotosUI
import ShrinkCore
import SwiftUI

/// First screen: pick where the video is going, pick the video, get a file that fits.
/// The biggest text is the job ("Shrink a video", "Compress for Discord"), never a number.
struct HomeView: View {
    @State private var chosen: Preset?
    @State private var showPicker = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var removeLocation = true
    @State private var job = ShrinkJob()

    private let presets = Presets.all.filter { $0.appliesToVideo && $0.limitBytes != nil }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(presets) { preset in
                        Button {
                            chosen = preset
                            showPicker = true
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.title)
                                    .font(.headline)
                                // "Under 10 MB" already says it; don't repeat it underneath.
                                if let label = preset.limitLabel, !preset.title.contains(label) {
                                    Text("Fits under \(label)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Where is it going?")
                }
                Section {
                    Toggle("Remove location before sharing", isOn: $removeLocation)
                }
            }
            .navigationTitle("Shrink a video")
            .photosPicker(isPresented: $showPicker, selection: $pickedItem, matching: .videos, preferredItemEncoding: .current)
            .onChange(of: pickedItem) { _, item in
                guard let item, let preset = chosen else { return }
                pickedItem = nil
                job.open(item: item, preset: preset, removeLocation: removeLocation)
            }
            // A full, solid screen: the first demo's half sheet let the destination list show through.
            .fullScreenCover(isPresented: $job.isShowing) {
                ShrinkJobView(job: job)
            }
        }
    }
}
