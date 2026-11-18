import ShrinkCore
import SwiftUI
import UIKit

/// The pushed screen: an intro until Photos access is asked, then the piles.
struct PhotoCleanupScreen: View {
    @Bindable var model: PhotoCleanup
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch model.freeUp.access {
        case .notAsked:
            PhotoCleanupIntro(model: model)
        case .denied:
            VStack(spacing: 16) {
                Text("Shrink can't see your photos")
                    .font(.title2.bold())
                Text("Allow access to Photos in Settings, then come back.")
                    .foregroundStyle(.secondary)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.borderedProminent)
            }
            .multilineTextAlignment(.center)
            .padding(24)
        case .limited, .full:
            PilesView(model: model)
        }
    }
}

/// First time only: what happens, before iOS asks for Photos access.
private struct PhotoCleanupIntro: View {
    let model: PhotoCleanup
    @State private var asking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Clean up photos")
                    .font(.largeTitle.bold())
                Text("Shrink sorts out photos you may not need: duplicates, screenshots, blurry shots and more. You choose what goes.")
                    .foregroundStyle(.secondary)
            }
            IntroPoint(icon: "iphone", title: "Nothing leaves your iPhone",
                       detail: "Your photos are looked at right here. Nothing is uploaded.")
            IntroPoint(icon: "checkmark.square", title: "You pick every photo",
                       detail: "Only exact duplicates come picked, and you see everything before it goes.")
            IntroPoint(icon: "arrow.uturn.backward", title: "Photos can come back",
                       detail: "They go to Recently Deleted, where Photos keeps them for 30 days.")
            IntroPoint(icon: "gauge.with.needle", title: "Your first 5 GB is free",
                       detail: "See how much you'd free before paying anything.")
            Spacer(minLength: 0)
            Text("Next, iPhone asks to let Shrink see your photos. Choose Allow Full Access so Shrink can look at all of them.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                asking = true
                Task {
                    await model.freeUp.requestAccess()
                    asking = false
                }
            } label: {
                Text("Look at my photos").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(asking)
        }
        .padding(24)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// An icon in a circle, a bold line and a quieter one.
