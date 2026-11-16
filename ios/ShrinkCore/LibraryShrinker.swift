import AVFoundation
import CoreMedia
import VideoToolbox

public struct LibraryShrinkOptions {
    public var size: LibraryPlanner.Size
    /// HEVC when the iPhone has it (every iPhone since the 7). It's smaller, and it can keep HDR.
    public var hevc: Bool
    /// The video's size now. A copy that isn't clearly smaller is thrown away (`ShrinkError.notSmaller`).
    public var originalBytes: Int64?

    public init(size: LibraryPlanner.Size = .hd, hevc: Bool, originalBytes: Int64? = nil) {
        self.size = size
        self.hevc = hevc
        self.originalBytes = originalBytes
    }
}

public struct LibraryShrinkResult {
    public let url: URL
    public let bytes: Int64
    public let outputSize: CGSize
    /// The copy kept HDR (HEVC 10-bit with the source's HDR transfer).
    public let keptHDR: Bool
    public let usedHEVC: Bool
}

/// Free up space: makes a smaller copy of a video for the person's own library. Unlike sending, it keeps
/// everything that makes it theirs: HDR (when HEVC is available), the frame rate, the sound as recorded
/// (copied, not re-encoded), and all the metadata including the date and place it was filmed.
public final class LibraryShrinker {
    public init() {}

    /// A copy at least this much smaller is worth replacing the original with.
    static let requiredShare = 0.9

    public func shrink(
        asset: AVAsset,
        to outputURL: URL,
        options: LibraryShrinkOptions,
        progress: @escaping (Double) -> Void = { _ in }
    ) async throws -> LibraryShrinkResult {
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else { throw ShrinkError.noVideo }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0 else { throw ShrinkError.couldNotRead("It has no length.") }

        let (naturalSize, transform, frameRate, characteristics, formats) = try await videoTrack.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .mediaCharacteristics, .formatDescriptions
        )
        let upright = naturalSize.applying(transform)
        let dimensions = LibraryPlanner.outputDimensions(
            width: Int(abs(upright.width).rounded()), height: Int(abs(upright.height).rounded()), size: options.size
        )
        let outputSize = CGSize(width: dimensions.width, height: dimensions.height)
        let fps = Double(frameRate > 0 ? frameRate : 30)
        let hdr = options.hevc && characteristics.contains(.containsHDRVideo)
        let color = Self.colorProperties(hdr: hdr, transfer: Self.transferFunction(of: formats.first))
        let bitrate = LibraryPlanner.videoBitsPerSecond(width: dimensions.width, height: dimensions.height,
                                                        frameRate: fps, hevc: options.hevc)

        var includeMetadata = true
        while true {
            try? FileManager.default.removeItem(at: outputURL)
            if Task.isCancelled { throw ShrinkError.cancelled }
            do {
                try await encode(
                    asset: asset, videoTracks: videoTracks, audioTrack: audioTrack, duration: duration,
                    outputSize: outputSize, fps: fps, bitrate: bitrate, hdr: hdr, color: color,
                    hevc: options.hevc, includeMetadata: includeMetadata, outputURL: outputURL, progress: progress
                )
                break
            } catch ShrinkError.couldNotWrite(_) where includeMetadata {
                // Some metadata can't be written back. The video matters more, and Photos keeps its
                // date and place separately.
                includeMetadata = false
            }
        }

        let bytes = VideoShrinker.fileSize(outputURL)
        if let original = options.originalBytes, original > 0, Double(bytes) >= Double(original) * Self.requiredShare {
            try? FileManager.default.removeItem(at: outputURL)
            throw ShrinkError.notSmaller
        }
        return LibraryShrinkResult(url: outputURL, bytes: bytes, outputSize: outputSize, keptHDR: hdr,
                                   usedHEVC: options.hevc)
    }

    // MARK: - One encode

    private func encode(
        asset: AVAsset,
        videoTracks: [AVAssetTrack],
        audioTrack: AVAssetTrack?,
        duration: CMTime,
        outputSize: CGSize,
        fps: Double,
        bitrate: Int,
        hdr: Bool,
        color: [String: String],
        hevc: Bool,
        includeMetadata: Bool,
        outputURL: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch {
            throw ShrinkError.couldNotRead(error.localizedDescription)
        }

        // Upright frames (rotation baked in) in the source's own color: HDR stays HDR.
        let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        let capped = CMTime(value: 1, timescale: 60)
        if !composition.frameDuration.isValid || composition.frameDuration.seconds < capped.seconds {
            composition.frameDuration = capped
            composition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        }
        composition.colorPrimaries = color[AVVideoColorPrimariesKey]
        composition.colorTransferFunction = color[AVVideoTransferFunctionKey]
        composition.colorYCbCrMatrix = color[AVVideoYCbCrMatrixKey]

        let pixelFormat = hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        )
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw ShrinkError.couldNotRead("Its picture can't be decoded.") }
        reader.add(videoOutput)

        // The sound is copied as recorded: nothing to lose.
        var audioOutput: AVAssetReaderTrackOutput?
        var audioHint: CMFormatDescription?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
                audioHint = try await audioTrack.load(.formatDescriptions).first
            }
        }

        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov) } catch {
            throw ShrinkError.couldNotWrite(error.localizedDescription)
        }
        if includeMetadata {
            writer.metadata = (try? await asset.load(.metadata)) ?? []
        }

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: Int(min(fps, 60).rounded()),
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
        ]
        if hevc {
            if hdr { compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String }
        } else {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoColorPropertiesKey: color,
            AVVideoCompressionPropertiesKey: compression,
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw ShrinkError.couldNotWrite("The video encoder refused these settings.") }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioHint)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            } else {
                throw ShrinkError.couldNotWrite("Its sound can't be copied.")
            }
        }

        guard reader.startReading() else {
            throw ShrinkError.couldNotRead(reader.error?.localizedDescription ?? "")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw ShrinkError.couldNotWrite(writer.error?.localizedDescription ?? "")
        }
        writer.startSession(atSourceTime: .zero)

        let reporter = ProgressReporter(duration: duration.seconds, report: progress)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let group = DispatchGroup()
                VideoShrinker.drain(videoOutput, into: videoInput, reader: reader, offset: .zero, group: group,
                                    label: "library.video") { reporter.update($0) }
                if let audioOutput, let audioInput {
                    VideoShrinker.drain(audioOutput, into: audioInput, reader: reader, offset: .zero, group: group,
                                        label: "library.audio", onSample: nil)
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

    // MARK: - Color

    /// The source's transfer function ("ITU_R_2100_HLG", "SMPTE_ST_2084_PQ", ...), when it says.
    static func transferFunction(of format: CMFormatDescription?) -> String? {
        guard let format else { return nil }
        return CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
            as? String
    }

    /// HDR keeps the wide BT.2020 color with the source's own transfer (HLG unless it's PQ); everything
    /// else is standard BT.709.
    static func colorProperties(hdr: Bool, transfer: String?) -> [String: String] {
        guard hdr else {
            return [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
        }
        let isPQ = transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
        return [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
            AVVideoTransferFunctionKey: isPQ ? AVVideoTransferFunction_SMPTE_ST_2084_PQ
                                             : AVVideoTransferFunction_ITU_R_2100_HLG,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
        ]
    }
}
