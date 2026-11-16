import PhotosUI
import SwiftUI

/// First screen: pick where it's going, pick the video or photo, get a file that fits.
/// The biggest text is the job ("Compress for Discord", "Convert a photo to JPG"), never a number.
struct HomeView: View {
    @State private var chosen: Destination?
    @State private var showPicker = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var removeLocation = true
    @State private var job = ShrinkJob()

    var body: some View {
        NavigationStack {
            DestinationList(kind: nil, removeLocation: $removeLocation) { destination in
                chosen = destination
                showPicker = true
            }
            .navigationTitle("Shrink a video or photo")
            .photosPicker(isPresented: $showPicker, selection: $pickedItem,
                          matching: chosen?.pickerFilter ?? .videos, preferredItemEncoding: .current)
            .onChange(of: pickedItem) { _, item in
                guard let item, let destination = chosen else { return }
                pickedItem = nil
                job.open(item: item, destination: destination, removeLocation: removeLocation)
            }
            // A full, solid screen: the first demo's half sheet let the destination list show through.
            .fullScreenCover(isPresented: $job.isShowing) {
                ShrinkJobView(job: job)
            }
        }
    }
}
