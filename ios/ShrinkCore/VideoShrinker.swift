import AVFoundation
import CoreMedia

public struct VideoShrinkOptions {
    /// The destination's limit. The finished file is never larger than this.
    public var targetBytes: Int64
    /// Leave the place it was filmed out of the file. On by default.
    public var removeLocation: Bool
    /// H.264 plays everywhere (Windows, Android, Discord, browsers). HEVC is smaller but less compatible.
    public var codec: AVVideoCodecType

    public init(targetBytes: Int64, removeLocation: Bool = true, codec: AVVideoCodecType = .h264) {
        self.targetBytes = targetBytes
        self.removeLocation = removeLocation
        self.codec = codec
    }
}

public struct VideoShrinkResult {
    public let url: URL
    public let bytes: Int64
    /// Size of the source file, when it was a file.
    public let originalBytes: Int64?
    public let plan: SizePlan
    public let outputSize: CGSize
    /// 1 normally; up to 4 when the encoder overshot and we re-encoded lower (and smaller, if needed).
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
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw ShrinkError.couldNotRead("It has no length.") }

        let (naturalSize, transform, nominalFrameRate, dataRate) =
            try await videoTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate)
        let upright = naturalSize.applying(transform)
        let width = abs(upright.width), height = abs(upright.height)
        let longSide = Int(max(width, height).rounded())

        guard var plan = SizePlanner.plan(
            targetBytes: options.targetBytes,
            durationSeconds: duration,
            hasAudio: audioTrack != nil,
            sourceLongSide: longSide,
            sourceFrameRate: Double(nominalFrameRate),
            sourceVideoBitsPerSecond: dataRate > 0 ? Int(Double(dataRate) * 1.5) : nil
        ) else { throw ShrinkError.tooLongToFit }

        let originalBytes = (asset as? AVURLAsset).map { Self.fileSize($0.url) }
        var includeMetadata = true
        var passes = 0

        while true {
            passes += 1
            let outputSize = Self.outputSize(width: width, height: height, maxLongSide: plan.maxLongSide)
            if Task.isCancelled { throw ShrinkError.cancelled }
            try? FileManager.default.removeItem(at: outputURL)
            do {
                try await encode(
                    asset: asset, videoTracks: videoTracks, audioTrack: audioTrack, plan: plan,
                    outputSize: outputSize, duration: duration, options: options,
                    includeMetadata: includeMetadata, outputURL: outputURL, progress: progress
                )
            } catch ShrinkError.couldNotWrite(_) where includeMetadata {
                // Some metadata can't go into MP4. The video matters more than its date, so try without.
                includeMetadata = false
                passes -= 1
                continue
            }

            let bytes = Self.fileSize(outputURL)
            if bytes > 0, bytes <= options.targetBytes {
                return VideoShrinkResult(
                    url: outputURL, bytes: bytes, originalBytes: originalBytes,
                    plan: plan, outputSize: outputSize, passes: passes
                )
            }
            guard passes < 4, let next = SizePlanner.corrected(
                plan, deliveredBytes: bytes, targetBytes: options.targetBytes, durationSeconds: duration
            ) else {
                // Never hand back a file that's over the limit.
                try? FileManager.default.removeItem(at: outputURL)
                throw ShrinkError.stillTooBig(bytes: bytes)
            }
            plan = next
        }
    }

    // MARK: - One encode

    private func encode(
        asset: AVAsset,
        videoTracks: [AVAssetTrack],
        audioTrack: AVAssetTrack?,
        plan: SizePlan,
        outputSize: CGSize,
        duration: Double,
        options: VideoShrinkOptions,
        includeMetadata: Bool,
        outputURL: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch {
            throw ShrinkError.couldNotRead(error.localizedDescription)
        }

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
        do { writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4) } catch {
            throw ShrinkError.couldNotWrite(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = true
        if includeMetadata {
            writer.metadata = await Self.keptMetadata(of: asset, removeLocation: options.removeLocation)
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

        let reporter = ProgressReporter(duration: duration, report: progress)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let group = DispatchGroup()
                Self.drain(videoOutput, into: videoInput, reader: reader, group: group, label: "shrink.video") {
                    reporter.update($0)
                }
                if let audioOutput, let audioInput {
                    Self.drain(audioOutput, into: audioInput, reader: reader, group: group, label: "shrink.audio", onSample: nil)
                }
                group.notify(queue: .global()) { done.resume() }
            }
        } onCancel: {
            reader.cancelReading()
        }

        if Task.isCancelled {
            writer.cancelWriting()
            throw ShrinkError.cancelled
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

    /// Moves samples from a reader output to a writer input until the output runs dry.
    private static func drain(
        _ output: AVAssetReaderOutput,
        into input: AVAssetWriterInput,
        reader: AVAssetReader,
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
                guard reader.status == .reading, let sample = output.copyNextSampleBuffer() else {
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

    /// Even dimensions with the source's shape, no larger than maxLongSide on the long edge.
    static func outputSize(width: CGFloat, height: CGFloat, maxLongSide: Int) -> CGSize {
        let scale = min(1, CGFloat(maxLongSide) / max(width, height))
        func even(_ value: CGFloat) -> CGFloat { max(2, (value * scale / 2).rounded() * 2) }
        return CGSize(width: even(width), height: even(height))
    }

    /// The date it was filmed, and its location only when the person chose to keep it.
    static func keptMetadata(of asset: AVAsset, removeLocation: Bool) async -> [AVMetadataItem] {
        let items = (try? await asset.load(.metadata)) ?? []
        return items.filter { item in
            let id = item.identifier?.rawValue.lowercased() ?? ""
            if id.contains("location") { return !removeLocation }
            return id.contains("creationdate")
        }
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
private final class Flag {
    var value = false
}

/// Turns sample times into 0...1 progress, reporting at most once per percent.
private final class ProgressReporter {
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
