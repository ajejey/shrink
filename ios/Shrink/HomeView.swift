import AVFoundation
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
                                if let label = preset.limitLabel {
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
                guard let item, let preset = chosen, let limit = preset.limitBytes else { return }
                pickedItem = nil
                job.start(item: item, targetBytes: limit, title: preset.title, limitLabel: preset.limitLabel,
                          removeLocation: removeLocation)
            }
            // A full, solid screen: the first demo's half sheet let the destination list show through.
            .fullScreenCover(isPresented: $job.isShowing) {
                ShrinkJobView(job: job)
            }
        }
    }
}

/// One shrink, from picking to a file ready to send.
@Observable
@MainActor
final class ShrinkJob {
    enum Phase {
        case opening
        case shrinking(Double)
        case done(Finished)
        case failed(String)
    }

    /// The shrunk file, ready to share.
    struct Finished {
        let url: URL
        let bytes: Int64
        let originalBytes: Int64?
    }

    var phase: Phase = .opening
    var isShowing = false
    var title = ""
    /// "20 MB", shown with the result so the person sees it fits.
    var limitLabel: String?
    private var task: Task<Void, Never>?

    /// Finished one way or the other: the button says "Done" instead of "Cancel".
    var isFinished: Bool {
        switch phase {
        case .done, .failed: return true
        case .opening, .shrinking: return false
        }
    }

    func start(item: PhotosPickerItem, targetBytes: Int64, title: String, limitLabel: String?, removeLocation: Bool) {
        task?.cancel()
        self.title = title
        self.limitLabel = limitLabel
        phase = .opening
        isShowing = true
        task = Task {
            do {
                guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                    throw ShrinkError.couldNotRead("Couldn't open that video.")
                }
                defer { try? FileManager.default.removeItem(at: movie.url) }
                phase = .shrinking(0)
                let output = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Shrink-\(UUID().uuidString.prefix(6)).mp4")
                let result = try await VideoShrinker().shrink(
                    asset: AVURLAsset(url: movie.url),
                    to: output,
                    options: VideoShrinkOptions(targetBytes: targetBytes, removeLocation: removeLocation)
                ) { [weak self] value in
                    Task { @MainActor in
                        guard let self, case .shrinking = self.phase else { return }
                        self.phase = .shrinking(value)
                    }
                }
                phase = .done(Finished(url: result.url, bytes: result.bytes, originalBytes: result.originalBytes))
            } catch ShrinkError.cancelled {
                // Closed by the person; nothing to show.
            } catch is CancellationError {
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func close() {
        task?.cancel()
        isShowing = false
    }

    /// A job frozen in one state, for CI screenshots (`-screenshot shrinking|done|failed`).
    static func preview(_ state: String) -> ShrinkJob {
        let job = ShrinkJob()
        job.title = "Compress for Discord"
        job.limitLabel = "20 MB"
        job.isShowing = true
        switch state {
        case "done":
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Shrink-preview.mp4")
            job.phase = .done(Finished(url: url, bytes: 19_040_000, originalBytes: 61_500_000))
        case "failed":
            job.phase = .failed("Couldn't open that video.")
        default:
            job.phase = .shrinking(0.62)
        }
        return job
    }
}

/// The whole screen while a video shrinks, then the result with the button to send it.
struct ShrinkJobView: View {
    let job: ShrinkJob

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                switch job.phase {
                case .opening:
                    ProgressView()
                        .controlSize(.large)
                    Text("Opening the video…")
                        .font(.title3)
                case .shrinking(let value):
                    Text("Shrinking your video")
                        .font(.title2.bold())
                    Text("\(Int(value * 100))%")
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.default, value: Int(value * 100))
                    ProgressView(value: value)
                        .scaleEffect(x: 1, y: 3, anchor: .center)
                        .padding(.horizontal, 8)
                    Text("Keep Shrink open until it's done.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                case .done(let result):
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(.green)
                    Text("Ready to send")
                        .font(.largeTitle.bold())
                    VStack(spacing: 6) {
                        Text(sizeLine(result))
                            .font(.title3)
                        if let limit = job.limitLabel {
                            Text("Under the \(limit) limit")
                                .foregroundStyle(.secondary)
                        }
                    }
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.orange)
                    Text("Couldn't shrink this one")
                        .font(.title2.bold())
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if case .done(let result) = job.phase {
                    ShareLink(item: result.url) {
                        Label("Send it", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
            .navigationTitle(job.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if job.isFinished {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { job.close() }
                    }
                }
                if !job.isFinished {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { job.close() }
                    }
                }
            }
        }
    }

    /// "19.0 MB, was 61.5 MB": both sizes written the same way.
    private func sizeLine(_ result: ShrinkJob.Finished) -> String {
        let now = SizeFormat.string(result.bytes)
        guard let original = result.originalBytes, original > 0 else { return now }
        return "\(now), was \(SizeFormat.string(original))"
    }
}

/// A video handed over by the Photos picker, copied somewhere we can read it.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked-\(UUID().uuidString)")
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}