struct IntroPoint: View {
    let icon: String
    let title: String
    let detail: String
    var iconSize: CGFloat = 40

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: iconSize * 0.45, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: iconSize, height: iconSize)
                .background(Color.accentColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Piles

/// "Clean up photos": every pile with its count and size. The quick piles show at once; the rest fill
/// in during the closer look.
struct PilesView: View {
    @Bindable var model: PhotoCleanup

    var body: some View {
        Group {
            switch model.scan {
            case .notStarted, .listing:
                scanning
            case .finished where model.visibleKinds.isEmpty:
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.green)
                    Text("Nothing to clean up")
                        .font(.title2.bold())
                    Text("No duplicates, screenshots or other piles turned up.")
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding(24)
            default:
                list
            }
        }
        .navigationTitle("Clean up photos")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.start() }
    }

    private var scanning: some View {
        VStack(spacing: 18) {
            Text("Looking at your photos")
                .font(.title2.bold())
            if case .listing(let checked, let total) = model.scan, total > 0 {
                Text("Checked \(checked.formatted()) of \(total.formatted())")
                    .monospacedDigit()
                ProgressView(value: Double(checked), total: Double(total))
            } else {
                ProgressView()
            }
            Text("This first reads dates and sizes, so it takes a few seconds. Nothing changes yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(32)
    }

    private var list: some View {
        List {
            Section {
                if case .looking(let done, let total) = model.scan {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Taking a closer look: \(done.formatted()) of \(total.formatted()) photos")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                        ProgressView(value: Double(done), total: Double(max(total, 1)))
                        Text("Duplicates, similar shots and more fill in as it goes. It only looks at each photo once.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                ForEach(model.visibleKinds, id: \.self) { kind in
                    NavigationLink {
                        PileView(model: model, kind: kind)
                    } label: {
                        PileRow(model: model, kind: kind)
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Clean up photos")
                        .font(.title.bold())
                        .foregroundStyle(Color.primary)
                    Text("Nothing is deleted until you check and confirm.")
                        .font(.subheadline)
                }
                .textCase(nil)
                .padding(.bottom, 8)
            }
        }
        .safeAreaInset(edge: .bottom) { CleanupBottomBar(model: model) }
    }
}

private struct PileRow: View {
    let model: PhotoCleanup
    let kind: PileKind

    var body: some View {
        let pile = model.piles[kind]
        let count = pile?.count ?? 0
        let picked = model.pickedCount(in: kind)
        HStack(spacing: 14) {
            Image(systemName: kind.icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(.headline)
                Text(count == 0 && model.isLooking ? "Looking…"
                                                    : "\(kind.amount(count)) · \(SizeFormat.string(pile?.bytes ?? 0))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if picked > 0 {
                Text("\(picked.formatted()) picked")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 4)
    }
}

extension PileKind {
    /// "2,341 photos", "12 extra copies".
    func amount(_ count: Int) -> String {
        let one = count == 1
        let noun: String
        switch self {
        case .duplicates: noun = one ? "extra copy" : "extra copies"
        case .similar, .bursts: noun = one ? "extra shot" : "extra shots"
        case .screenRecordings: noun = one ? "recording" : "recordings"
        default: noun = one ? "photo" : "photos"
        }
        return "\(count.formatted()) \(noun)"
    }
}

// MARK: - One pile

/// One pile: a grid by month (or the groups), tap to pick, or swipe through them.
struct PileView: View {
    @Bindable var model: PhotoCleanup
    let kind: PileKind
    @State private var swiping = false

    var body: some View {
        let pile = model.piles[kind] ?? Pile(kind: kind)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(kind.title)
                    .font(.title.bold())
                Text(kind.explanation)
                    .foregroundStyle(.secondary)
                if !kind.isGrouped && !pile.items.isEmpty {
                    Button {
                        swiping = true
                    } label: {
                        Label("Swipe through them", systemImage: "hand.draw")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .padding(.top, 4)
                }
                if pile.count == 0 {
                    Text(model.isLooking ? "Still looking. Photos show here as they're found." : "Nothing here now.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            if kind.isGrouped {
                GroupedPileContent(model: model, kind: kind, groups: pile.groups)
            } else {
                FlatPileContent(model: model, kind: kind, items: pile.items)
            }
        }
        .navigationTitle("Clean up photos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(model.allPicked(kind) ? "Clear" : "Pick all") {
                    if model.allPicked(kind) { model.clearPicks(kind) } else { model.pickAll(kind) }
                }
                .disabled(pile.count == 0)
            }
        }
        .safeAreaInset(edge: .bottom) { CleanupBottomBar(model: model) }
        .fullScreenCover(isPresented: $swiping) {
            SwipeReview(model: model, kind: kind)
        }
    }
}

/// Month by month, newest first, three across.
private struct FlatPileContent: View {
    let model: PhotoCleanup
    let kind: PileKind
    let items: [CleanupItem]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    var body: some View {
        let sections = Months.sections(items) { $0.created }
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(sections.indices, id: \.self) { index in
                let section = sections[index]
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(MonthTitle.string(section.start))
                            .font(.headline)
                        Spacer()
                        Text(kind.amount(section.items.count))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(section.items) { item in
                            PhotoTile(item: item, kind: kind, isPicked: model.isPicked(item, in: kind)) {
                                model.toggle(item, in: kind)
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 16)
    }
}

/// Duplicates, similar shots and bursts: each group in a row, the one to keep marked.
private struct GroupedPileContent: View {
    let model: PhotoCleanup
    let kind: PileKind
    let groups: [CleanupGroup]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(group.date?.formatted(date: .abbreviated, time: .shortened) ?? "No date")
                            .font(.headline)
                        Spacer()
                        Text(kind == .duplicates ? "\(group.items.count) copies" : "\(group.items.count) shots")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(group.items) { item in
                                PhotoTile(item: item, kind: kind, isPicked: model.isPicked(item, in: kind),
                                          badge: group.keeps.contains(item.id) ? (kind == .similar ? "Best" : "Keep") : nil,
                                          side: 108) {
                                    model.toggle(item, in: kind)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 16)
    }
}

/// A photo to pick: dimmed with a tick when picked (a crossed-out Live Photo mark in the Live Photos pile).
struct PhotoTile: View {
    let item: CleanupItem
    let kind: PileKind
    let isPicked: Bool
    var badge: String? = nil
    var side: CGFloat? = nil
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            AssetThumbnail(id: item.id, side: side, corner: side == nil ? 2 : 10)
                .overlay {
                    if isPicked { Color.black.opacity(0.28) }
                }
                .overlay(alignment: .topTrailing) {
                    if isPicked && kind == .livePhotos {
                        // "Photo only": the Live Photo mark crossed out, on a solid badge so it reads at a glance.
                        Image(systemName: "livephoto.slash")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Color.accentColor, in: Circle())
                            .shadow(radius: 2)
                            .padding(6)
                    } else {
                        Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                            .font(.title3.weight(.semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, isPicked ? Color.accentColor : Color.black.opacity(0.25))
                            .shadow(radius: 2)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if item.isVideo {
                        Text(Clock.string(item.duration))
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                            .padding(5)
                    } else if item.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let badge {
                        Text(badge)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.green, in: Capsule())
                            .padding(.bottom, 6)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }

    private var accessibilityText: String {
        var parts = [item.isVideo ? "Recording" : "Photo"]
        if let created = item.created { parts.append(created.formatted(date: .abbreviated, time: .shortened)) }
        parts.append(SizeFormat.string(kind == .livePhotos ? item.stillSaving : item.bytes))
        if let badge { parts.append(badge) }
        return parts.joined(separator: ", ")
    }
}

enum MonthTitle {
    static func string(_ start: Date?) -> String {
        start?.formatted(.dateTime.month(.wide).year()) ?? "No date"
    }
}

// MARK: - Picked so far

/// Under every cleanup screen: what's picked, what it frees, and Next.
struct CleanupBottomBar: View {
    let model: PhotoCleanup
    @State private var showPro = false

    var body: some View {
        let count = model.pickedCount
        let saving = model.pickedSaving
        VStack(spacing: 8) {
            HStack {
                Text(count == 1 ? "1 picked" : "\(count.formatted()) picked")
                Spacer()
                Text("frees about \(SizeFormat.string(saving))")
            }
            .font(.headline)
            if model.isOverAllowance {
                overAllowance(count: count)
            } else {
                Text(Store.shared.isPro ? "Shrink Pro: no limit" : "Uses \(SizeFormat.string(saving)) of your free 5 GB")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                NavigationLink {
                    PhotoCleanupCheck(model: model)
                } label: {
                    Text("Next").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(count == 0)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .sheet(isPresented: $showPro) { ProView() }
    }

    /// More than the free allowance left: said up front, with the free part offered too.
    @ViewBuilder private func overAllowance(count: Int) -> some View {
        let free = model.planned.count
        let left = SizeFormat.string(FreeAllowance.leftBytes)
        Label {
            Text(free > 0 ? "That's more than the \(left) you have left free. \(free) of them fit in it."
                          : "Your free 5 GB is used up.")
        } icon: {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        }
        .font(.subheadline)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        Button {
            showPro = true
        } label: {
            Text("Get Pro to clean up all \(count.formatted())").font(.headline).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        if free > 0 {
            NavigationLink {
                PhotoCleanupCheck(model: model)
            } label: {
                Text(free == 1 ? "Clean up the 1 that fits free" : "Clean up the \(free) that fit free")
                    .font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }
}

// MARK: - Check

/// "Check before cleaning up": exactly what goes, what becomes a still, and where the space comes back.
struct PhotoCleanupCheck: View {
    let model: PhotoCleanup
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 4)

    var body: some View {
        let plan = model.planned
        let saving = plan.saving
        let left = FreeAllowance.leftBytes
        let stillIDs = Set(plan.stills.map(\.id))
        let duplicatesGoing = plan.deletes.contains { model.keeperFor[$0.id] != nil }
        List {
            Section {
                if !plan.deletes.isEmpty {
                    CheckFact(icon: "trash", title: "\(Self.things(plan.deletes)) go to Recently Deleted",
                              detail: "Photos keeps them for 30 days. You can put any of them back.")
                }
                if duplicatesGoing {
                    CheckFact(icon: "square.on.square", title: "The copies that stay keep their albums",
                              detail: "Each duplicate's albums and favorite move to the copy you keep.")
                }
                if !plan.stills.isEmpty {
                    CheckFact(icon: "livephoto",
                              title: plan.stills.count == 1 ? "1 Live Photo becomes a still photo"
                                                            : "\(plan.stills.count.formatted()) Live Photos become still photos",
                              detail: "Each still keeps its date, place, favorite and albums. The Live Photo goes to Recently Deleted only once its still is saved and checked.")
                }
                CheckFact(icon: "gauge.with.needle",
                          title: "About \(SizeFormat.string(saving)) comes back when Recently Deleted is emptied",
                          detail: "Photos empties it after 30 days, or you can do it sooner. With iCloud Photos on, the space comes back in iCloud too.")
                if Store.shared.isPro {
                    CheckFact(icon: "checkmark.seal", title: "Shrink Pro: no limit", detail: "Thank you for supporting Shrink.")
                } else {
                    CheckFact(icon: "checkmark", title: "Uses \(SizeFormat.string(min(saving, left))) of your free 5 GB",
                              detail: "\(SizeFormat.string(max(0, left - saving))) left after this.")
                }
            } header: {
                Text("Check before cleaning up")
                    .font(.title.bold())
                    .foregroundStyle(Color.primary)
                    .textCase(nil)
                    .padding(.bottom, 8)
            }

            Section("Everything that goes") {
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(plan.all) { item in
                        AssetThumbnail(id: item.id, side: nil, corner: 2)
                            .overlay(alignment: .bottomTrailing) {
                                if stillIDs.contains(item.id) {
                                    Image(systemName: "livephoto.slash")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 20, height: 20)
                                        .background(Color.accentColor, in: Circle())
                                        .padding(4)
                                }
                            }
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Text(plan.stills.isEmpty ? "At the end, iPhone asks you to confirm."
                                         : "Shrink saves the still photos first. At the end, iPhone asks you to confirm.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    model.startCleanup()
                } label: {
                    Text(plan.stills.isEmpty ? "Delete \(Self.things(plan.deletes))" : "Clean up \(Self.things(plan.all))")
                        .font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(plan.count == 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .navigationTitle("Clean up photos")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// "3 photos", "1 video", "4 photos and videos".
    static func things(_ items: [CleanupItem]) -> String {
        let videos = items.filter(\.isVideo).count
        let count = items.count
        let noun: String
        if videos == 0 {
            noun = count == 1 ? "photo" : "photos"
        } else if videos == count {
            noun = count == 1 ? "video" : "videos"
        } else {
            noun = "photos and videos"
        }
        return "\(count.formatted()) \(noun)"
    }
}

/// One line of a check screen: an icon, what happens, and the detail.
struct CheckFact: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
