import AVFoundation
import AVKit
import ImageIO
import ShrinkCore
import SwiftUI

/// The whole screen for one quick extra: choose the frame or the GIF's part, wait a moment, then
/// send or save what was made.
struct QuickJobView: View {
    let job: QuickJob
    @State private var showReport = false

    var body: some View {
        NavigationStack {
            Group {
                if case .choosing(let video) = job.phase {
                    if job.kind == .frame {
                        FrameChooser(video: video) { seconds in job.saveFrame(at: seconds) }
                    } else {
                        GIFChooser(video: video) { part, size in job.makeGIF(part: part, size: size) }
                    }
                } else {
                    status
                }
            }
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

    private var status: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            switch job.phase {
            case .opening, .choosing:
                ProgressView()
                    .controlSize(.large)
                Text("Opening the video…")
                    .font(.title3)
            case .working(let value):
                working(value)
            case .done(let result):
                done(result)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.orange)
                Text(job.failedTitle)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            buttons
        }
        .padding(24)
    }

    @ViewBuilder private func working(_ value: Double?) -> some View {
        switch job.kind {
        case .gif:
            Text("Making your GIF")
                .font(.title2.bold())
            Text("\(Int((value ?? 0) * 100))%")
                .font(.system(size: 72, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.default, value: Int((value ?? 0) * 100))
            ProgressView(value: value ?? 0)
                .scaleEffect(x: 1, y: 3, anchor: .center)
                .padding(.horizontal, 8)
        default:
            ProgressView()
                .controlSize(.large)
            Text(job.kind == .sound ? "Getting the sound…" : job.kind == .mute ? "Taking the sound out…" : "Saving the frame…")
                .font(.title2.bold())
        }
    }

    @ViewBuilder private func done(_ result: QuickJob.Finished) -> some View {
        switch job.kind {
        case .gif:
            AnimatedGIF(url: result.url)
                .frame(maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text("GIF ready")
                .font(.largeTitle.bold())
            Text("\(result.detail) · \(SizeFormat.string(result.bytes))")
                .font(.title3)
        case .frame:
            StillImage(url: result.url)
                .frame(maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(job.saveState == .saved ? "Saved to Photos" : "Frame ready")
                .font(.largeTitle.bold())
            Text(job.saveState == .saved ? "\(result.detail), with the video's date and place" : result.detail)
                .font(.title3)
                .multilineTextAlignment(.center)
        case .sound, .mute:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
            Text(job.kind == .sound ? "Sound ready" : "Muted video ready")
                .font(.largeTitle.bold())
            VStack(spacing: 6) {
                Text(result.detail)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                Text(SizeFormat.string(result.bytes))
                    .foregroundStyle(.secondary)
            }
        }
        if case .failed(let why) = job.saveState {
            Label(why, systemImage: "exclamationmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        }
    }

    @ViewBuilder private var buttons: some View {
        switch job.phase {
        case .done(let result):
            VStack(spacing: 10) {
                switch job.kind {
                case .sound:
                    sendButton(result, label: "Send or save it", prominent: true)
                case .mute, .gif:
                    saveButton(prominent: job.kind == .mute)
                    sendButton(result, label: "Send it", prominent: job.kind == .gif)
                case .frame:
                    if job.saveState != .saved, job.saveState != .saving { saveButton(prominent: true) }
                    Button {
                        job.pickAnotherFrame()
                    } label: {
                        Text("Save another frame")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    sendButton(result, label: "Send it", prominent: false)
                }
            }
        case .failed(let message):
            VStack(spacing: 10) {
                Button {
                    job.pickAnother()
                } label: {
                    Text("Pick another video")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                if SupportContact.reportURL != nil {
                    Button {
                        showReport = true
                    } label: {
                        Text("Report a problem")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .sheet(isPresented: $showReport) {
                        ReportProblemView(report: ProblemReport(job: job.title, problem: message))
                    }
                }
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func saveButton(prominent: Bool) -> some View {
        let button = Button {
            job.saveToPhotos()
        } label: {
            Group {
                switch job.saveState {
                case .saved: Label("Saved to Photos", systemImage: "checkmark")
                case .saving: Text("Saving…")
                default: Text("Save to Photos")
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .disabled(job.saveState == .saved || job.saveState == .saving)
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    @ViewBuilder private func sendButton(_ result: QuickJob.Finished, label: String, prominent: Bool) -> some View {
        let link = ShareLink(item: result.url) {
            Label(label, systemImage: "square.and.arrow.up")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        if prominent {
            link.buttonStyle(.borderedProminent)
        } else {
            link.buttonStyle(.bordered)
        }
    }
}

// MARK: - Save a frame as a photo

/// Slide to the moment, nudge a frame at a time, then save that exact frame.
struct FrameChooser: View {
    let video: PickedVideo
    let onSave: (Double) -> Void

    @State private var position: Double
    @State private var image: UIImage?
    /// One frame's length (from the video's frame rate).
    @State private var step = 1.0 / 30

    init(video: PickedVideo, onSave: @escaping (Double) -> Void) {
        self.video = video
        self.onSave = onSave
        _position = State(initialValue: video.duration / 2)
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("Pick the moment")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground))
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    ProgressView()
                }
            }
            .aspectRatio(video.aspectRatio, contentMode: .fit)
            .frame(maxHeight: 380)

            Slider(value: $position, in: 0...max(video.duration - step, 0.01))
                .accessibilityLabel("Moment in the video")
                .accessibilityValue(FrameClock.string(position))

            HStack {
                nudge(-1, symbol: "backward.frame.fill", label: "One frame back")
                Spacer()
                Text(FrameClock.string(position))
                    .font(.headline.monospacedDigit())
                Spacer()
                nudge(1, symbol: "forward.frame.fill", label: "One frame on")
            }

            Spacer(minLength: 0)

            Text("It goes into Photos with the video's date and place.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                onSave(position)
            } label: {
                Text("Save this frame")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(20)
        .task {
            let asset = AVURLAsset(url: video.url)
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let rate = try? await track.load(.nominalFrameRate), rate > 0 {
                step = 1 / Double(rate)
            }
        }
        .task(id: position) {
            // The exact frame, fetched again whenever the slider moves (an older fetch is cancelled).
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video.url))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.maximumSize = CGSize(width: 1200, height: 1200)
            if let frame = try? await generator.image(at: CMTime(seconds: position, preferredTimescale: 600)),
               !Task.isCancelled {
                image = UIImage(cgImage: frame.image)
            }
        }
    }

    private func nudge(_ direction: Double, symbol: String, label: String) -> some View {
        Button {
            position = min(max(0, position + direction * step), max(video.duration - step, 0))
        } label: {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 56, height: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(label)
    }
}

/// "0:12.4": minutes, seconds and tenths, so a frame step shows.
enum FrameClock {
    static func string(_ seconds: Double) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded(.down))
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }
}

// MARK: - Make a GIF

/// Pick the part (up to 15 seconds) and the size, then make the GIF.
struct GIFChooser: View {
    let video: PickedVideo
    let onMake: (ClosedRange<Double>, QuickJob.GIFSize) -> Void

    @State private var start: Double = 0
    @State private var end: Double
    @State private var size: QuickJob.GIFSize = .medium
    @State private var player: AVPlayer
    @State private var frames: [UIImage] = []

    init(video: PickedVideo, onMake: @escaping (ClosedRange<Double>, QuickJob.GIFSize) -> Void) {
        self.video = video
        self.onMake = onMake
        _end = State(initialValue: min(video.duration, 5))
        let player = AVPlayer(url: video.url)
        player.isMuted = true
        _player = State(initialValue: player)
    }

    private var length: Double { end - start }
    private var tooLong: Bool { length > QuickExtras.longestGIFSeconds + 0.01 }

    var body: some View {
        VStack(spacing: 14) {
            Text("Pick the part for the GIF")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)

            VideoPlayer(player: player)
                .aspectRatio(video.aspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .frame(maxHeight: 260)

            TrimBar(duration: video.duration, start: $start, end: $end, frames: frames,
                    shortest: min(QuickExtras.shortestGIFSeconds, video.duration))
                .frame(height: 56)
                .padding(.top, 4)

            HStack {
                Text(FrameClock.string(start))
                Spacer()
                Text("\(FrameClock.string(length)) long")
                    .fontWeight(.semibold)
                Spacer()
                Text(FrameClock.string(end))
            }
            .font(.subheadline.monospacedDigit())

            if tooLong {
                Label {
                    Text("A GIF can be up to 15 seconds. Make the part shorter.").fontWeight(.medium)
                } icon: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Size")
                    .font(.headline)
                Picker("Size", selection: $size) {
                    ForEach(QuickJob.GIFSize.allCases) { option in
                        Text(option.name).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                Text(sizeNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            Button {
                player.pause()
                onMake(start...end, size)
            } label: {
                Text("Make the GIF")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(tooLong || length < QuickExtras.shortestGIFSeconds - 0.01)
        }
        .padding(20)
        .task { frames = await TrimView.filmstrip(of: video, count: 8) }
        .onAppear {
            player.currentItem?.forwardPlaybackEndTime = time(end)
            player.play()
        }
        .onDisappear { player.pause() }
        .onChange(of: start) { _, value in
            player.seek(to: time(value), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        .onChange(of: end) { _, value in
            player.currentItem?.forwardPlaybackEndTime = time(value)
            player.seek(to: time(max(start, value - 1)), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            // A GIF loops, so the preview does too.
            guard (note.object as? AVPlayerItem) === player.currentItem else { return }
            player.seek(to: time(start), toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
        }
    }

    private var sizeNote: String {
        switch size {
        case .small: return "\(size.rawValue) pixels across. Quick to send in chats."
        case .medium: return "\(size.rawValue) pixels across. Good for most places."
        case .large: return "\(size.rawValue) pixels across. Sharper, but a bigger file."
        }
    }

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }
}

// MARK: - Showing what was made

/// A GIF playing on a loop. At most 90 frames, each at most 400 pixels, so a long GIF can't use up memory.
struct AnimatedGIF: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.image = Self.animation(from: url)
        view.accessibilityLabel = "The GIF"
        view.isAccessibilityElement = true
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {}

    static func animation(from url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        let every = max(1, Int((Double(count) / 90).rounded(.up)))
        var images: [UIImage] = []
        var duration = 0.0
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceThumbnailMaxPixelSize: 400] as CFDictionary
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            duration += (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? 0.1
            guard index % every == 0, let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options) else { continue }
            images.append(UIImage(cgImage: frame))
        }
        return UIImage.animatedImage(with: images, duration: duration)
    }
}

/// A saved frame, read small.
struct StillImage: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color(.secondarySystemBackground)
            }
        }
        .task {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let small = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 900,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary) else { return }
            image = UIImage(cgImage: small)
        }
        .accessibilityLabel("The frame")
    }
}
