import AVFoundation
import ImageIO
import PhotosUI
import ShrinkCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Send several at once (Shrink Pro): the one-file job for a whole pick from Photos, all for one place.
/// Each file fits the place's limit, or for an email (Gmail, Outlook) all of them fit in one email.
/// opening → checking (what fits, shown before anything starts) → working → finished.
@Observable
@MainActor
final class BatchSend {
    /// The most one pick can hold. Each file is copied out of Photos before the check, so this also
    /// caps the room the copies take.
    static let maxItems = 20

    enum Phase: Equatable {
        case opening(done: Int, of: Int)
        case checking
        case working
        case finished
    }

    enum State: Equatable {
        case waiting
        /// nil for a photo (a second or two, no percentage).
        case working(Double?)
        case done(url: URL, bytes: Int64)
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        let isVideo: Bool
        /// "Video 1", "Photo 2": also the name of the file that's sent.
        let name: String
        /// Our copy out of Photos (picked-…), removed once its file is made or the batch closes.
        var source: URL?
        var seconds: Double?
        var hasAudio = false
        var longSide = 0
        var frameRate: Double = 30
        var bytes: Int64 = 0
        var thumbnail: UIImage?
        /// Its part of the limit, set at the check. nil when it couldn't be opened.
        var share: BatchPlanner.Share?
        var state: State = .waiting

        var isFailed: Bool {
            if case .failed = state { return true }
            return false
        }
    }

    var phase: Phase = .opening(done: 0, of: 0)
    var isShowing = false
    private(set) var items: [Item] = []
    private(set) var destination: Destination?
    /// The files the current run makes, for "Shrinking 2 of 5".
    private(set) var runIDs: [Item.ID] = []
    private var removeLocation = true
    private var task: Task<Void, Never>?
    private var folder: URL?

    // MARK: - Opening

    /// From the app: the pick from Photos, in the order it was picked.
    func open(items picked: [PhotosPickerItem], destination: Destination, removeLocation: Bool) {
        let chosen = Array(picked.prefix(Self.maxItems))
        start(loaders: chosen.map { Self.loader(for: $0) }, kinds: chosen.map { Self.isVideo($0) },
              destination: destination, removeLocation: removeLocation)
    }

    private static func isVideo(_ item: PhotosPickerItem) -> Bool {
        item.supportedContentTypes.contains { $0.conforms(to: .movie) }
    }

    /// Copies one picked file out of Photos when it's called.
    private static func loader(for pickerItem: PhotosPickerItem) -> () async throws -> (url: URL, isVideo: Bool) {
        let video = isVideo(pickerItem)
        return {
            let url: URL?
            if video {
                url = try await pickerItem.loadTransferable(type: PickedMovie.self)?.url
            } else {
                url = try await pickerItem.loadTransferable(type: PickedPhoto.self)?.url
            }
            guard let url else {
                throw ShrinkError.couldNotRead(video ? "Couldn't open that video." : "Couldn't open that photo.")
            }
            return (url, video)
        }
    }

    private func start(loaders: [() async throws -> (url: URL, isVideo: Bool)], kinds: [Bool],
                       destination: Destination, removeLocation: Bool) {
        close()
        Self.removeOldResults()
        folder = nil
        items = []
        runIDs = []
        self.destination = destination
        self.removeLocation = removeLocation
        RecentPlaces.remember(destination)
        isShowing = true
        phase = .opening(done: 0, of: loaders.count)
        task = Task {
            var videos = 0, photos = 0
            for (index, load) in loaders.enumerated() {
                if Task.isCancelled { return }
                let isVideo = kinds[index]
                if isVideo { videos += 1 } else { photos += 1 }
                var item = Item(isVideo: isVideo, name: isVideo ? "Video \(videos)" : "Photo \(photos)")
                do {
                    let file = try await load()
                    item.source = file.url
                    item = try await Self.examined(item, at: file.url)
                    if isVideo, destination.limitBytes == nil {
                        throw ShrinkError.couldNotMake("This one makes photos into JPGs, so videos stay out.")
                    }
                } catch {
                    item.state = .failed(error.localizedDescription)
                    if let source = item.source { try? FileManager.default.removeItem(at: source) }
                    item.source = nil
                }
                if Task.isCancelled {
                    if let source = item.source { try? FileManager.default.removeItem(at: source) }
                    return
                }
                items.append(item)
                phase = .opening(done: index + 1, of: loaders.count)
            }
            replan(limit: destination.limitBytes)
            phase = .checking
        }
    }

