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
                job.start(item: item, targetBytes: limit, title: preset.title, removeLocation: removeLocation)
            }
            .sheet(isPresented: $job.isShowing) {
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
        case done(VideoShrinkResult)
        case failed(String)
    }

    var phase: Phase = .opening
    var isShowing = false
    var title = ""
    private var task: Task<Void, Never>?

    func start(item: PhotosPickerItem, targetBytes: Int64, title: String, removeLocation: Bool) {
        task?.cancel()
        self.title = title
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
                phase = .done(result)
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
}

struct ShrinkJobView: View {
    let job: ShrinkJob

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                switch job.phase {
                case .opening:
                    ProgressView("Opening the video…")
                case .shrinking(let value):
                    ProgressView(value: value) {
                        Text("Shrinking…")
                    } currentValueLabel: {
                        Text("\(Int(value * 100))%")
                    }
                case .done(let result):
                    Text("Ready to send")
                        .font(.title.bold())
                    Text(sizeLine(result))
                        .foregroundStyle(.secondary)
                    ShareLink(item: result.url) {
                        Label("Send it", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                case .failed(let message):
                    Text("Couldn't shrink this one")
                        .font(.title2.bold())
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .navigationTitle(job.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { job.close() }
                }
            }
        }
        .interactiveDismissDisabled()
        .presentationDetents([.medium])
    }

    private func sizeLine(_ result: VideoShrinkResult) -> String {
        let now = ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file)
        guard let original = result.originalBytes, original > 0 else { return now }
        return "\(now) (was \(ByteCountFormatter.string(fromByteCount: original, countStyle: .file)))"
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
