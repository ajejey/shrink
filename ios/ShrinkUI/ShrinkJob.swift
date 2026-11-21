import AVFoundation
import PhotosUI
import ShrinkCore
import SwiftUI
import UniformTypeIdentifiers

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

    enum Kind { case video, photo }

    var phase: Phase = .opening
    var isShowing = false
    var kind: Kind = .video
    /// The job in the person's words: "Compress for Discord".
    var title = ""
    /// "20 MB", shown on the trim screen and with the result. nil when there's no limit (JPG only).
    var limitLabel: String?
    /// nil when there's no limit (convert a photo to JPG).
    var targetBytes: Int64?
    var removeLocation = true
    /// The app offers "Pick another video" after a failure; the share sheet has only the one file.
    var offersAnother = false
    /// Set by "Pick another video": once this screen closes, the app opens the Photos picker again.
    private(set) var wantsAnother = false
    private var picked: PickedVideo?
    private var task: Task<Void, Never>?

    /// Finished one way or the other: the button says "Done" instead of "Cancel".
    var isFinished: Bool {
        switch phase {
        case .done, .failed: return true
        case .opening, .choosing, .shrinking: return false
        }
    }

    /// From the app: what was picked in Photos. A video goes to the trim screen, a photo is shrunk straight away.
    func open(item: PhotosPickerItem, destination: Destination, removeLocation: Bool) {
        let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        start(isVideo: isVideo, destination: destination, removeLocation: removeLocation) {
            let url: URL?
            if isVideo {
                url = try await item.loadTransferable(type: PickedMovie.self)?.url
            } else {
                url = try await item.loadTransferable(type: PickedPhoto.self)?.url
            }
            guard let url else {
                throw ShrinkError.couldNotRead(isVideo ? "Couldn't open that video." : "Couldn't open that photo.")
            }
            return url
        }
    }

    /// From the share sheet: a file it already copied somewhere we can read it (and removes itself).
    func open(url: URL, isVideo: Bool, destination: Destination, removeLocation: Bool) {
        start(isVideo: isVideo, destination: destination, removeLocation: removeLocation) { url }
    }

    private func start(isVideo: Bool, destination: Destination, removeLocation: Bool,
                       file: @escaping () async throws -> URL) {
        reset(title: destination.title, limitLabel: destination.limitLabel, targetBytes: destination.limitBytes,
              removeLocation: removeLocation)
        RecentPlaces.remember(destination)
        kind = isVideo ? .video : .photo
        if isVideo, destination.limitBytes == nil {
            phase = .failed("This one makes photos into JPGs. To shrink a video, pick where it's going instead.")
            return
        }
        task = Task {
            do {
                let url = try await file()
                if Task.isCancelled {
                    // Cancelled while Photos was still handing it over: don't leave the copy behind.
                    if PickedVideo.isOurCopy(url) { try? FileManager.default.removeItem(at: url) }
                    return
                }
                if isVideo {
                    try await choose(url: url)
                } else {
                    try await shrinkPhoto(at: url)
                }
            } catch is CancellationError {
            } catch ShrinkError.cancelled {
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Shrinks the part the person picked on the trim screen.
    func shrink(part: ClosedRange<Double>) {
        guard let picked, let targetBytes else { return }
        task?.cancel()
        phase = .shrinking(0)
        let range = CMTimeRange(
            start: CMTime(seconds: part.lowerBound, preferredTimescale: 600),
            end: CMTime(seconds: part.upperBound, preferredTimescale: 600)
        )
        // The whole video (within a frame) needs no trim; nil keeps every last sample.
        let wholeVideo = part.lowerBound <= 0.01 && part.upperBound >= picked.duration - 0.01
        let options = SendingOptions.current.video(targetBytes: targetBytes, removeLocation: removeLocation,
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

    /// After a failure: close, then the app opens the Photos picker again for the same place.
    func pickAnother() {
        wantsAnother = true
        close()
    }

    /// True once after "Pick another video" (the app reads it when this screen has closed).
    func takeWantsAnother() -> Bool {
        defer { wantsAnother = false }
        return wantsAnother
    }

    /// "Compress for Discord (20 MB)", for a problem report.
    var jobDescription: String {
        guard let limitLabel, !title.contains(limitLabel) else { return title }
        return "\(title) (\(limitLabel))"
    }

    // MARK: - Steps

    private func reset(title: String, limitLabel: String?, targetBytes: Int64?, removeLocation: Bool) {
        task?.cancel()
        removePicked()
        Self.removeOldResults()
        self.title = title
        self.limitLabel = limitLabel
        self.targetBytes = targetBytes
        self.removeLocation = removeLocation
        wantsAnother = false
        kind = .video
        phase = .opening
        isShowing = true
    }

    /// A photo made into a JPEG under the limit (any HEIC becomes JPG).
    private func shrinkPhoto(at url: URL) async throws {
        defer { if PickedVideo.isOurCopy(url) { try? FileManager.default.removeItem(at: url) } }
        phase = .shrinking(0)
        let originalBytes = Self.fileSize(url)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("Shrink-\(UUID().uuidString.prefix(6)).jpg")
        let targetBytes = targetBytes, removeLocation = removeLocation, sending = SendingOptions.current
        // PhotoShrinker works synchronously; keep it off the main thread.
        let result = try await Task.detached(priority: .userInitiated) {
            try sending.photo(at: url, to: output, targetBytes: targetBytes, removeLocation: removeLocation)
        }.value
        try Task.checkCancellation()
        phase = .done(Finished(url: result.url, bytes: result.bytes, originalBytes: originalBytes > 0 ? originalBytes : nil))
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

    private static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Finished files from earlier jobs. Kept until the next job so a share in progress never loses its file.
    private static func removeOldResults() {
        let folder = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("Shrink-") && (name.hasSuffix(".mp4") || name.hasSuffix(".jpg")) {
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
            job.offersAnother = true
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
    /// Frames per second as filmed (30 when the file doesn't say).
    let frameRate: Double
    /// A copy we made (from the Photos picker), deleted when the job closes.
    let isOurCopy: Bool

    static func examine(_ url: URL) async throws -> PickedVideo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ShrinkError.noVideo }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let hasAudio = !audioTracks.isEmpty
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw ShrinkError.couldNotRead("It has no length.") }
        let (size, transform, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let upright = size.applying(transform)
        let width = abs(upright.width), height = abs(upright.height)
        return PickedVideo(
            url: url, duration: duration, hasAudio: hasAudio,
            longSide: Int(max(width, height).rounded()),
            aspectRatio: height > 0 ? Double(width / height) : 16.0 / 9.0,
            frameRate: rate > 0 ? Double(rate) : 30,
            isOurCopy: isOurCopy(url)
        )
    }

    /// Copies the Photos picker hands us are named picked-… (see PickedMovie).
    static func isOurCopy(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("picked-")
    }
}

/// A photo handed over by the Photos picker (HEIC, JPEG, PNG…), copied somewhere we can read it.
struct PickedPhoto: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .image) { photo in
            SentTransferredFile(photo.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked-\(UUID().uuidString)")
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedPhoto(url: copy)
        }
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
