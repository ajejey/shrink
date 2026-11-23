import Photos
import ShrinkCore
import SwiftUI
import UIKit

/// Home's "Free up space" card. Before access: what it does and that the first 5 GB is free.
/// After a scan it's the dashboard: what the videos could free, what photo cleanup found, what's new,
/// the allowance (shared by both), iPhone storage.
struct FreeUpSpaceCard: View {
    let model: FreeUpSpace
    let cleanup: PhotoCleanup
    let onOpen: () -> Void
    let onOpenCleanup: () -> Void
    private var store: Store { .shared }
    @Environment(\.openURL) private var openURL
    @State private var showPro = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Free up space")
                .font(.title.bold())
            switch model.access {
            case .notAsked:
                Text("See which videos take the most room and which photos you may not need. You pick what goes.")
                    .foregroundStyle(.secondary)
                checkLine("Your first 5 GB is free")
                bigButton("Find my biggest videos")
            case .denied:
                Text("Shrink can't see your videos and photos. Allow access to Photos in Settings to find what takes up space.")
                    .foregroundStyle(.secondary)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    Text("Open Settings").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            case .limited, .full:
                Text("Shrink big videos")
                    .font(.title3.weight(.semibold))
                summary
                bigButton("See the videos")
                Divider().padding(.vertical, 4)
                Text("Clean up photos")
                    .font(.title3.weight(.semibold))
                photoSummary
                Button(action: onOpenCleanup) {
                    Text("See the photos").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.top, 4)
                if model.access == .limited {
                    Text("Shrink can only see the photos and videos you chose. Allow all in Settings to find everything.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !model.pendingOriginals.isEmpty {
                    pendingRow
                }
                Divider().padding(.vertical, 4)
                AllowanceBar()
                if !store.isPro, FreeAllowance.leftBytes == 0 {
                    HStack {
                        Text("Your free 5 GB is used. Pro frees the rest.")
                            .font(.subheadline)
                        Spacer()
                        Button("Get Pro") { showPro = true }
                            .buttonStyle(.bordered)
                    }
                }
                if let storage = StorageInfo.current() {
                    meter("iPhone storage",
                          value: "\(SizeFormat.string(storage.freeBytes)) free of \(SizeFormat.string(storage.totalBytes))",
                          fraction: 1 - Double(storage.freeBytes) / Double(storage.totalBytes), tint: .gray)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        .sheet(isPresented: $showPro) { ProView() }
    }

    @ViewBuilder private var summary: some View {
        switch model.scan {
        case .notStarted, .running:
            HStack(spacing: 8) {
                ProgressView()
                Text("Looking at your videos…").foregroundStyle(.secondary)
            }
        case .finished:
            if model.totalSaving > 0 {
                Text("Your videos could free about \(SizeFormat.string(model.totalSaving))")
                    .foregroundStyle(.secondary)
                if model.newSinceLastTime > 0 {
                    Label("New since last time: about \(SizeFormat.string(model.newSinceLastTime))", systemImage: "plus")
                        .font(.subheadline)
                }
            } else {
                Text("Your videos are already small. Nothing here is worth shrinking.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var photoSummary: some View {
        switch cleanup.scan {
        case .notStarted, .listing:
            HStack(spacing: 8) {
                ProgressView()
                Text("Looking at your photos…").foregroundStyle(.secondary)
            }
        default:
            Text(cleanup.mayFree > 0
                 ? "Duplicates, screenshots, blurry shots and more could free about \(SizeFormat.string(cleanup.mayFree))"
                 : "Duplicates, screenshots, blurry shots and more")
                .foregroundStyle(.secondary)
        }
    }

    /// Copies saved earlier whose originals are still in the library (iOS asked, they said no).
    private var pendingRow: some View {
        let count = model.pendingOriginals.count
        let saving = model.pendingOriginals.reduce(Int64(0)) { $0 + $1.savedBytes }
        return VStack(alignment: .leading, spacing: 8) {
            Text(count == 1 ? "1 original is still in your library" : "\(count) originals are still in your library")
                .font(.subheadline.weight(.semibold))
            Text("Their smaller copies are saved. Moving the originals to Recently Deleted frees about \(SizeFormat.string(saving)).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Move them to Recently Deleted") {
                Task { await model.moveOriginals() }
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func bigButton(_ title: String) -> some View {
        Button(action: onOpen) {
            Text(title).font(.headline).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(.top, 4)
    }

    private func checkLine(_ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "checkmark").foregroundStyle(.green)
        }
        .font(.subheadline)
    }
}

/// "Free allowance: 3.2 GB of 5 GB left".
struct AllowanceBar: View {
    private var store: Store { .shared }

    var body: some View {
        if store.isPro {
            Label("Shrink Pro: no limit", systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold))
        } else {
            meter("Free allowance",
                  value: "\(SizeFormat.string(FreeAllowance.leftBytes)) of 5 GB left",
                  fraction: Double(FreeAllowance.usedBytes) / Double(FreeAllowance.totalBytes), tint: .accentColor)
        }
    }
}

/// A labelled bar: the name on the left, the numbers on the right.
private func meter(_ title: String, value: String, fraction: Double, tint: Color) -> some View {
    VStack(spacing: 6) {
        HStack {
            Text(title).fontWeight(.semibold)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .font(.subheadline)
        ProgressView(value: min(max(fraction, 0), 1))
            .tint(tint)
    }
    .accessibilityElement(children: .combine)
}

/// The pushed screen: the intro until Photos access is asked, then the videos to pick.
struct FreeUpSpaceScreen: View {
    @Bindable var model: FreeUpSpace
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch model.access {
        case .notAsked:
            FreeUpSpaceIntro(model: model)
        case .denied:
            VStack(spacing: 16) {
                Text("Shrink can't see your videos")
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
            FreeUpSpacePick(model: model)
        }
    }
}

/// First time only: what happens, before iOS asks for Photos access.
private struct FreeUpSpaceIntro: View {
    let model: FreeUpSpace
    @State private var asking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Free up space")
                    .font(.largeTitle.bold())
                Text("Shrink lists the videos taking the most room. You choose which ones to make smaller.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            point("iphone", "Nothing leaves your iPhone", "Videos are shrunk right here. Nothing is uploaded.")
            point("checkmark.square", "You pick every video", "Nothing is shrunk or deleted until you say so.")
            point("arrow.uturn.backward", "Originals can come back",
                  "They go to Recently Deleted, where Photos keeps them for 30 days.")
            point("gauge.with.needle", "Your first 5 GB is free", "See how much you'd free before paying anything.")
            Spacer(minLength: 0)
            Text("Next, iPhone asks to let Shrink see your photos. Choose Allow Full Access so Shrink can find every big video.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                asking = true
                Task {
                    await model.requestAccess()
                    asking = false
                }
            } label: {
                Text("Look at my videos").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(asking)
        }
        .padding(24)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func point(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

/// "Pick the videos to shrink": biggest first, nothing ticked for them, the saving shown before anything starts.
private struct FreeUpSpacePick: View {
    @Bindable var model: FreeUpSpace
    @State private var showPro = false

    var body: some View {
        Group {
            switch model.scan {
            case .notStarted, .running:
                scanning
            case .finished where model.videos.isEmpty:
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.green)
                    Text("Your videos are already small")
                        .font(.title2.bold())
                    Text("Nothing here would free enough space to be worth it.")
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding(24)
            case .finished:
                list
            }
        }
        .navigationTitle("Free up space")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if case .notStarted = model.scan { await model.scanLibrary() }
        }
    }

    private var scanning: some View {
        VStack(spacing: 18) {
            Text("Looking at your videos")
                .font(.title2.bold())
            if case .running(let checked, let total) = model.scan, total > 0 {
                Text("Checked \(checked.formatted()) of \(total.formatted()) videos")
                    .monospacedDigit()
                ProgressView(value: Double(checked), total: Double(total))
            } else {
                ProgressView()
            }
            Text("This only reads sizes and dates, so it takes a few seconds. Nothing changes yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(32)
    }

    private var list: some View {
        List {
            Section {
                Picker("Shrink videos to", selection: $model.size) {
                    Text("1080p").tag(LibraryPlanner.Size.hd)
                    Text("Keep 4K").tag(LibraryPlanner.Size.keep4K)
                }
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pick the videos to shrink")
                        .font(.title.bold())
                        .foregroundStyle(Color.primary)
                    Text("Biggest first · \(model.videos.count) worth shrinking")
                        .font(.subheadline)
                }
                .textCase(nil)
                .padding(.bottom, 8)
            } footer: {
                Text(model.size == .hd ? "1080p looks the same on a phone and frees the most."
                                       : "4K videos stay 4K. This frees less.")
            }

            Section {
                ForEach(model.videos) { video in
                    VideoRow(video: video, isPicked: model.picked.contains(video.id)) {
                        model.toggle(video.id)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(model.allPicked ? "Clear" : "Pick all") {
                    if model.allPicked { model.clearPicks() } else { model.pickAll() }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
    }

    private var bottomBar: some View {
        let count = model.picked.count
        let saving = model.pickedSaving
        return VStack(spacing: 8) {
            HStack {
                Text(count == 1 ? "1 video picked" : "\(count) videos picked")
                Spacer()
                Text("frees about \(SizeFormat.string(saving))")
            }
            .font(.headline)
            if model.isOverAllowance {
                overAllowance(count: count)
            } else {
                Text(Store.shared.isPro ? "Shrink Pro: no limit"
                                        : "Uses \(SizeFormat.string(saving)) of your free 5 GB")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                NavigationLink {
                    FreeUpSpaceCheck(model: model)
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
        let free = model.plannedVideos.count
        Label {
            Text(overText(free: free))
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
            Text("Get Pro to shrink all \(count)").font(.headline).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        if free > 0 {
            NavigationLink {
                FreeUpSpaceCheck(model: model)
            } label: {
                Text(free == 1 ? "Shrink the first one free" : "Shrink the first \(free) free")
                    .font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private func overText(free: Int) -> String {
        guard free > 0 else { return "Your free 5 GB is used up." }
        let left = SizeFormat.string(FreeAllowance.leftBytes)
        let fits = free == 1 ? "The first video fits" : "The first \(free) videos fit"
        return "That's more than the \(left) you have left free. \(fits) in it."
    }
}

/// One video: thumbnail with its length, the date, the size now and about how small it gets.
private struct VideoRow: View {
    let video: LibraryVideo
    let isPicked: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                AssetThumbnail(id: video.id)
                    .overlay(alignment: .bottomTrailing) {
                        Text(Clock.string(video.duration))
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                            .padding(4)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(video.created?.formatted(date: .abbreviated, time: .omitted) ?? "Video")
                        .font(.headline)
                    Text("\(SizeFormat.string(video.bytes)) → about \(SizeFormat.string(video.estimatedBytes))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isPicked ? Color.accentColor : Color(.tertiaryLabel))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }
}

/// A square picture of a library photo or video. With no `side` it fills the width it's given.
struct AssetThumbnail: View {
    let id: String
    var side: CGFloat? = 60
    var corner: CGFloat = 8
    @State private var image: UIImage?

    var body: some View {
        Color(.tertiarySystemFill)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if id.hasPrefix("preview-") {
                    PreviewArt(id: id)
                }
            }
            .frame(width: side, height: side)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: corner))
            .accessibilityHidden(true)
            .task(id: id) { image = await Self.load(id, pixels: (side ?? 140) * 3, mode: .aspectFill) }
    }

    static func load(_ id: String, pixels: CGFloat, mode: PHImageContentMode) async -> UIImage? {
        guard !id.hasPrefix("preview-") else { return nil }
        // Asking Photos for anything before access is granted makes iOS ask for access, so don't.
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { done in
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: pixels, height: pixels), contentMode: mode, options: options
            ) { image, _ in
                done.resume(returning: image)
            }
        }
    }
}

/// For CI screenshots only: a made-up picture where a library photo would be (ids starting "preview-").
struct PreviewArt: View {
    let id: String
    private static let symbols = ["sun.max.fill", "leaf.fill", "car.fill", "fork.knife", "pawprint.fill",
                                  "mountain.2.fill", "building.2.fill", "figure.walk", "doc.text.fill",
                                  "message.fill", "birthday.cake.fill", "beach.umbrella.fill"]

    var body: some View {
        let seed = id.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        // A camera roll's colours: sunset, sand, foliage, sea and sky (no purples).
        let hues = [0.04, 0.09, 0.13, 0.25, 0.33, 0.48, 0.56, 0.60]
        let hue = hues[Int(seed % UInt32(hues.count))]
        LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.9),
                                Color(hue: hue + 0.03, saturation: 0.65, brightness: 0.55)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                Image(systemName: Self.symbols[Int(seed / 7) % Self.symbols.count])
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
    }
}

/// "Check before shrinking": exactly what happens to every video, and where the space comes back.
struct FreeUpSpaceCheck: View {
    let model: FreeUpSpace

    var body: some View {
        let videos = model.plannedVideos
        let count = videos.count
        let saving = model.plannedSaving
        let left = FreeAllowance.leftBytes
        let pro = Store.shared.isPro
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(videos.prefix(8)) { video in
                            AssetThumbnail(id: video.id, side: 64)
                        }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } header: {
                Text("Check before shrinking")
                    .font(.title.bold())
                    .foregroundStyle(Color.primary)
                    .textCase(nil)
                    .padding(.bottom, 8)
            }

            Section {
                fact("plus.square.on.square", count == 1 ? "1 smaller copy goes into your library"
                                                         : "\(count) smaller copies go into your library",
                     "Same dates, places, favorites and albums as the originals.")
                fact("arrow.uturn.backward", count == 1 ? "The original goes to Recently Deleted"
                                                        : "The \(count) originals go to Recently Deleted",
                     "Photos keeps them for 30 days. You can put any of them back.")
                fact("gauge.with.needle", "About \(SizeFormat.string(saving)) comes back when Recently Deleted is emptied",
                     "Photos empties it after 30 days, or you can do it sooner. With iCloud Photos and Optimize iPhone Storage on, most of it comes back in iCloud.")
                if pro {
                    fact("checkmark.seal", "Shrink Pro: no limit", "Thank you for supporting Shrink.")
                } else {
                    fact("checkmark", "Uses \(SizeFormat.string(min(saving, left))) of your free 5 GB",
                         "\(SizeFormat.string(max(0, left - saving))) left after this.")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Text(Self.whileItWorks)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    model.startShrinking()
                } label: {
                    Text(count == 1 ? "Shrink 1 video" : "Shrink \(count) videos").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(count == 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .navigationTitle("Free up space")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// iOS 26 can keep a batch going in the background (ContinuedRun); earlier iOS needs Shrink open.
    private static var whileItWorks: String {
        if #available(iOS 26.0, *) {
            return "You can switch to another app while it works. If iPhone pauses it, tap Keep going. At the end, iPhone asks you to confirm moving the originals."
        }
        return "Keep Shrink open while it works. At the end, iPhone asks you to confirm moving the originals."
    }

    private func fact(_ icon: String, _ title: String, _ detail: String) -> some View {
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
