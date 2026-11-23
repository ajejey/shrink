import PhotosUI
import StoreKit
import SwiftUI

/// Home: the two jobs, in the person's words. "Send a video or photo" with one-tap places, and
/// "Free up space". No intro screens: people open the app with a problem, so the job comes first.
struct HomeView: View {
    @State private var chosen: Destination?
    @State private var showPicker = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var job = ShrinkJob()
    @State private var showPlaces = false
    @State private var showSettings = false
    @State private var recents = RecentPlaces.load()
    @State private var freeUp: FreeUpSpace
    @State private var showFreeUp = false
    @State private var cleanup: PhotoCleanup
    @State private var showCleanup = false
    @State private var quick = QuickJob()
    @State private var quickKind: QuickJob.Kind?
    @State private var showQuickPicker = false
    @State private var quickItem: PhotosPickerItem?
    @State private var batch = BatchSend()
    @State private var showSeveralPlaces = false
    @State private var severalPlace: Destination?
    @State private var showSeveralPicker = false
    @State private var severalItems: [PhotosPickerItem] = []
    @State private var showProSeveral = false
    @State private var showCrashReport = false
    private let crashes = CrashReports.shared
    private let router = ShortcutRouter.shared
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var scenePhase

    /// `freeUp` and `cleanup` are frozen copies for CI screenshots; the app makes its own.
    @MainActor
    init(freeUp: FreeUpSpace? = nil, cleanup: PhotoCleanup? = nil) {
        let model = freeUp ?? FreeUpSpace()
        _freeUp = State(initialValue: model)
        _cleanup = State(initialValue: cleanup ?? PhotoCleanup(freeUp: model))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let crash = crashes.pending, SupportContact.reportURL != nil {
                        CrashCard(onReport: { showCrashReport = true }, onDismiss: { crashes.clear() })
                            .sheet(isPresented: $showCrashReport) {
                                ReportProblemView(report: ProblemReport(crash: crash), onSent: { crashes.clear() })
                            }
                    }
                    sendCard
                    FreeUpSpaceCard(model: freeUp, cleanup: cleanup,
                                    onOpen: { showFreeUp = true }, onOpenCleanup: { showCleanup = true })
                    QuickJobsCard(onPick: pickQuick)
                        // On the card, apart from the send job's picker and cover on the stack.
                        .photosPicker(isPresented: $showQuickPicker, selection: $quickItem,
                                      matching: quickKind?.pickerFilter ?? .videos, preferredItemEncoding: .current)
                        .onChange(of: quickItem) { _, item in
                            guard let item, let kind = quickKind else { return }
                            quickItem = nil
                            quick.open(item: item, kind: kind)
                        }
                        .fullScreenCover(isPresented: $quick.isShowing, onDismiss: quickClosed) {
                            QuickJobView(job: quick)
                        }
                    Text("Everything happens on your iPhone. Nothing is uploaded.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }
                .padding(16)
                // Photo cleanup's progress and result (on its own view, apart from the other covers).
                .fullScreenCover(isPresented: Binding(get: { cleanup.isRunShowing },
                                                      set: { if !$0 { cleanup.cancelRun() } })) {
                    PhotoCleanupRunView(model: cleanup)
                }
            }
            .background(Color(.systemGroupedBackground))
            // Free up space's progress and result, over everything (on its own view, apart from the job's cover).
            .fullScreenCover(isPresented: Binding(get: { freeUp.isRunShowing },
                                                  set: { if !$0 { freeUp.cancelRun() } })) {
                FreeUpSpaceRunView(model: freeUp)
            }
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
            .navigationDestination(isPresented: $showFreeUp) {
                FreeUpSpaceScreen(model: freeUp)
            }
            .navigationDestination(isPresented: $showCleanup) {
                PhotoCleanupScreen(model: cleanup)
            }
        }
        .task {
            crashes.start()
            freeUp.restoreInterruptedRun()
            await Store.shared.load()
            await freeUp.refreshAndScanIfNeeded()
            await cleanup.refreshAndListIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await freeUp.refreshAndScanIfNeeded()
                await cleanup.refreshAndListIfNeeded()
            }
        }
        .onChange(of: router.request, initial: true) { _, _ in openShortcut() }
        .onChange(of: freeUp.requestsHome) { _, goHome in
            guard goHome else { return }
            freeUp.requestsHome = false
            showFreeUp = false
            if freeUp.lastRunFreed > 0, ReviewPrompt.recordSuccess() { requestReview() }
        }
        .onChange(of: cleanup.requestsHome) { _, goHome in
            guard goHome else { return }
            cleanup.requestsHome = false
            showCleanup = false
            if cleanup.lastRunFreed > 0, ReviewPrompt.recordSuccess() { requestReview() }
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
                .environment(\.proScreen, .app)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    /// "Send a video or photo", with Send several at once's places, Photos picker and screen on it,
    /// apart from the single job's picker and cover on the stack.
    private var sendCard: some View {
        SendCard(places: recents.isEmpty ? RecentPlaces.popular : recents,
                 isRecent: !recents.isEmpty,
                 isPro: Store.shared.isPro,
                 onPick: pick,
                 onAllPlaces: { showPlaces = true },
                 onSeveral: openSeveral)
            .sheet(isPresented: $showSeveralPlaces, onDismiss: {
                if severalPlace != nil { showSeveralPicker = true }
            }) {
                SeveralPlacesView { place in
                    severalPlace = place
                    showSeveralPlaces = false
                }
            }
            .sheet(isPresented: $showProSeveral, onDismiss: {
                // Bought Pro just now: carry on to the places.
                if Store.shared.isPro { showSeveralPlaces = true }
            }) {
                ProView(reason: .several)
            }
            .photosPicker(isPresented: $showSeveralPicker, selection: $severalItems,
                          maxSelectionCount: BatchSend.maxItems, selectionBehavior: .ordered,
                          matching: severalPlace?.pickerFilter ?? .videos, preferredItemEncoding: .current)
            .onChange(of: severalItems) { _, items in
                guard !items.isEmpty, let place = severalPlace else { return }
                severalItems = []
                batch.open(items: items, destination: place, removeLocation: AppSettings.removeLocation)
            }
            .fullScreenCover(isPresented: $batch.isShowing, onDismiss: batchClosed) {
                BatchSendView(model: batch)
            }
    }

    private func pick(_ destination: Destination) {
        chosen = destination
        showPicker = true
    }

    /// "Send several at once": Pro first if it isn't on, then where they're going, then Photos.
    private func openSeveral() {
        severalPlace = nil
        if Store.shared.isPro {
            showSeveralPlaces = true
        } else {
            showProSeveral = true
        }
    }

    /// After Send several at once has closed.
    private func batchClosed() {
        recents = RecentPlaces.load()
        if !batch.madeFiles.isEmpty, ReviewPrompt.recordSuccess() { requestReview() }
    }

    private func pickQuick(_ kind: QuickJob.Kind) {
        quickKind = kind
        showQuickPicker = true
    }

    /// After a quick extra's screen has closed: "Pick another video" opens the Photos picker again.
    private func quickClosed() {
        if quick.takeWantsAnother() { showQuickPicker = true }
    }

    /// Siri or Spotlight asked for a job: open its screen.
    private func openShortcut() {
        guard let request = router.request else { return }
        router.request = nil
        switch request {
        case .send(let id):
            if let destination = Destination.find(id: id) { pick(destination) }
        case .freeUp:
            showFreeUp = true
        case .cleanUp:
            showCleanup = true
        case .quick(let raw):
            if let kind = QuickJob.Kind(rawValue: raw) { pickQuick(kind) }
        }
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

/// After a crash: an offer to send iOS's details of it. Nothing goes unless they tap Report it, then Send.
private struct CrashCard: View {
    let onReport: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("Shrink closed unexpectedly")
                    .font(.headline)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text("Sending what happened helps fix it. You'll see exactly what goes before anything is sent.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Report it", action: onReport)
                    .buttonStyle(.borderedProminent)
                Button("Not now", action: onDismiss)
                    .buttonStyle(.bordered)
            }
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}

/// "Send a video or photo": the job, then the places as one-tap buttons, then every place.
private struct SendCard: View {
    let places: [Destination]
    /// Recently used places, or the popular ones before anything has been sent.
    let isRecent: Bool
    let isPro: Bool
    let onPick: (Destination) -> Void
    let onAllPlaces: () -> Void
    let onSeveral: () -> Void

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
            Divider()
                .padding(.top, 4)
            Button(action: onSeveral) {
                HStack(spacing: 12) {
                    Image(systemName: "square.stack")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    Text("Send several at once")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if !isPro {
                        Text("Pro")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPro ? "Send several at once" : "Send several at once, Shrink Pro")
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

/// The quick extras, each a plain job in the person's words.
private struct QuickJobsCard: View {
    let onPick: (QuickJob.Kind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("More with a video")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            ForEach(QuickJob.Kind.allCases) { kind in
                Button {
                    onPick(kind)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: kind.symbol)
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(kind.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                if kind != QuickJob.Kind.allCases.last {
                    Divider().padding(.leading, 42)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}

/// "Where are they going?" for Send several at once: the same places, in a sheet with Cancel.
private struct SeveralPlacesView: View {
    let onPick: (Destination) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DestinationList(kind: nil, showsHeader: false, onPick: onPick)
                .navigationTitle("Where are they going?")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
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
                // The icon's blue (scripts/make-app-icon.py), the same in light and dark mode.
                .fill(Color(red: 0.145, green: 0.388, blue: 0.922))
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
