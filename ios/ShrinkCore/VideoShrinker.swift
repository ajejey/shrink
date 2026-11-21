import AVFoundation
import CoreMedia

public struct VideoShrinkOptions {
    /// The destination's limit. The finished file is never larger than this.
    public var targetBytes: Int64
    /// Leave the place it was filmed out of the file. On by default.
    public var removeLocation: Bool
    /// The part of the video to keep (trim). nil keeps all of it. The finished file starts at 0:00.
    public var timeRange: CMTimeRange?
    /// Shrink Pro's sending options: the whole limit, picture size, 60 fps, HEVC.
    public var choices: SizeChoices
    /// Keep every detail in the file (camera, lens, software...), not just the date. The place still
    /// follows `removeLocation`.
    public var keepsAllDetails: Bool

    public init(targetBytes: Int64, removeLocation: Bool = true, timeRange: CMTimeRange? = nil,
                choices: SizeChoices = .standard, keepsAllDetails: Bool = false) {
        self.targetBytes = targetBytes
        self.removeLocation = removeLocation
        self.timeRange = timeRange
        self.choices = choices
        self.keepsAllDetails = keepsAllDetails
    }

    /// H.264 plays everywhere (Windows, Android, Discord, browsers). HEVC is sharper at the same size
    /// but plays in fewer places, so it's a Pro choice.
    public var codec: AVVideoCodecType { choices.hevc ? .hevc : .h264 }

    /// MP4 plays everywhere but keeps only the date and place (and a title or copyright); the camera,
    /// lens and the rest need QuickTime (CI run 44911678768 probed it). So keeping every detail makes
    /// a .mov.
    public var fileType: AVFileType { keepsAllDetails ? .mov : .mp4 }
    public var fileExtension: String { keepsAllDetails ? "mov" : "mp4" }
}

public struct VideoShrinkResult {
    public let url: URL
    public let bytes: Int64
    /// Size of the source file, when it was a file.
    public let originalBytes: Int64?
    public let plan: SizePlan
    public let outputSize: CGSize
    /// 1 normally; up to 4 when the encoder overshot and we re-encoded lower (and smaller, if needed),
    /// or when "Use the whole limit" redid a pass that came out well under the limit.
    public let passes: Int
}

/// Re-encodes a video to MP4 so it fits under a size limit and plays everywhere:
/// rotation baked in, HDR turned into standard color, sound kept and in sync, location removed.
public final class VideoShrinker {
    public init() {}

    public func shrink(
        asset: AVAsset,
        to outputURL: URL,
        options: VideoShrinkOptions,
        progress: @escaping (Double) -> Void = { _ in }
    ) async throws -> VideoShrinkResult {
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else { throw ShrinkError.noVideo }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let fullDuration = try await asset.load(.duration)
        guard fullDuration.seconds.isFinite, fullDuration.seconds > 0 else { throw ShrinkError.couldNotRead("It has no length.") }
        let range = Self.kept(options.timeRange, of: fullDuration)
        guard range.duration.seconds >= Self.shortestTrimSeconds else { throw ShrinkError.trimTooShort }
        let duration = range.duration.seconds

        let (naturalSize, transform, nominalFrameRate, dataRate) =
            try await videoTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate)
        let upright = naturalSize.applying(transform)
        let width = abs(upright.width), height = abs(upright.height)
        let longSide = Int(max(width, height).rounded())

        let sourceCap = dataRate > 0 ? Int(Double(dataRate) * 1.5) : nil
        guard var plan = SizePlanner.plan(
            targetBytes: options.targetBytes,
            durationSeconds: duration,
            hasAudio: audioTrack != nil,
            sourceLongSide: longSide,
            sourceFrameRate: Double(nominalFrameRate),
            sourceVideoBitsPerSecond: sourceCap,
            choices: options.choices
        ) else { throw ShrinkError.tooLongToFit }