    /// What the check needs: length, sound, picture size and a small picture to show.
    private static func examined(_ item: Item, at url: URL) async throws -> Item {
        var item = item
        item.bytes = fileSize(url)
        if item.isVideo {
            let video = try await PickedVideo.examine(url)
            item.seconds = video.duration
            item.hasAudio = video.hasAudio
            item.longSide = video.longSide
            item.frameRate = video.frameRate
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 160)
            let moment = CMTime(seconds: min(0.5, video.duration / 2), preferredTimescale: 600)
            if let frame = try? await generator.image(at: moment) {
                item.thumbnail = UIImage(cgImage: frame.image)
            }
        } else {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int
            else { throw ShrinkError.couldNotRead("This doesn't look like a photo.") }
            item.longSide = max(width, height)
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 160,
            ]
            if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                item.thumbnail = UIImage(cgImage: thumbnail)
            }
        }
        return item
    }

    /// Each waiting file's part of `limit` (the place's, or what a retry has left in the email).
    private func replan(limit: Int64?) {
        guard let destination else { return }
        let indices = items.indices.filter { items[$0].state == .waiting }
        let entries = indices.map { index -> BatchPlanner.Item in
            let item = items[index]
            if item.isVideo {
                return .video(seconds: item.seconds ?? 0, hasAudio: item.hasAudio,
                              longSide: item.longSide, frameRate: item.frameRate)
            }
            return .photo(longSide: item.longSide)
        }
        let shares = BatchPlanner.shares(for: entries, limit: limit, together: destination.limitIsTotal,
                                         choices: SendingOptions.current.sizeChoices)
        for (position, index) in indices.enumerated() {
            items[index].share = shares[position]
        }
    }

    // MARK: - The check

    /// All of them must fit in one email together (Gmail, Outlook), not each on its own.
    var together: Bool { destination?.limitIsTotal ?? false }

    /// The files that will be made when Shrink starts.
    var going: [Item] { items.filter { $0.state == .waiting && $0.share?.fit != .doesNotFit } }
    /// Waiting files that don't fit (too long for the limit, or too much for one email together).
    var tooBig: [Item] { items.filter { $0.state == .waiting && $0.share?.fit == .doesNotFit } }

    var canStart: Bool {
        guard phase == .checking, !going.isEmpty else { return false }
        return together ? tooBig.isEmpty : true
    }

    /// "3 videos and 2 photos".
    static func count(_ items: [Item]) -> String {
        let videos = items.filter(\.isVideo).count
        let photos = items.count - videos
        var parts: [String] = []
        if videos > 0 { parts.append(videos == 1 ? "1 video" : "\(videos) videos") }
        if photos > 0 { parts.append(photos == 1 ? "1 photo" : "\(photos) photos") }
        return parts.isEmpty ? "nothing" : parts.joined(separator: " and ")
    }

    /// Leaves one out (swiped away on the check screen).
    func remove(_ id: Item.ID) {
        guard phase == .checking, let index = position(of: id) else { return }
        removeSource(at: index)
        items.remove(at: index)
        replan(limit: destination?.limitBytes)
    }

    // MARK: - Working

    func startShrinking() {
        guard canStart else { return }
        // Files too long for the limit on their own stay out, saying why.
        let limit = destination?.limitLabel ?? "the limit"
        for index in items.indices where items[index].state == .waiting && items[index].share?.fit == .doesNotFit {
            items[index].state = .failed("Too long for \(limit). Send it on its own to trim it.")
            removeSource(at: index)
        }
        run()
    }

    private func run() {
        runIDs = items.filter { $0.state == .waiting }.map(\.id)
        phase = .working
        UIApplication.shared.isIdleTimerDisabled = true
        let sending = SendingOptions.current
        task = Task {
            await makeWaiting(sending)
            UIApplication.shared.isIdleTimerDisabled = false
            if !Task.isCancelled { phase = .finished }
        }
    }

    /// Makes each waiting file in turn. Items are found by id after every wait, so closing mid-way
    /// can't point at the wrong file.
    private func makeWaiting(_ sending: SendingOptions) async {
        // For one email: what a file leaves unused goes to the videos after it.
        var spare: Int64 = 0
        for id in runIDs {
            guard let index = position(of: id), items[index].state == .waiting, let share = items[index].share else { continue }
            if Task.isCancelled { return }
            var target = share.targetBytes
            if together, items[index].isVideo, spare > 0, let planned = target {
                let seconds = items[index].seconds ?? 0
                let later = items[index...].filter { $0.state == .waiting && $0.isVideo }
                    .reduce(0.0) { $0 + ($1.seconds ?? 0) }
                let extra = later > 0 ? Int64(Double(spare) * seconds / later) : spare
                target = planned + extra
                spare -= extra
            }
            items[index].state = .working(items[index].isVideo ? 0 : nil)
            do {
                let made = try await make(items[index], target: target, sending: sending)
                guard let index = position(of: id) else { return }
                items[index].state = .done(url: made.url, bytes: made.bytes)
                if let target { spare += max(0, target - made.bytes) }
                removeSource(at: index)
            } catch ShrinkError.cancelled {
                if let index = position(of: id) { items[index].state = .waiting }
                return
            } catch is CancellationError {
                if let index = position(of: id) { items[index].state = .waiting }
                return
            } catch {
                guard let index = position(of: id) else { return }
                items[index].state = .failed(error.localizedDescription)
                if let target { spare += target }
            }
        }
    }

    private func make(_ item: Item, target: Int64?, sending: SendingOptions) async throws -> (url: URL, bytes: Int64) {
        guard let source = item.source else { throw ShrinkError.couldNotRead("Its copy went missing.") }
        let removeLocation = removeLocation
        if item.isVideo {
            guard let target else { throw ShrinkError.couldNotMake("This one makes photos into JPGs, so videos stay out.") }
            let options = sending.video(targetBytes: target, removeLocation: removeLocation, timeRange: nil)
            let output = newFile("\(item.name).\(options.fileExtension)")
            let id = item.id
            let result = try await VideoShrinker().shrink(asset: AVURLAsset(url: source), to: output, options: options) { [weak self] value in
                Task { @MainActor in self?.progress(id, value) }
            }
            return (result.url, result.bytes)
        }
        let output = newFile("\(item.name).jpg")
        // PhotoShrinker works synchronously; keep it off the main thread.
        let result = try await Task.detached(priority: .userInitiated) {
            try sending.photo(at: source, to: output, targetBytes: target, removeLocation: removeLocation)
        }.value
        return (result.url, result.bytes)
    }

    private func progress(_ id: Item.ID, _ value: Double) {
        guard let index = position(of: id), case .working = items[index].state else { return }
        items[index].state = .working(value)
    }

    /// The files in this run.
    var runItems: [Item] { items.filter { runIDs.contains($0.id) } }

    /// How many files of this run are finished, one way or the other.
    var finishedInRun: Int {
        runItems.filter { item in
            switch item.state {
            case .done, .failed: return true
            case .waiting, .working: return false
            }
        }.count
    }

    /// 0...1 across the files being made.
    var overallProgress: Double {
        let run = runItems
        guard !run.isEmpty else { return 0 }
        var sum = 0.0
        for item in run {
            switch item.state {
            case .done, .failed: sum += 1
            case .working(let value): sum += value ?? 0.5
            case .waiting: break
            }
        }
        return sum / Double(run.count)
    }

    // MARK: - Finished

    /// The finished files, in order.
    var madeFiles: [(url: URL, bytes: Int64)] {
        items.compactMap { item in
            if case .done(let url, let bytes) = item.state { return (url, bytes) }
            return nil
        }
    }

    var madeBytes: Int64 { madeFiles.reduce(0) { $0 + $1.bytes } }

    /// Files that failed while being made and can be tried again (their copies are still here).
    var retryable: [Item] { items.filter { $0.isFailed && $0.source != nil && $0.share != nil } }

    func retryFailed() {
        guard phase == .finished, let destination else { return }
        let ids = Set(retryable.map(\.id))
        guard !ids.isEmpty else { return }
        for index in items.indices where ids.contains(items[index].id) {
            items[index].state = .waiting
        }
        var limit = destination.limitBytes
        if together, let whole = limit {
            // For one email, only what the finished files left is free.
            limit = max(0, whole - madeBytes)
        }
        replan(limit: limit)
        for index in items.indices where items[index].state == .waiting && items[index].share?.fit == .doesNotFit {
            items[index].state = .failed(together ? "There's no room left in the email for this one."
                                                  : "Too long for \(destination.limitLabel ?? "the limit"). Send it on its own to trim it.")
            removeSource(at: index)
        }
        if items.contains(where: { $0.state == .waiting }) { run() }
    }

    /// Closes the screen, stopping any work and removing the copies taken out of Photos. Finished
    /// files stay until the next batch, so a share in progress never loses its file.
    func close() {
        task?.cancel()
        task = nil
        UIApplication.shared.isIdleTimerDisabled = false
        for index in items.indices { removeSource(at: index) }
        isShowing = false
    }

    // MARK: - Files

    private func position(of id: Item.ID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    private func removeSource(at index: Int) {
        guard items.indices.contains(index), let source = items[index].source else { return }
        if PickedVideo.isOurCopy(source) { try? FileManager.default.removeItem(at: source) }
        items[index].source = nil
    }

    /// A file with a plain name ("Video 1.mp4") in this batch's own folder, so it reads well when sent.
    private func newFile(_ name: String) -> URL {
        let folder = folder ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("Batch-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.folder = folder
        let url = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Folders from earlier batches.
    private static func removeOldResults() {
        let folder = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("Batch-") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    // MARK: - Screenshots

    /// A batch frozen in one state for CI screenshots (`-screenshot batch-…`). batch-done really
    /// shrinks two copies of tmp/batch-sample.mp4 (8 s of 720p at ~3 Mbps, like a phone clip; CI copies
    /// it in) for one Gmail email. (sample-video.mp4 has only ~50 kbps of picture, below what the
    /// encoder goes to, so its copies came out bigger than it: "1.7 MB, was 533 KB".)
    static func preview(_ state: String) -> BatchSend {
        let batch = BatchSend()
        let gmail = Destination.find(id: "gmail")
        let discord = Destination.find(id: "discord")
        let sample = FileManager.default.temporaryDirectory.appendingPathComponent("sample-video.mp4")
        batch.isShowing = true

        if state == "batch-done", let gmail {
            let clip = FileManager.default.temporaryDirectory.appendingPathComponent("batch-sample.mp4")
            // Copies named like the Photos picker's, so they're cleaned up the same way.
            func copyOfSample() async throws -> (url: URL, isVideo: Bool) {
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("picked-\(UUID().uuidString).mp4")
                try FileManager.default.copyItem(at: clip, to: copy)
                return (copy, true)
            }
            batch.start(loaders: [copyOfSample, copyOfSample], kinds: [true, true], destination: gmail, removeLocation: true)
            Task {
                // Let the opening finish, then shrink for real.
                while batch.phase != .checking {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                batch.startShrinking()
            }
            return batch
        }

        func video(_ name: String, _ seconds: Double, _ bytes: Int64, _ state: State = .waiting) -> Item {
            var item = Item(isVideo: true, name: name)
            item.seconds = seconds
            item.hasAudio = true
            item.longSide = 1920
            item.bytes = bytes
            item.state = state
            return item
        }
        func photo(_ name: String, _ bytes: Int64, _ state: State = .waiting) -> Item {
            var item = Item(isVideo: false, name: name)
            item.longSide = 4032
            item.bytes = bytes
            item.state = state
            return item
        }

        switch state {
        case "batch-toomuch":
            batch.destination = gmail
            batch.items = [video("Video 1", 370, 704_000_000), video("Video 2", 425, 809_000_000),
                           video("Video 3", 340, 647_000_000)]
            batch.replan(limit: gmail?.limitBytes)
            batch.phase = .checking
        case "batch-each":
            batch.destination = discord
            batch.items = [video("Video 1", 48, 91_000_000), video("Video 2", 1_250, 2_400_000_000),
                           video("Video 3", 75, 143_000_000), photo("Photo 1", 3_100_000)]
            batch.replan(limit: discord?.limitBytes)
            batch.phase = .checking
        case "batch-working":
            batch.destination = discord
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Video 1.mp4")
            batch.items = [video("Video 1", 48, 91_000_000, .done(url: url, bytes: 17_900_000)),
                           video("Video 2", 75, 143_000_000, .working(0.45)),
                           video("Video 3", 32, 61_000_000), photo("Photo 1", 3_100_000)]
            batch.replan(limit: discord?.limitBytes)
            batch.runIDs = batch.items.map(\.id)
            batch.phase = .working
        default:
            batch.destination = gmail
            batch.items = [video("Video 1", 32, 61_500_000), video("Video 2", 41, 78_000_000),
                           video("Video 3", 22, 42_000_000), photo("Photo 1", 3_100_000)]
            batch.replan(limit: gmail?.limitBytes)
            batch.phase = .checking
        }
        // Small pictures from the sample video, so the rows look like the real thing.
        batch.task = Task {
            for index in batch.items.indices {
                if let frame = try? await QuickExtras.frame(of: AVURLAsset(url: sample), at: Double(4 + index * 9)) {
                    batch.items[index].thumbnail = UIImage(cgImage: frame)
                }
            }
        }
        return batch
    }
}
