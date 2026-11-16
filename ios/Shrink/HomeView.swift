import PhotosUI
import StoreKit
import SwiftUI

/// Home: the two jobs, in the person's words. "Send a video or photo" with one-tap places, and (next)
/// "Free up space". No intro screens: people open the app with a problem, so the job comes first.
struct HomeView: View {
    @State private var chosen: Destination?
    @State private var showPicker = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var job = ShrinkJob()
    @State private var showPlaces = false
    @State private var showSettings = false
    @State private var recents = RecentPlaces.load()
    @Environment(\.requestReview) private var requestReview

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    SendCard(places: recents.isEmpty ? RecentPlaces.popular : recents,
                             isRecent: !recents.isEmpty,
                             onPick: pick,
                             onAllPlaces: { showPlaces = true })
                    Text("Everything happens on your iPhone. Nothing is uploaded.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Shrink")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { AppName() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .navigationDestination(isPresented: $showPlaces) {
                PlacesView(onPick: pick)
            }
        }
        .photosPicker(isPresented: $showPicker, selection: $pickedItem,
                      matching: chosen?.pickerFilter ?? .videos, preferredItemEncoding: .current)
        .onChange(of: pickedItem) { _, item in
            guard let item, let destination = chosen else { return }
            pickedItem = nil
            job.offersAnother = true
            job.open(item: item, destination: destination, removeLocation: AppSettings.removeLocation)
        }
        // A full, solid screen: the first demo's half sheet let the list behind show through.
        .fullScreenCover(isPresented: $job.isShowing, onDismiss: jobClosed) {
            ShrinkJobView(job: job)
                .environment(\.canReportProblem, true)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    private func pick(_ destination: Destination) {
        chosen = destination
        showPicker = true
    }

    /// Runs once the job screen has fully closed, so the next screen never opens over a closing one.
    private func jobClosed() {
        recents = RecentPlaces.load()
        showPlaces = false
        if job.takeWantsAnother() {
            showPicker = true
        } else if case .done = job.phase, ReviewPrompt.recordSuccess() {
            requestReview()
        }
    }
}

/// "Send a video or photo": the job, then the places as one-tap buttons, then every place.
private struct SendCard: View {
    let places: [Destination]
    /// Recently used places, or the popular ones before anything has been sent.
    let isRecent: Bool
    let onPick: (Destination) -> Void
    let onAllPlaces: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send a video or photo")
                .font(.title.bold())
            if !isRecent {
                Text("Make it fit Discord, email, WhatsApp, a form, or any size limit.")
                    .foregroundStyle(.secondary)
            }
            Text(isRecent ? "Recent" : "Popular")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            FlowLayout(spacing: 8) {
                ForEach(places) { place in
                    Button {
                        onPick(place)
                    } label: {
                        chip(Text(place.shortTitle))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(place.title)
                }
                Button(action: onAllPlaces) {
                    chip(Text("All places \(Image(systemName: "chevron.right"))"))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            }
            Label {
                Text("Free, as many as you like")
            } icon: {
                Image(systemName: "checkmark").foregroundStyle(.green)
            }
            .font(.subheadline)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private func chip(_ text: Text) -> some View {
        text
            .font(.body.weight(.semibold))
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(Color(.tertiarySystemGroupedBackground), in: Capsule())
            .contentShape(Capsule())
    }
}

/// "All places": every destination, a typed limit, and photo to JPG.
private struct PlacesView: View {
    let onPick: (Destination) -> Void

    var body: some View {
        DestinationList(kind: nil, showsHeader: false, onPick: onPick)
            .navigationTitle("Where is it going?")
            .navigationBarTitleDisplayMode(.large)
    }
}

/// The app's name with a small copy of its icon, at the top of Home.
private struct AppName: View {
    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 7)
                .fill(LinearGradient(colors: [Color(red: 0.145, green: 0.388, blue: 0.922),
                                              Color(red: 0.486, green: 0.227, blue: 0.929)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)
            Text("Shrink")
                .font(.headline)
        }
    }
}

/// Lays its children out in rows, wrapping to the next row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
