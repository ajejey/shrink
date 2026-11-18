import Photos
import ShrinkCore
import SwiftUI
import UIKit

/// Swipe through a pile one photo at a time, month by month, newest first: left to delete (in the Live
/// Photos pile, to keep just the photo), right to keep. Undo steps back. Each answer is the same pick as
/// tapping the photo in the grid, so nothing happens until the check screen.
struct SwipeReview: View {
    let model: PhotoCleanup
    let kind: PileKind
    @Environment(\.dismiss) private var dismiss
    @State private var sections: [(start: Date?, items: [CleanupItem])] = []
    @State private var loaded = false
    @State private var month = 0
    @State private var index = 0
    @State private var history: [Step] = []
    @State private var drag: CGSize = .zero

    private struct Step {
        let month: Int
        let index: Int
        let item: CleanupItem
        let wasPicked: Bool
    }

    /// "Delete", or "Photo only" for Live Photos.
    private var goWord: String { kind == .livePhotos ? "Photo only" : "Delete" }
    /// How a marked photo is described: "6 to delete", "6 photo only".
    private var markedWord: String { kind == .livePhotos ? "photo only" : "to delete" }
    private var goIcon: String { kind == .livePhotos ? "livephoto.slash" : "trash" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if loaded && sections.isEmpty {
                    Spacer()
                    Text("Nothing to go through")
                        .font(.title2.bold())
                    Spacer()
                } else if let item = current {
                    header
                    card(item)
                    buttons(item)
                } else if loaded {
                    monthDone
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                guard !loaded else { return }
                sections = Months.sections(model.piles[kind]?.items ?? []) { $0.created }
                loaded = true
            }
        }
    }

    private var current: CleanupItem? {
        guard month < sections.count, index < sections[month].items.count else { return nil }
        return sections[month].items[index]
    }

    private var monthItems: [CleanupItem] {
        month < sections.count ? sections[month].items : []
    }

    private var pickedThisMonth: Int {
        monthItems.filter { model.isPicked($0, in: kind) }.count
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(MonthTitle.string(month < sections.count ? sections[month].start : nil))
                .font(.title2.bold())
            Text("\(index + 1) of \(monthItems.count) · \(pickedThisMonth) \(markedWord)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func card(_ item: CleanupItem) -> some View {
        VStack(spacing: 8) {
            AssetPicture(id: item.id)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(alignment: .topLeading) {
                    stamp(goWord, color: .red).opacity(drag.width < -30 ? min(1, Double(-drag.width - 30) / 80) : 0)
                }
                .overlay(alignment: .topTrailing) {
                    stamp("Keep", color: .green).opacity(drag.width > 30 ? min(1, Double(drag.width - 30) / 80) : 0)
                }
                .overlay(alignment: .bottomTrailing) {
                    if model.isPicked(item, in: kind) {
                        Label(kind == .livePhotos ? "Photo only" : "To delete", systemImage: goIcon)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.6), in: Capsule())
                            .padding(10)
                    }
                }
                .offset(x: drag.width, y: drag.height * 0.15)
                .rotationEffect(.degrees(Double(drag.width) / 25))
                .gesture(
                    DragGesture()
                        .onChanged { drag = $0.translation }
                        .onEnded { value in
                            if value.translation.width < -110 {
                                decide(item, go: true)
                            } else if value.translation.width > 110 {
                                decide(item, go: false)
                            }
                            withAnimation(.spring(duration: 0.25)) { drag = .zero }
                        }
                )
            Text(detail(item))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxHeight: .infinity)
    }

    private func detail(_ item: CleanupItem) -> String {
        var parts: [String] = []
        if let created = item.created { parts.append(created.formatted(date: .abbreviated, time: .shortened)) }
        if item.isVideo { parts.append(Clock.string(item.duration)) }
        parts.append(kind == .livePhotos ? "frees \(SizeFormat.string(item.stillSaving))" : SizeFormat.string(item.bytes))
        return parts.joined(separator: " · ")
    }

    private func stamp(_ text: String, color: Color) -> some View {
        Text(text.uppercased())
            .font(.title2.weight(.heavy))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color, lineWidth: 3))
            .background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
            .padding(16)
    }

    private func buttons(_ item: CleanupItem) -> some View {
        HStack(spacing: 12) {
            Button {
                decide(item, go: true)
            } label: {
                Label(goWord, systemImage: goIcon).font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            Button {
                undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.headline)
                    .frame(width: 44)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(history.isEmpty)
            .accessibilityLabel("Undo")
            Button {
                decide(item, go: false)
            } label: {
                Label("Keep", systemImage: "checkmark").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.large)
        }
    }

    private var monthDone: some View {
        let title = MonthTitle.string(month < sections.count ? sections[month].start : nil)
        let marked = pickedThisMonth
        return VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("\(title) done")
                .font(.title.bold())
            Text("\(marked) \(markedWord), \(monthItems.count - marked) kept")
                .foregroundStyle(.secondary)
            Spacer()
            if month + 1 < sections.count {
                Button {
                    month += 1
                    index = 0
                } label: {
                    Text("Next: \(MonthTitle.string(sections[month + 1].start))").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            Button {
                dismiss()
            } label: {
                Text("Back to the pile").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            Button("Undo") { undo() }
                .disabled(history.isEmpty)
        }
        .multilineTextAlignment(.center)
    }

    private func decide(_ item: CleanupItem, go: Bool) {
        history.append(Step(month: month, index: index, item: item, wasPicked: model.isPicked(item, in: kind)))
        model.set(item, in: kind, picked: go)
        index += 1
    }

    private func undo() {
        guard let last = history.popLast() else { return }
        model.set(last.item, in: kind, picked: last.wasPicked)
        month = last.month
        index = last.index
    }
}

/// A library photo as big as it fits, for swiping.
struct AssetPicture: View {
    let id: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if id.hasPrefix("preview-") {
                PreviewArt(id: id)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
        .task(id: id) { image = await AssetThumbnail.load(id, pixels: 1400, mode: .aspectFit) }
    }
}
