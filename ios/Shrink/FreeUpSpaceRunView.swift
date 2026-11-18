import ShrinkCore
import SwiftUI

/// Free up space while it works and when it's done: progress, then "Space freed" (or why not).
struct FreeUpSpaceRunView: View {
    let model: FreeUpSpace
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Group {
                switch model.run {
                case .idle:
                    EmptyView()
                case .working(let working):
                    progress(working)
                case .paused(let paused):
                    pausedView(paused)
                case .movingOriginals:
                    VStack(spacing: 16) {
                        ProgressView().controlSize(.large)
                        Text("Moving the originals to Recently Deleted…")
                            .font(.title3)
                    }
                    .padding(24)
                case .finished(let summary):
                    finished(summary)
                case .tooFull(let tooFull):
                    full(tooFull)
                case .failed(let message):
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.title3)
                    }
                    .multilineTextAlignment(.center)
                    .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
            .navigationTitle("Free up space")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isWorking {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Stop") { model.stop() }
                    }
                }
                if isEnded {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { model.closeRun() }
                    }
                }
                if isBeforeStart {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Back") { model.cancelRun() }
                    }
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private var isWorking: Bool {
        if case .working = model.run { return true }
        return false
    }

    private var isEnded: Bool {
        if case .finished = model.run { return true }
        return false
    }

    private var isBeforeStart: Bool {
        switch model.run {
        case .tooFull, .failed: return true
        default: return false
        }
    }

    // MARK: - Working

    private func progress(_ working: FreeUpSpace.Working) -> some View {
        let overall = (Double(working.index) + working.progress) / Double(max(working.count, 1))
        return VStack(spacing: 18) {
            Spacer()
            Text("Shrinking your videos")
                .font(.title2.bold())
            Text("Video \(working.index + 1) of \(working.count)")
                .foregroundStyle(.secondary)
            Text("\(Int(overall * 100))%")
                .font(.system(size: 72, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.default, value: Int(overall * 100))
            ProgressView(value: overall)
                .scaleEffect(x: 1, y: 3, anchor: .center)
                .padding(.horizontal, 8)
            if working.downloading {
                Label("Getting it from iCloud…", systemImage: "icloud.and.arrow.down")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                AssetThumbnail(id: working.video.id, side: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(working.video.created?.formatted(date: .abbreviated, time: .omitted) ?? "Video")
                        .font(.headline)
                    Text("\(SizeFormat.string(working.video.bytes)) → about \(SizeFormat.string(working.video.estimatedBytes))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            Text(model.continued != nil
                 ? "You can switch to another app while it works. If iPhone pauses it, tap Keep going when you're back. Stop keeps the videos already finished."
                 : "Keep Shrink open. The screen stays on until it's done. If something interrupts it, you can carry on from where it stopped. Stop keeps the videos already finished.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(24)
    }

    // MARK: - Paused

    private func pausedView(_ paused: FreeUpSpace.Paused) -> some View {
        let left = paused.count - paused.done
        return VStack(spacing: 16) {
            Spacer()
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
            Text("Shrinking paused")
                .font(.title.bold())
            Text(paused.done == 0
                 ? "None of the \(paused.count) videos is finished yet."
                 : "\(paused.done) of \(paused.count) videos are finished.")
                .font(.title3)
            Text(left == 1
                 ? "Shrink was interrupted, so 1 video is still waiting. Nothing was lost: the finished copies are saved, and every original is still in your library."
                 : "Shrink was interrupted, so \(left) videos are still waiting. Nothing was lost: the finished copies are saved, and every original is still in your library.")
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                model.keepGoing()
            } label: {
                Text("Keep going").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button {
                model.stopHere()
            } label: {
                Text(paused.done == 0 ? "Stop" : "Stop here").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            if paused.done > 0 {
                Text("Stop here still frees the space from the finished videos.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
    }

    // MARK: - Finished

    @ViewBuilder private func finished(_ summary: FreeUpSpace.RunSummary) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                if summary.originalsKept {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.orange)
                    Text("Copies saved, originals kept")
                        .font(.title.bold())
                    Text("The smaller copies are in your library, but the originals are still there too, so no space is freed yet.")
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await model.moveOriginals() }
                    } label: {
                        Text("Move the originals to Recently Deleted").font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 8)
                } else if summary.shrunk > 0 {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(.green)
                    Text("Space freed")
                        .font(.largeTitle.bold())
                    Text("About \(SizeFormat.string(summary.freedBytes)) from \(summary.shrunk == 1 ? "1 video" : "\(summary.shrunk) videos")")
                        .font(.title3)
                    Text("It comes back when Recently Deleted is emptied.")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Get the space back now")
                            .font(.headline)
                        Text("In Photos, open Albums, then Recently Deleted. Tap Select, then Delete All. Apps aren't allowed to do this for you.")
                            .font(.subheadline)
                        openPhotosButton
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.top, 10)
                    AllowanceBar()
                        .padding(.top, 6)
                } else {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.secondary)
                    Text("Nothing was shrunk")
                        .font(.title.bold())
                }
                if summary.skipped > 0 {
                    Text(summary.skipped == 1
                         ? "1 video was already about as small as it can be, so it was left as it is."
                         : "\(summary.skipped) videos were already about as small as they can be, so they were left as they are.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let problem = summary.problems.first {
                    Text(summary.problems.count == 1
                         ? "1 video couldn't be shrunk: \(problem)"
                         : "\(summary.problems.count) videos couldn't be shrunk. The first: \(problem)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .padding(24)
            .padding(.top, 24)
        }
    }

    private var openPhotosButton: some View {
        Button {
            if let url = URL(string: "photos-redirect://") { openURL(url) }
        } label: {
            Text("Open Photos").font(.headline).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    // MARK: - Too full

    private func full(_ tooFull: FreeUpSpace.TooFull) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Your iPhone is too full to start")
                    .font(.title.bold())
                Text("The smaller copies need room before the originals can go. These need about \(SizeFormat.string(tooFull.neededBytes)), and your iPhone has \(SizeFormat.string(tooFull.freeBytes)) free.")
                    .foregroundStyle(.secondary)
                step(1, "Empty Recently Deleted", "Videos and photos deleted earlier may still be using space there.") {
                    openPhotosButton
                }
                step(2, "Shrink fewer at a time",
                     tooFull.fitsOne.map { "One video fits right now. It needs about \(SizeFormat.string($0.estimatedBytes))." }
                        ?? "None fits yet. Free a little room first.") {
                    if let video = tooFull.fitsOne {
                        Button {
                            model.shrinkOnly(video)
                        } label: {
                            Text("Shrink just that one").font(.headline).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
                step(3, "Clear something else big",
                     "In iPhone Settings, General, then iPhone Storage lists what takes the most room.") {
                    EmptyView()
                }
            }
            .padding(24)
        }
    }

    private func step<Extra: View>(_ number: Int, _ title: String, _ detail: String,
                                   @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.bold())
                .frame(width: 28, height: 28)
                .background(Color(.secondarySystemBackground), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                extra()
            }
        }
    }
}

extension FreeUpSpace {
    /// The run screen frozen in one state, for CI screenshots.
    static func previewRun(_ state: String) -> FreeUpSpace {
        let model = preview()
        let videos = model.videos
        switch state {
        case "freeup-done":
            model.run = .finished(RunSummary(shrunk: 3, freedBytes: 3_760_000_000, originalsKept: false,
                                             skipped: 0, problems: []))
        case "freeup-kept":
            model.run = .finished(RunSummary(shrunk: 3, freedBytes: 0, originalsKept: true, skipped: 0, problems: []))
        case "freeup-full":
            model.run = .tooFull(TooFull(neededBytes: 940_000_000, freeBytes: 420_000_000, fitsOne: videos.last))
        case "freeup-paused":
            model.run = .paused(Paused(done: 2, count: 5))
        default:
            model.run = .working(Working(index: 1, count: 3, progress: 0.45, video: videos[min(1, videos.count - 1)],
                                         downloading: false))
        }
        return model
    }
}
