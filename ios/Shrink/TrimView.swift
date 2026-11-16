import AVFoundation
import AVKit
import ShrinkCore
import SwiftUI

/// Pick the part of the video to send, see whether it fits, then shrink it.
/// Cutting length is what shrinks a file most, so this comes before the size work.
struct TrimView: View {
    let video: PickedVideo
    let targetBytes: Int64
    let limitLabel: String?
    let onShrink: (ClosedRange<Double>) -> Void

    @State private var start: Double = 0
    @State private var end: Double
    @State private var player: AVPlayer
    @State private var frames: [UIImage] = []
    /// The whole video was too long to fit, so only its start is picked to begin with.
    private let startsShortened: Bool

    /// Longest the part can be and still fit at all, and still look sharp.
    private let longestThatFits: Double
    private let longestThatLooksSharp: Double

    init(video: PickedVideo, targetBytes: Int64, limitLabel: String?, onShrink: @escaping (ClosedRange<Double>) -> Void) {
        self.video = video
        self.targetBytes = targetBytes
        self.limitLabel = limitLabel
        self.onShrink = onShrink
        let fits = SizePlanner.longestSeconds(targetBytes: targetBytes, hasAudio: video.hasAudio,
                                              sourceLongSide: video.longSide, sharp: false)
        longestThatFits = fits
        longestThatLooksSharp = SizePlanner.longestSeconds(targetBytes: targetBytes, hasAudio: video.hasAudio,
                                                           sourceLongSide: video.longSide, sharp: true)
        startsShortened = video.duration > fits
        _end = State(initialValue: startsShortened ? (fits * 0.98).rounded(.down) : video.duration)
        _player = State(initialValue: AVPlayer(url: video.url))
    }

    private var length: Double { end - start }
    private var fits: Bool { length <= longestThatFits }
    private var limit: String { limitLabel ?? "the limit" }