        let originalBytes = (asset as? AVURLAsset).map { Self.fileSize($0.url) }
        var details: Details = options.keepsAllDetails ? .all : .dateAndPlace
        var passes = 0
        var stalls = 0
        // "Use the whole limit": a pass that fit, kept aside while a fuller one is tried.
        var kept: (bytes: Int64, plan: SizePlan, outputSize: CGSize)?
        let keptURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("fit-\(UUID().uuidString.prefix(6))-\(outputURL.lastPathComponent)")
        defer { try? FileManager.default.removeItem(at: keptURL) }

        while true {
            passes += 1
            let outputSize = Self.outputSize(width: width, height: height, maxLongSide: plan.maxLongSide)
            if Task.isCancelled { throw ShrinkError.cancelled }
            try? FileManager.default.removeItem(at: outputURL)
            do {
                try await encode(
                    asset: asset, videoTracks: videoTracks, audioTrack: audioTrack, plan: plan,
                    outputSize: outputSize, range: range, options: options,
                    details: details, outputURL: outputURL, progress: progress
                )
            } catch ShrinkError.couldNotWrite(_) where details != .nothing {
                // Some metadata can't go into MP4. The video matters more than its details, so try with fewer.
                details = details == .all ? .dateAndPlace : .nothing
                passes -= 1
                continue
            } catch ShrinkError.stalled where stalls == 0 {
                // AVFoundation stalled (seen once in CI on a 4-second black video). One fresh try.
                stalls += 1
                passes -= 1
                continue
            }

            let bytes = Self.fileSize(outputURL)
            if bytes > 0, bytes <= options.targetBytes {
                if let earlier = kept, earlier.bytes >= bytes {
                    // The fuller try came out no bigger: the earlier file is the one.
                    try Self.move(keptURL, to: outputURL)
                    return VideoShrinkResult(url: outputURL, bytes: earlier.bytes, originalBytes: originalBytes,
                                             plan: earlier.plan, outputSize: earlier.outputSize, passes: passes)
                }
                let fullEnough = Double(bytes) >= Double(options.targetBytes) * SizePlanner.exactFloor
                let grew = kept.map { Double(bytes) > Double($0.bytes) * 1.03 } ?? true
                if options.choices.exactSize, !fullEnough, grew, passes < Self.maxPasses,
                   let next = SizePlanner.filled(plan, deliveredBytes: bytes, targetBytes: options.targetBytes,
                                                 durationSeconds: duration, choices: options.choices,
                                                 maxVideoBitsPerSecond: sourceCap) {
                    // Well under the limit: keep this file aside and try a fuller one.
                    try Self.move(outputURL, to: keptURL)
                    kept = (bytes, plan, outputSize)
                    plan = next
                    continue
                }
                return VideoShrinkResult(url: outputURL, bytes: bytes, originalBytes: originalBytes,
                                         plan: plan, outputSize: outputSize, passes: passes)
            }
            if let earlier = kept {
                // The fuller try went over the limit; the earlier one fit.
                try Self.move(keptURL, to: outputURL)
                return VideoShrinkResult(url: outputURL, bytes: earlier.bytes, originalBytes: originalBytes,
                                         plan: earlier.plan, outputSize: earlier.outputSize, passes: passes)
            }
            guard passes < Self.maxPasses, let next = SizePlanner.corrected(
                plan, deliveredBytes: bytes, targetBytes: options.targetBytes, durationSeconds: duration,
                choices: options.choices
            ) else {
                // Never hand back a file that's over the limit.
                try? FileManager.default.removeItem(at: outputURL)
                throw ShrinkError.stillTooBig(bytes: bytes)
            }
            plan = next
        }
    }

    /// Encodes per video, at most: the first, then corrections (or fuller tries for the whole limit).
    static let maxPasses = 4

    /// Watchdog ticks (5 s each) with no sample moving before an encode counts as stalled.
    static let stallTicks = 9

    /// Which of the source's metadata goes into the file. Lowered when MP4 refuses some of it.
    enum Details: Equatable {
        /// Everything (camera, lens, software, date...); the place only when it's kept.
        case all
        /// The date it was filmed, and the place only when it's kept.
        case dateAndPlace
        case nothing
    }

    /// Replaces `destination` with the file at `source`.
    static func move(_ source: URL, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        do { try FileManager.default.moveItem(at: source, to: destination) } catch {
            throw ShrinkError.couldNotWrite(error.localizedDescription)
        }
    }

    // MARK: - One encode

    private func encode(
        asset: AVAsset,
        videoTracks: [AVAssetTrack],
        audioTrack: AVAssetTrack?,
        plan: SizePlan,
        outputSize: CGSize,
        range: CMTimeRange,
        options: VideoShrinkOptions,
        details: Details,
        outputURL: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch {
            throw ShrinkError.couldNotRead(error.localizedDescription)
        }
        // Read only the kept part. Its samples are moved back by range.start so the file starts at 0:00
        // (plain timestamps instead of an edit list, which some players and sites ignore).
        reader.timeRange = range
        let offset = range.start

        // Upright frames (rotation baked in), HDR tone-mapped to standard color, frame rate capped.
        let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        let capped = CMTime(value: 1, timescale: CMTimeScale(plan.maxFrameRate.rounded()))
        if !composition.frameDuration.isValid || composition.frameDuration.seconds < capped.seconds {
            composition.frameDuration = capped
            // A composition made from an asset follows the source's frame timing and ignores
            // frameDuration (CI run 43848639741 kept 60 fps). Drop that link so the cap applies.
            composition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        }
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw ShrinkError.couldNotRead("Its picture can't be decoded.") }
        reader.add(videoOutput)

        let stereo = Self.stereoLayout()
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack, plan.audioBitsPerSecond > 0 {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVChannelLayoutKey: stereo,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw ShrinkError.couldNotRead("Its sound can't be decoded.") }
            reader.add(output)
            audioOutput = output
        }

        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: outputURL, fileType: options.fileType) } catch {
            throw ShrinkError.couldNotWrite(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = true
        if details != .nothing {
            let kept = await Self.keptMetadata(of: asset, removeLocation: options.removeLocation,
                                               keepsAll: details == .all)
            writer.metadata = options.fileType == .mp4 ? Self.forMP4(kept) : kept
        }

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: plan.videoBitsPerSecond,
            AVVideoExpectedSourceFrameRateKey: Int(plan.maxFrameRate.rounded()),
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
        ]
        if options.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: options.codec,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: compression,
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw ShrinkError.couldNotWrite("The video encoder refused these settings.") }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVChannelLayoutKey: stereo,
                AVEncoderBitRateKey: plan.audioBitsPerSecond,
            ])
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw ShrinkError.couldNotWrite("The sound encoder refused these settings.") }
            writer.add(input)
            audioInput = input
        }

        guard reader.startReading() else {
            throw ShrinkError.couldNotRead(reader.error?.localizedDescription ?? "")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw ShrinkError.couldNotWrite(writer.error?.localizedDescription ?? "")
        }
        writer.startSession(atSourceTime: .zero)

        let reporter = ProgressReporter(duration: range.duration.seconds, report: progress)
        // Whichever comes first ends the wait: every sample drained, or the watchdog giving up (a stuck
        // writer may never call the drains again, so cancelling the reading alone could still hang).
        let finish = ResumeOnce()
        let watchdog = StallWatchdog(idleTicksAllowed: Self.stallTicks) {
            reader.cancelReading()
            finish.fire()
        }
        watchdog.start()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                finish.set { done.resume() }
                let group = DispatchGroup()
                Self.drain(videoOutput, into: videoInput, reader: reader, offset: offset, group: group, label: "shrink.video") {
                    reporter.update($0)
                    watchdog.touch()
                }
                if let audioOutput, let audioInput {
                    Self.drain(audioOutput, into: audioInput, reader: reader, offset: offset, group: group,
                               label: "shrink.audio") { _ in watchdog.touch() }
                }
                group.notify(queue: .global()) { finish.fire() }
            }
        } onCancel: {
            reader.cancelReading()
        }
        watchdog.stop()

        if Task.isCancelled {
            writer.cancelWriting()
            throw ShrinkError.cancelled
        }
        if watchdog.fired {
            // Its reading was cut short: never finish that into a file that looks whole.
            writer.cancelWriting()
            throw ShrinkError.stalled
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw ShrinkError.couldNotRead(reader.error?.localizedDescription ?? "")
        }
        if writer.status == .failed {
            throw ShrinkError.couldNotWrite(writer.error?.localizedDescription ?? "")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ShrinkError.couldNotWrite(writer.error?.localizedDescription ?? "")
        }
        progress(1)
    }

    /// Moves samples from a reader output to a writer input until the output runs dry, moving each
    /// one back by `offset` (the start of a trim).
    static func drain(
        _ output: AVAssetReaderOutput,
        into input: AVAssetWriterInput,
        reader: AVAssetReader,
        offset: CMTime,
        group: DispatchGroup,
        label: String,
        onSample: ((CMTime) -> Void)?
    ) {
        group.enter()
        let finished = Flag()
        func finish() {
            finished.value = true
            input.markAsFinished()
            group.leave()
        }
        input.requestMediaDataWhenReady(on: DispatchQueue(label: label)) {
            guard !finished.value else { return }
            while input.isReadyForMoreMediaData {
                guard reader.status == .reading, let read = output.copyNextSampleBuffer() else {
                    finish()
                    return
                }
                guard let sample = shifted(read, back: offset) else {
                    reader.cancelReading()
                    finish()
                    return
                }
                if !input.append(sample) {
                    reader.cancelReading()
                    finish()
                    return
                }
                onSample?(CMSampleBufferGetPresentationTimeStamp(sample))
            }
        }
    }

    // MARK: - Helpers

    /// A trim shorter than this is almost certainly a slip of the finger.
    public static let shortestTrimSeconds = 0.5

    /// The part of the video to keep: the requested trim, kept inside the video, or all of it.
    static func kept(_ requested: CMTimeRange?, of duration: CMTime) -> CMTimeRange {
        let whole = CMTimeRange(start: .zero, duration: duration)
        guard let requested, requested.isValid, !requested.isIndefinite, !requested.isEmpty else { return whole }
        return requested.intersection(whole)
    }

    /// The same sample, `offset` earlier. nil only if Core Media can't copy it.
    static func shifted(_ sample: CMSampleBuffer, back offset: CMTime) -> CMSampleBuffer? {
        guard offset.isValid, offset != .zero else { return sample }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return sample }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(
            sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count
        ) == noErr else { return nil }
        for index in timing.indices {
            if timing[index].presentationTimeStamp.isValid {
                timing[index].presentationTimeStamp = timing[index].presentationTimeStamp - offset
            }
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = timing[index].decodeTimeStamp - offset
            }
        }
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &copy
        ) == noErr else { return nil }
        return copy
    }

    /// Even dimensions with the source's shape, no larger than maxLongSide on the long edge.
    static func outputSize(width: CGFloat, height: CGFloat, maxLongSide: Int) -> CGSize {
        let scale = min(1, CGFloat(maxLongSide) / max(width, height))
        func even(_ value: CGFloat) -> CGFloat { max(2, (value * scale / 2).rounded() * 2) }
        return CGSize(width: even(width), height: even(height))
    }

    /// The date it was filmed (or every detail, with `keepsAll`), and its location only when the
    /// person chose to keep it.
    static func keptMetadata(of asset: AVAsset, removeLocation: Bool, keepsAll: Bool) async -> [AVMetadataItem] {
        let items = (try? await asset.load(.metadata)) ?? []
        return items.filter { item in
            if isLocation(item) { return !removeLocation }
            if keepsAll { return true }
            return item.identifier?.rawValue.lowercased().contains("creationdate") == true
        }
    }

    /// MP4 has no room for iPhone-style metadata (com.apple.quicktime.…): CI run 44900163317 found sent
    /// videos with no date or place at all, whatever the settings said. Each kept item is rewritten in
    /// the common key space, which the writer turns into MP4's own (ISO user data: date, loci). MP4
    /// drops the camera's make and model however they're written, so those need a .mov.
    static func forMP4(_ items: [AVMetadataItem]) -> [AVMetadataItem] {
        var seen = Set<String>()
        return items.compactMap { item -> AVMetadataItem? in
            guard let commonKey = item.commonKey, let value = item.value,
                  !seen.contains(commonKey.rawValue),
                  let identifier = AVMetadataItem.identifier(forKey: commonKey.rawValue, keySpace: .common)
            else { return nil }
            seen.insert(commonKey.rawValue)
            let copy = AVMutableMetadataItem()
            copy.identifier = identifier
            copy.value = value
            if let dataType = item.dataType { copy.dataType = dataType }
            return copy
        }
    }

    /// A place in any of the forms a video can carry it: QuickTime's location keys, the user data
    /// xyz atom, 3GPP's loci, or anything tagged as the common location.
    static func isLocation(_ item: AVMetadataItem) -> Bool {
        if item.commonKey == .commonKeyLocation { return true }
        let id = item.identifier?.rawValue.lowercased() ?? ""
        return id.contains("location") || id.contains("xyz") || id.contains("loci") || id.contains("gps")
    }

    static func stereoLayout() -> Data {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        return withUnsafeBytes(of: &layout) { Data($0) }
    }

    static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

