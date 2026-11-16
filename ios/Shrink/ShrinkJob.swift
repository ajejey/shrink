import AVFoundation
import PhotosUI
import ShrinkCore
import SwiftUI

/// One shrink, from picking a video to a file ready to send:
/// opening → choosing the part to send (trim) → shrinking → done (or failed).
@Observable
@MainActor
final class ShrinkJob {
    enum Phase {
        case opening
        case choosing(PickedVideo)
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
    /// The job in the person's words: "Compress for Discord".
    var title = ""
    /// "20 MB", shown on the trim screen and with the result.
    var limitLabel: String?
    var targetBytes: Int64 = 0
    var removeLocation = true
    private var picked: PickedVideo?
    private var task: Task<Void, Never>?

    /// Finished one way or the other: the button says "Done" instead of "Cancel".
    var isFinished: Bool {
        switch phase {
        case .done, .failed: return true
        case .opening, .choosing, .shrinking: return false
        }
    }

    /// Opens the picked video and shows the trim screen.
    func open(item: PhotosPickerItem, preset: Preset, removeLocation: Bool) {
        guard let limit = preset.limitBytes else { return }
        reset(title: preset.title, limitLabel: preset.limitLabel, targetBytes: limit, removeLocation: removeLocation)
        task = Task {
            do {
                guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                    throw ShrinkError.couldNotRead("Couldn't open that video.")
                }
                if Task.isCancelled {
                    // Cancelled while Photos was still handing it over: don't leave the copy behind.
                    try? FileManager.default.removeItem(at: movie.url)
                    return
                }
                try await choose(url: movie.url)
            } catch is CancellationError {
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Shrinks the part the person picked on the trim screen.
    func shrink(part: ClosedRange<Double>) {
        guard let picked else { return }
        task?.cancel()
        phase = .shrinking(0)
        let range = CMTimeRange(
            start: CMTime(seconds: part.lowerBound, preferredTimescale: 600),
            end: CMTime(seconds: part.upperBound, preferredTimescale: 600)
        )
        // The whole video (within a frame) needs no trim; nil keeps every last sample.
        let wholeVideo = part.lowerBound <= 0.01 && part.upperBound >= picked.duration - 0.01
        let options = VideoShrinkOptions(targetBytes: targetBytes, removeLocation: removeLocation,
                                         timeRange: wholeVideo ? nil : range)
        task = Task {
            do {
                let output = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Shrink-\(UUID().uuidString.prefix(6)).mp4")
                let result = try await VideoShrinker().shrink(
                    asset: AVURLAsset(url: picked.url), to: output, options: options
                ) { [weak self] value in
                    Task { @MainActor in
                        guard let self, case .shrinking = self.phase else { return }
                        self.phase = .shrinking(value)
                    }
                }
                phase = .done(Finished(url: result.url, bytes: result.bytes, originalBytes: result.originalBytes))
            } catch ShrinkError.cancelled {
                // Cancelled by the person; nothing to show.
            } catch is CancellationError {
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func close() {
        task?.cancel()
        isShowing = false
        removePicked()
    }

    // MARK: - Steps

    private func reset(title: String, limitLabel: String?, targetBytes: Int64, removeLocation: Bool) {
        task?.cancel()
        removePicked()
        Self.removeOldResults()
        self.title = title
        self.limitLabel = limitLabel
        self.targetBytes = targetBytes
        self.removeLocation = removeLocation
        phase = .opening
        isShowing = true
    }

    /// Reads what the trim screen needs to know about the video, then shows it.
    private func choose(url: URL) async throws {
        do {
            let video = try await PickedVideo.examine(url)
            try Task.checkCancellation()
            picked = video
            phase = .choosing(video)
        } catch {
            if PickedVideo.isOurCopy(url) { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    private func removePicked() {
        if let picked, picked.isOurCopy { try? FileManager.default.removeItem(at: picked.url) }
        picked = nil
    }

    /// Finished files from earlier jobs. Kept until the next job so a share in progress never loses its file.
    private static func removeOldResults() {
        let folder = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("Shrink-") && name.hasSuffix(".mp4") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    // MARK: - Screenshots

    /// A job frozen in one state, for CI screenshots (`-screenshot trim|shrinking|done|failed`).
    /// "trim" opens tmp/sample-video.mp4, which CI copies into the app's folder first.
    static func preview(_ state: String) -> ShrinkJob {
        let job = ShrinkJob()
        job.title = "Compress for Discord"
        job.limitLabel = "20 MB"
        job.targetBytes = 20_000_000
        job.isShowing = true
        switch state {
        case "trim":
            let sample = FileManager.default.temporaryDirectory.appendingPathComponent("sample-video.mp4")
            job.task = Task {
                do { try await job.choose(url: sample) } catch { job.phase = .failed(error.localizedDescription) }
            }
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

/// A video ready to trim: where it is and what the trim screen needs to know about it.
struct PickedVideo {
    let url: URL
    let duration: Double
    let hasAudio: Bool
    /// Longest side of the upright picture, in pixels.
    let longSide: Int
    /// Width over height of the upright picture.
    let aspectRatio: Double
    /// A copy we made (from the Photos picker), deleted when the job closes.
    let isOurCopy: Bool

    static func examine(_ url: URL) async throws -> PickedVideo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ShrinkError.noVideo }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let hasAudio = !audioTracks.isEmpty
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw ShrinkError.couldNotRead("It has no length.") }
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        let upright = size.applying(transform)
        let width = abs(upright.width), height = abs(upright.height)
        return PickedVideo(
            url: url, duration: duration, hasAudio: hasAudio,
            longSide: Int(max(width, height).rounded()),
            aspectRatio: height > 0 ? Double(width / height) : 16.0 / 9.0,
            isOurCopy: isOurCopy(url)
        )
    }

    /// Copies the Photos picker hands us are named picked-… (see PickedMovie).
    static func isOurCopy(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("picked-")
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