    var body: some View {
        VStack(spacing: 14) {
            Text("Pick the part to send")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)

            VideoPlayer(player: player)
                .aspectRatio(video.aspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 300)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            TrimBar(duration: video.duration, start: $start, end: $end, frames: frames)
                .frame(height: 56)
                .padding(.top, 4)

            HStack {
                Text(Clock.string(start))
                Spacer()
                Text("\(Clock.string(length)) long")
                    .fontWeight(.semibold)
                Spacer()
                Text(Clock.string(end))
            }
            .font(.subheadline.monospacedDigit())

            fitLine
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            Button {
                player.pause()
                onShrink(start...end)
            } label: {
                Text("Shrink it")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!fits || length < VideoShrinker.shortestTrimSeconds)
        }
        .padding(20)
        .task { frames = await Self.filmstrip(of: video, count: 8) }
        .onAppear { player.currentItem?.forwardPlaybackEndTime = time(end) }
        .onDisappear { player.pause() }
        .onChange(of: start) { _, value in
            player.pause()
            player.seek(to: time(value), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        .onChange(of: end) { _, value in
            player.pause()
            player.currentItem?.forwardPlaybackEndTime = time(value)
            player.seek(to: time(value), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            // Played to the end of the picked part: go back to its start, ready to play again.
            guard (note.object as? AVPlayerItem) === player.currentItem else { return }
            player.seek(to: time(start), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// Whether the picked part fits, in plain words, with what to do when it doesn't.
    @ViewBuilder private var fitLine: some View {
        if !fits {
            Label("Too long for \(limit). Make it shorter than \(Clock.string(longestThatFits)).",
                  systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        } else if length > longestThatLooksSharp {
            VStack(alignment: .leading, spacing: 4) {
                Label("Fits under \(limit), but it will look soft. Under \(Clock.string(longestThatLooksSharp)) stays sharp.",
                      systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                if startsShortened {
                    Text("The whole video is \(Clock.string(video.duration)), too long for \(limit), so only the start is picked.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Label("Fits under \(limit) and stays sharp.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// Small frames spread across the video, for the strip behind the trim handles.
    static func filmstrip(of video: PickedVideo, count: Int) async -> [UIImage] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 200, height: 200)
        var images: [UIImage] = []
        for index in 0..<count {
            let seconds = video.duration * (Double(index) + 0.5) / Double(count)
            if let frame = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) {
                images.append(UIImage(cgImage: frame.image))
            }
        }
        return images
    }
}

/// The strip of frames with a handle at each end of the picked part.
struct TrimBar: View {
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    let frames: [UIImage]
    /// Shortest part the handles allow.
    var shortest: Double = 1

    private let handleWidth: CGFloat = 22

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let track = max(1, geometry.size.width - handleWidth * 2)
            let x0 = handleWidth + CGFloat(start / duration) * track
            let x1 = handleWidth + CGFloat(end / duration) * track

            ZStack(alignment: .topLeading) {
                strip(width: track, height: height)
                    .offset(x: handleWidth)
                // Outside the picked part is dimmed.
                Rectangle().fill(.black.opacity(0.55))
                    .frame(width: max(0, x0 - handleWidth), height: height)
                    .offset(x: handleWidth)
                Rectangle().fill(.black.opacity(0.55))
                    .frame(width: max(0, handleWidth + track - x1), height: height)
                    .offset(x: x1)
                // The picked part: a frame top and bottom between the handles.
                Rectangle()
                    .strokeBorder(Color.yellow, lineWidth: 3)
                    .frame(width: max(0, x1 - x0), height: height)
                    .offset(x: x0)
                handle(edge: .leading)
                    .offset(x: x0 - handleWidth)
                    .gesture(drag { x in
                        // The finger holds the handle's middle; its inner edge is half a handle right.
                        let seconds = Double((x + handleWidth / 2 - handleWidth) / track) * duration
                        start = min(max(0, seconds), end - min(shortest, duration))
                    })
                    .accessibilityElement()
                    .accessibilityLabel("Start of the part to send")
                    .accessibilityValue(Clock.string(start))
                    .accessibilityAdjustableAction { direction in
                        let step = direction == .increment ? 1.0 : -1.0
                        start = min(max(0, start + step), end - min(shortest, duration))
                    }
                handle(edge: .trailing)
                    .offset(x: x1)
                    .gesture(drag { x in
                        // The finger holds the handle's middle; its inner edge is half a handle left.
                        let seconds = Double((x - handleWidth / 2 - handleWidth) / track) * duration
                        end = max(min(duration, seconds), start + min(shortest, duration))
                    })
                    .accessibilityElement()
                    .accessibilityLabel("End of the part to send")
                    .accessibilityValue(Clock.string(end))
                    .accessibilityAdjustableAction { direction in
                        let step = direction == .increment ? 1.0 : -1.0
                        end = max(min(duration, end + step), start + min(shortest, duration))
                    }
            }
            .coordinateSpace(name: "trimBar")
        }
    }

    private func strip(width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(frames.indices, id: \.self) { index in
                Image(uiImage: frames[index])
                    .resizable()
                    .scaledToFill()
                    .frame(width: width / CGFloat(max(frames.count, 1)), height: height)
                    .clipped()
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .background(Color.gray.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func handle(edge: HorizontalEdge) -> some View {
        UnevenRoundedRectangle(
            topLeadingRadius: edge == .leading ? 8 : 0, bottomLeadingRadius: edge == .leading ? 8 : 0,
            bottomTrailingRadius: edge == .trailing ? 8 : 0, topTrailingRadius: edge == .trailing ? 8 : 0
        )
        .fill(Color.yellow)
        .overlay(
            Image(systemName: edge == .leading ? "chevron.compact.left" : "chevron.compact.right")
                .font(.title3.bold())
                .foregroundStyle(.black.opacity(0.7))
        )
        .frame(width: handleWidth)
        // A bigger area to grab than the handle you see.
        .contentShape(Rectangle().inset(by: -12))
    }

    /// Follows the finger; `place` gets the finger's x in the bar.
    private func drag(_ place: @escaping (CGFloat) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("trimBar"))
            .onChanged { value in place(value.location.x) }
    }
}

/// "1:05", or "1:02:05" for an hour or more.
enum Clock {
    static func string(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
