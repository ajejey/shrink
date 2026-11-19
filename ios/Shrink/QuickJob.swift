import AVFoundation
import CoreLocation
import ImageIO
import Photos
import PhotosUI
import ShrinkCore
import SwiftUI

/// One quick extra from Home, from picking a video to the finished file:
/// opening → (choosing the frame or the GIF's part) → working → done (or failed).
@Observable
@MainActor
final class QuickJob {
    /// The jobs, each in the person's words.
    enum Kind: String, CaseIterable, Identifiable {
        case sound, mute, frame, gif

        var id: String { rawValue }

        var title: String {
            switch self {
            case .sound: return "Get the sound from a video"
            case .mute: return "Mute a video"
            case .frame: return "Save a frame as a photo"
            case .gif: return "Make a GIF"
            }
        }

        var detail: String {
            switch self {
            case .sound: return "Save it as an audio file (M4A)"
            case .mute: return "The same video with no sound"
            case .frame: return "Pick the moment; it goes into Photos"
            case .gif: return "From a video or Live Photo"
            }
        }

        var symbol: String {
            switch self {
            case .sound: return "waveform"
            case .mute: return "speaker.slash"
            case .frame: return "photo"
            case .gif: return "square.stack.3d.forward.dottedline"
            }
        }

        var pickerFilter: PHPickerFilter {
            self == .gif ? .any(of: [.videos, .livePhotos]) : .videos
        }

        fileprivate var failedTitle: String {
            switch self {
            case .sound: return "Couldn't get the sound"
            case .mute: return "Couldn't mute this video"
            case .frame: return "Couldn't save the frame"
            case .gif: return "Couldn't make the GIF"
            }
        }
    }

    enum Phase {
        case opening
        case choosing(PickedVideo)
        /// nil when there's no percentage to follow (it takes a second or two).
        case working(Double?)
        case done(Finished)
        case failed(String)
    }

    struct Finished {
        let url: URL
        let bytes: Int64
        /// "M4A audio · 2:31", "480 × 270 · 3 seconds": what was made, in plain words.
        let detail: String
    }

    enum SaveState: Equatable {
        case notSaved, saving, saved
        case failed(String)
    }

    /// The GIF sizes offered, by their longest side.
    enum GIFSize: Int, CaseIterable, Identifiable {
        case small = 320, medium = 480, large = 640
        var id: Int { rawValue }
        var name: String {
            switch self {
            case .small: return "Small"
            case .medium: return "Medium"
            case .large: return "Large"
            }
        }
    }

    var kind: Kind = .sound
    var phase: Phase = .opening
    var isShowing = false
    /// Saving what was made into Photos (the frame saves itself; a muted video or GIF on request).
    var saveState: SaveState = .notSaved
    /// Set by "Pick another video": once this screen closes, Home opens the Photos picker again.
    private(set) var wantsAnother = false
    private var picked: PickedVideo?
    private var facts = QuickExtras.Facts()
    private var folder: URL?
    private var task: Task<Void, Never>?

    var title: String { kind.title }
    var failedTitle: String { kind.failedTitle }

    /// What a saved frame takes from the video, only what the video really says ("with the video's
    /// date and place"); nil when it says neither.
    var keptFromVideo: String? {
        switch (facts.created != nil, facts.latitude != nil) {
        case (true, true): return "with the video's date and place"
        case (true, false): return "with the video's date"
        case (false, true): return "with the video's place"
        case (false, false): return nil
        }
    }

    var isFinished: Bool {
        switch phase {
        case .done, .failed: return true
        case .opening, .choosing, .working: return false
        }
    }

