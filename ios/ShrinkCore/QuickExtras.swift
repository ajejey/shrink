import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// The small jobs on Home: the sound from a video, the same video without sound, one frame as a
/// photo, and a GIF. Each writes one file and returns its size in bytes.
public enum QuickExtras {

    // MARK: - Sound

    /// The video's sound as an M4A (AAC) file, without the place it was filmed.
    /// Throws `.noSound` when the video has none.
    public static func extractSound(from asset: AVAsset, to url: URL) async throws -> Int64 {
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard !audio.isEmpty else { throw ShrinkError.noSound }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ShrinkError.couldNotMake("This video's sound can't be saved on its own.")
        }
        session.metadataItemFilter = AVMetadataItemFilter.forSharing()
        try await export(session, to: url, as: .m4a)
        return fileSize(url)
    }

    // MARK: - Mute

    /// The same video with its sound left out. The picture is copied, not re-encoded, so it looks
    /// exactly the same (HDR and HEVC stay). The date it was filmed is kept; the place only when
    /// `keepLocation` is on.
    public static func mute(_ asset: AVAsset, to url: URL, keepLocation: Bool) async throws -> Int64 {
        guard let source = try await asset.loadTracks(withMediaType: .video).first else { throw ShrinkError.noVideo }
        let (range, transform) = try await source.load(.timeRange, .preferredTransform)
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ShrinkError.couldNotMake("The picture couldn't be copied.")
        }
        try track.insertTimeRange(range, of: source, at: .zero)
        track.preferredTransform = transform
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ShrinkError.couldNotMake("The picture couldn't be copied.")
        }
        session.metadata = await keptMetadata(of: asset, keepLocation: keepLocation)
        try await export(session, to: url, as: .mov)
        return fileSize(url)
    }

    // MARK: - Frame

    /// The exact frame at `seconds`, upright and full size.
    public static func frame(of asset: AVAsset, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        do {
            return try await generator.image(at: CMTime(seconds: max(0, seconds), preferredTimescale: 600)).image
        } catch {
            throw ShrinkError.couldNotMake("That frame couldn't be read.")
        }
    }

    /// A frame (or any picture) as a JPEG file.
    public static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.92) throws -> Int64 {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ShrinkError.couldNotMake("The photo couldn't be written.")
        }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ShrinkError.couldNotMake("The photo couldn't be written.") }
        return fileSize(url)
    }

    // MARK: - GIF

    public struct GIFOptions: Sendable, Equatable {
        /// The part of the video, in seconds.
        public var start: Double
        public var end: Double
        /// Longest side of the GIF, in pixels.
        public var longSide: Int
        public var framesPerSecond: Double

        public init(start: Double, end: Double, longSide: Int, framesPerSecond: Double = 12) {
            self.start = start
            self.end = end
            self.longSide = longSide
            self.framesPerSecond = framesPerSecond
        }

        public var frameCount: Int { max(2, Int(((end - start) * framesPerSecond).rounded())) }
    }

    /// GIFs are for short moments; a longer one gets huge and many apps won't play it.
    public static let longestGIFSeconds = 15.0
    public static let shortestGIFSeconds = 0.5

    /// A looping GIF of part of the video, upright, at most `longSide` pixels on its longest side.
    public static func makeGIF(
        from asset: AVAsset, options: GIFOptions, to url: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Int64 {
        let length = options.end - options.start
        guard length >= shortestGIFSeconds - 0.01 else { throw ShrinkError.trimTooShort }
        guard length <= longestGIFSeconds + 0.01 else {
            throw ShrinkError.couldNotMake("A GIF can be up to \(Int(longestGIFSeconds)) seconds. Pick a shorter part.")
        }
        let count = options.frameCount
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: options.longSide, height: options.longSide)
        let half = CMTime(seconds: 0.5 / options.framesPerSecond, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = half
        generator.requestedTimeToleranceAfter = half

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw ShrinkError.couldNotMake("The GIF couldn't be written.")
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let delay = 1 / options.framesPerSecond
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ],
        ] as CFDictionary

        for index in 0..<count {
            try Task.checkCancellation()
            let seconds = options.start + Double(index) / options.framesPerSecond
            let image: CGImage
            do {
                image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            } catch {
                throw ShrinkError.couldNotMake("Part of the video couldn't be read.")
            }
            CGImageDestinationAddImage(destination, image, frameProperties)
            progress(Double(index + 1) / Double(count))
        }
        guard CGImageDestinationFinalize(destination) else { throw ShrinkError.couldNotMake("The GIF couldn't be written.") }
        return fileSize(url)
    }

    // MARK: - What the video says about itself

    /// When and where the video was filmed, from its own metadata (nil when it doesn't say).
    public struct Facts: Sendable, Equatable {
        public var created: Date?
        public var latitude: Double?
        public var longitude: Double?

        public init(created: Date? = nil, latitude: Double? = nil, longitude: Double? = nil) {
            self.created = created
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    public static func facts(of asset: AVAsset) async -> Facts {
        var facts = Facts()
        let items = (try? await asset.load(.metadata)) ?? []
        for item in items {
            let id = item.identifier?.rawValue.lowercased() ?? ""
            if facts.created == nil, id.contains("creationdate") {
                if let date = try? await item.load(.dateValue) {
                    facts.created = date
                } else if let text = try? await item.load(.stringValue) {
                    facts.created = parseDate(text)
                }
            }
            if facts.latitude == nil, id.contains("location"), let text = try? await item.load(.stringValue),
               let place = parseISO6709(text) {
                facts.latitude = place.0
                facts.longitude = place.1
            }
        }
        if facts.created == nil, let date = try? await asset.load(.creationDate),
           let value = try? await date.load(.dateValue) {
            facts.created = value
        }
        return facts
    }

    /// "+37.3349-122.0090+010.000/" → (37.3349, -122.009).
    static func parseISO6709(_ text: String) -> (Double, Double)? {
        let pattern = #"^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let latRange = Range(match.range(at: 1), in: text), let lonRange = Range(match.range(at: 2), in: text),
              let latitude = Double(text[latRange]), let longitude = Double(text[lonRange]),
              abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
        return (latitude, longitude)
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        // QuickTime writes "2026-11-16T10:00:00+0000" (no colon in the offset).
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return fallback.date(from: text)
    }

    // MARK: - Helpers

    /// The date it was filmed, and its place only when kept.
    static func keptMetadata(of asset: AVAsset, keepLocation: Bool) async -> [AVMetadataItem] {
        let items = (try? await asset.load(.metadata)) ?? []
        return items.filter { item in
            let id = item.identifier?.rawValue.lowercased() ?? ""
            if id.contains("location") { return keepLocation }
            return id.contains("creationdate")
        }
    }

    private static func export(_ session: AVAssetExportSession, to url: URL, as type: AVFileType) async throws {
        try? FileManager.default.removeItem(at: url)
        if #available(iOS 18, *) {
            do {
                try await session.export(to: url, as: type)
            } catch is CancellationError {
                throw ShrinkError.cancelled
            } catch {
                throw ShrinkError.couldNotMake(error.localizedDescription)
            }
        } else {
            session.outputURL = url
            session.outputFileType = type
            await withTaskCancellationHandler {
                await session.export()
            } onCancel: {
                session.cancelExport()
            }
            switch session.status {
            case .completed: return
            case .cancelled: throw ShrinkError.cancelled
            default: throw ShrinkError.couldNotMake(session.error?.localizedDescription ?? "It stopped partway.")
            }
        }
    }

    static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