/// Mutable flag touched only on one serial queue.
final class Flag {
    var value = false
}

/// Runs its action once, whether `fire` comes before or after the action is set.
final class ResumeOnce {
    private let lock = NSLock()
    private var action: (() -> Void)?
    private var firedEarly = false
    private var done = false

    func set(_ action: @escaping () -> Void) {
        lock.lock()
        if firedEarly && !done {
            done = true
            lock.unlock()
            action()
            return
        }
        self.action = action
        lock.unlock()
    }

    func fire() {
        lock.lock()
        guard !done else {
            lock.unlock()
            return
        }
        guard let action else {
            firedEarly = true
            lock.unlock()
            return
        }
        done = true
        self.action = nil
        lock.unlock()
        action()
    }
}

/// Stops an encode that has stopped moving: AVFoundation stalled once in CI (a 4-second black video
/// sat for 7 minutes), and on an iPhone that would be a shrink stuck at one percentage for good. It
/// counts its own ticks rather than clock time, so time the app spends suspended doesn't count.
final class StallWatchdog {
    private let idleTicksAllowed: Int
    private let onStall: () -> Void
    private let lock = NSLock()
    private var moved = false
    private var idleTicks = 0
    private var didFire = false
    private var timer: DispatchSourceTimer?

    init(idleTicksAllowed: Int, onStall: @escaping () -> Void) {
        self.idleTicksAllowed = idleTicksAllowed
        self.onStall = onStall
    }

    var fired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didFire
    }

    func start(every seconds: Double = 5) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "shrink.watchdog"))
        timer.schedule(deadline: .now() + seconds, repeating: seconds)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// A sample moved.
    func touch() {
        lock.lock()
        moved = true
        lock.unlock()
    }

    private func tick() {
        lock.lock()
        if moved {
            moved = false
            idleTicks = 0
        } else {
            idleTicks += 1
        }
        let stalled = idleTicks >= idleTicksAllowed && !didFire
        if stalled { didFire = true }
        lock.unlock()
        if stalled { onStall() }
    }
}

/// Turns sample times into 0...1 progress, reporting at most once per percent.
final class ProgressReporter {
    private let duration: Double
    private let report: (Double) -> Void
    private var last = -1.0
    private let lock = NSLock()

    init(duration: Double, report: @escaping (Double) -> Void) {
        self.duration = duration
        self.report = report
    }

    func update(_ time: CMTime) {
        guard time.isNumeric, duration > 0 else { return }
        let value = min(1, max(0, time.seconds / duration))
        lock.lock()
        let due = value - last >= 0.01
        if due { last = value }
        lock.unlock()
        if due { report(value) }
    }
}