    /// What was picked in Photos: a video, or (for a GIF) a Live Photo, whose moving part is used.
    func open(item: PhotosPickerItem, kind: Kind) {
        reset(kind: kind)
        let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        task = Task {
            do {
                let url: URL
                if isVideo {
                    guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                        throw ShrinkError.couldNotRead("Couldn't open that video.")
                    }
                    url = movie.url
                } else {
                    guard let live = try await item.loadTransferable(type: PHLivePhoto.self) else {
                        throw ShrinkError.couldNotRead("Couldn't open that Live Photo.")
                    }
                    url = try await Self.movingPart(of: live)
                }
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                try await begin(with: url)
            } catch is CancellationError {
            } catch ShrinkError.cancelled {
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Saves the frame at `seconds` into Photos, with the video's date (moved on to that moment) and place.
    func saveFrame(at seconds: Double) {
        guard let picked else { return }
        task?.cancel()
        phase = .working(nil)
        saveState = .saving
        let output = newFile("Frame.jpg")
        let facts = facts
        task = Task {
            do {
                let image = try await QuickExtras.frame(of: AVURLAsset(url: picked.url), at: seconds)
                let bytes = try await Task.detached(priority: .userInitiated) {
                    try QuickExtras.writeJPEG(image, to: output)
                }.value
                try Task.checkCancellation()
                phase = .done(Finished(url: output, bytes: bytes, detail: "\(image.width) × \(image.height)"))
                await save(output, as: .photo, created: facts.created.map { $0.addingTimeInterval(seconds) },
                           latitude: facts.latitude, longitude: facts.longitude)
            } catch is CancellationError {
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Back to the frames after one was saved, to save another.
    func pickAnotherFrame() {
        guard let picked else { return }
        saveState = .notSaved
        phase = .choosing(picked)
    }

    func makeGIF(part: ClosedRange<Double>, size: GIFSize) {
        guard let picked else { return }
        task?.cancel()
        phase = .working(0)
        let output = newFile("GIF.gif")
        let options = QuickExtras.GIFOptions(start: part.lowerBound, end: part.upperBound, longSide: size.rawValue)
        task = Task {
            do {
                let bytes = try await QuickExtras.makeGIF(from: AVURLAsset(url: picked.url), options: options,
                                                          to: output) { [weak self] value in
                    Task { @MainActor in
                        guard let self, case .working = self.phase else { return }
                        self.phase = .working(value)
                    }
                }
                try Task.checkCancellation()
                let pixels = Self.pixelSize(of: output)
                let seconds = Int((part.upperBound - part.lowerBound).rounded())
                phase = .done(Finished(url: output, bytes: bytes,
                                       detail: "\(pixels) · \(seconds) second\(seconds == 1 ? "" : "s")"))
            } catch is CancellationError {
            } catch ShrinkError.cancelled {
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// "Save to Photos" for a muted video (with the original's date and place) or a GIF (dated now).
    func saveToPhotos() {
        guard case .done(let finished) = phase, saveState != .saving, saveState != .saved else { return }
        let facts = kind == .mute ? facts : QuickExtras.Facts()
        Task {
            await save(finished.url, as: kind == .mute ? .video : .photo, created: facts.created,
                       latitude: facts.latitude, longitude: facts.longitude)
        }
    }

    func close() {
        task?.cancel()
        isShowing = false
        removePicked()
    }

    func pickAnother() {
        wantsAnother = true
        close()
    }

    func takeWantsAnother() -> Bool {
        defer { wantsAnother = false }
        return wantsAnother
    }

    // MARK: - Steps

    private func reset(kind: Kind) {
        task?.cancel()
        removePicked()
        Self.removeOldResults()
        self.kind = kind
        facts = QuickExtras.Facts()
        folder = nil
        saveState = .notSaved
        wantsAnother = false
        phase = .opening
        isShowing = true
    }

    private func begin(with url: URL) async throws {
        do {
            let asset = AVURLAsset(url: url)
            facts = await QuickExtras.facts(of: asset)
            switch kind {
            case .frame, .gif:
                let video = try await PickedVideo.examine(url)
                try Task.checkCancellation()
                picked = video
                phase = .choosing(video)
            case .sound:
                picked = try await PickedVideo.examine(url)
                phase = .working(nil)
                let output = newFile("Sound.m4a")
                let bytes = try await QuickExtras.extractSound(from: asset, to: output)
                try Task.checkCancellation()
                let seconds = try await AVURLAsset(url: output).load(.duration).seconds
                phase = .done(Finished(url: output, bytes: bytes, detail: "M4A audio · \(Clock.string(seconds)) long"))
            case .mute:
                picked = try await PickedVideo.examine(url)
                phase = .working(nil)
                let output = newFile("Muted video.mov")
                let bytes = try await QuickExtras.mute(asset, to: output, keepLocation: !AppSettings.removeLocation)
                try Task.checkCancellation()
                let length = Clock.string(picked?.duration ?? 0)
                phase = .done(Finished(url: output, bytes: bytes, detail: "Same picture, no sound · \(length) long"))
            }
        } catch {
            if picked == nil, PickedVideo.isOurCopy(url) { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    private func save(_ url: URL, as type: PHAssetResourceType, created: Date?, latitude: Double?, longitude: Double?) async {
        saveState = .saving
        do {
            try await PhotoSaver.save(url, as: type, created: created, latitude: latitude, longitude: longitude)
            saveState = .saved
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    /// A file with a plain name ("GIF.gif") in this job's own folder, so it reads well when shared.
    private func newFile(_ name: String) -> URL {
        let folder = folder ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("Quick-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.folder = folder
        let url = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    private func removePicked() {
        if let picked, picked.isOurCopy { try? FileManager.default.removeItem(at: picked.url) }
        picked = nil
    }

    /// A Live Photo's moving part, copied out as a video (the edited one when it was edited).
    private static func movingPart(of live: PHLivePhoto) async throws -> URL {
        let resources = PHAssetResource.assetResources(for: live)
        guard let video = resources.first(where: { $0.type == .fullSizePairedVideo })
            ?? resources.first(where: { $0.type == .pairedVideo }) else {
            throw ShrinkError.couldNotRead("This Live Photo's moving part couldn't be found.")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("picked-\(UUID().uuidString).mov")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: video, toFile: url, options: options)
        return url
    }

    /// "480 × 270", read from the file.
    private static func pixelSize(of url: URL) -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return "GIF" }
        return "\(width) × \(height)"
    }

    /// Files from earlier quick jobs. Kept until the next one so a share in progress never loses its file.
    private static func removeOldResults() {
        let folder = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("Quick-") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    // MARK: - Screenshots

    /// A job frozen in one state for CI screenshots (`-screenshot quick-…`). The choosing and done
    /// states open tmp/sample-video.mp4 (CI copies it in) and really make the frame or GIF.
    static func preview(_ state: String) -> QuickJob {
        let job = QuickJob()
        job.isShowing = true
        let sample = FileManager.default.temporaryDirectory.appendingPathComponent("sample-video.mp4")
        func choose(_ kind: Kind, then next: ((PickedVideo) async throws -> Void)? = nil) {
            job.kind = kind
            job.facts = QuickExtras.Facts(created: Date(timeIntervalSince1970: 1_794_823_200),
                                          latitude: 48.8584, longitude: 2.2945)
            job.task = Task {
                do {
                    let video = try await PickedVideo.examine(sample)
                    job.picked = video
                    job.phase = .choosing(video)
                    try await next?(video)
                } catch {
                    job.phase = .failed(error.localizedDescription)
                }
            }
        }
        switch state {
        case "quick-frame":
            choose(.frame)
        case "quick-gif":
            choose(.gif)
        case "quick-frame-done":
            choose(.frame) { video in
                let image = try await QuickExtras.frame(of: AVURLAsset(url: video.url), at: video.duration / 2)
                let output = job.newFile("Frame.jpg")
                let bytes = try QuickExtras.writeJPEG(image, to: output)
                job.phase = .done(Finished(url: output, bytes: bytes, detail: "\(image.width) × \(image.height)"))
                job.saveState = .saved
            }
        case "quick-gif-done":
            choose(.gif) { video in
                let output = job.newFile("GIF.gif")
                let end = min(video.duration, 3)
                let bytes = try await QuickExtras.makeGIF(from: AVURLAsset(url: video.url),
                                                          options: .init(start: 0, end: end, longSide: 480), to: output)
                job.phase = .done(Finished(url: output, bytes: bytes,
                                           detail: "\(pixelSize(of: output)) · \(Int(end.rounded())) seconds"))
            }
        case "quick-sound-done":
            job.kind = .sound
            job.phase = .done(Finished(url: sample, bytes: 2_480_000, detail: "M4A audio · 2:31 long"))
        case "quick-mute-done":
            job.kind = .mute
            job.phase = .done(Finished(url: sample, bytes: 48_200_000, detail: "Same picture, no sound · 2:31 long"))
        case "quick-mute-saved":
            job.kind = .mute
            job.phase = .done(Finished(url: sample, bytes: 48_200_000, detail: "Same picture, no sound · 2:31 long"))
            job.saveState = .saved
        case "quick-failed":
            job.kind = .sound
            job.phase = .failed(ShrinkError.noSound.localizedDescription)
        default:
            job.kind = .gif
            job.phase = .working(0.42)
        }
        return job
    }
}

/// Saves what a quick extra made into the person's library as a new item.
enum PhotoSaver {
    /// Asks only for permission to add to Photos (not to see the library) the first time.
    static func save(_ url: URL, as type: PHAssetResourceType, created: Date?,
                     latitude: Double?, longitude: Double?) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ShrinkError.couldNotMake("Shrink isn't allowed to save to Photos. You can allow it in Settings > Shrink > Photos.")
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: type, fileURL: url, options: nil)
                if let created { request.creationDate = created }
                if let latitude, let longitude {
                    request.location = CLLocation(latitude: latitude, longitude: longitude)
                }
            }
        } catch {
            throw ShrinkError.couldNotMake("Photos didn't save it. \(error.localizedDescription)")
        }
    }
}
