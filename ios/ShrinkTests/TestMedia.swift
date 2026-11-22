import AVFoundation
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Makes test videos and photos on the fly, so CI needs no media files.
enum TestMedia {
    static func temporaryURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("shrink-test-\(UUID().uuidString).\(ext)")
    }

    /// A video with a moving gradient plus a moving block of noise (hard to compress, like real footage),
    /// and a 440 Hz tone when `audio` is on. `rotated` stores it sideways with a 90° transform, the way
    /// iPhones store portrait video. `location` adds a filming location to the metadata, `camera` the
    /// camera's make and model. `black` paints every frame black instead (a copy whose picture was
    /// lost, or a video filmed in the dark).
    static func makeVideo(
        width: Int, height: Int, seconds: Double, fps: Int32,
        audio: Bool, rotated: Bool = false, location: Bool = false, camera: Bool = false,
        bitrate: Int = 20_000_000, black: Bool = false, fileType: AVFileType = .mov, metadata override: [AVMetadataItem]? = nil
    ) throws -> URL {
        let url = temporaryURL(fileType == .mp4 ? "mp4" : "mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        var metadata: [AVMetadataItem] = []
        let date = AVMutableMetadataItem()
        date.identifier = .quickTimeMetadataCreationDate
        date.value = "2026-11-16T10:00:00+0000" as NSString
        date.dataType = kCMMetadataBaseDataType_UTF8 as String
        metadata.append(date)
        if location {
            let place = AVMutableMetadataItem()
            place.identifier = .quickTimeMetadataLocationISO6709
            place.value = "+37.3349-122.0090+010.000/" as NSString
            place.dataType = kCMMetadataBaseDataType_UTF8 as String
            metadata.append(place)
        }
        if camera {
            for (identifier, value) in [(AVMetadataIdentifier.quickTimeMetadataMake, "Apple"),
                                        (AVMetadataIdentifier.quickTimeMetadataModel, "iPhone 17 Pro")] {
                let item = AVMutableMetadataItem()
                item.identifier = identifier
                item.value = value as NSString
                item.dataType = kCMMetadataBaseDataType_UTF8 as String
                metadata.append(item)
            }
        }
        writer.metadata = override ?? metadata

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate],
        ])
        videoInput.expectsMediaDataInRealTime = false
        if rotated { videoInput.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(videoInput)

        let sampleRate = 48_000
        var audioInput: AVAssetWriterInput?
        if audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let painter = FramePainter(width: width, height: height, black: black)
        let frames = Int(seconds * Double(fps))
        let totalAudioFrames = audioInput == nil ? 0 : Int(Double(frames) / Double(fps) * Double(sampleRate))

        // Picture and sound each fed on their own queue whenever the writer asks, the way Apple
        // documents and VideoShrinker does. Feeding them in turn on one thread deadlocked the writer's
        // interleaving now and then (CI: a 2-second clip took 43 s once, and hung 7 minutes twice).
        let group = DispatchGroup()
        var failure: Error?
        let failureLock = NSLock()
        func fail(_ error: Error) {
            failureLock.lock()
            if failure == nil { failure = error }
            failureLock.unlock()
        }

        group.enter()
        var frame = 0
        var videoDone = false
        videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "testmedia.video")) {
            guard !videoDone else { return }
            while videoInput.isReadyForMoreMediaData {
                var buffer: CVPixelBuffer?
                if frame < frames, let pool = adaptor.pixelBufferPool {
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                }
                guard frame < frames, let buffer else {
                    if frame < frames { fail(CocoaError(.fileWriteUnknown)) }
                    videoDone = true
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
                painter.paint(buffer, frame: frame)
                adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
                frame += 1
            }
        }

        if let audioInput {
            group.enter()
            var written = 0
            var audioDone = false
            audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "testmedia.audio")) {
                guard !audioDone else { return }
                while audioInput.isReadyForMoreMediaData {
                    let count = min(1024, totalAudioFrames - written)
                    var sample: CMSampleBuffer?
                    if count > 0 {
                        do { sample = try toneSample(start: written, count: count, sampleRate: sampleRate) } catch { fail(error) }
                    }
                    guard let sample else {
                        audioDone = true
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                    audioInput.append(sample)
                    written += count
                }
            }
        }

        guard group.wait(timeout: .now() + 120) == .success else {
            writer.cancelWriting()
            throw TestMediaError.writerStuck
        }
        if let failure { throw failure }

        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        guard done.wait(timeout: .now() + 60) == .success else { throw TestMediaError.writerStuck }
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }

    enum TestMediaError: Error {
        /// The writer stopped taking samples: fail the test instead of hanging it.
        case writerStuck
    }

    private static func toneSample(start: Int, count: Int, sampleRate: Int) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        )
        var samples = [Int16](repeating: 0, count: count * 2)
        for i in 0..<count {
            let value = Int16(sin(2 * .pi * 440 * Double(start + i) / Double(sampleRate)) * 8_000)
            samples[2 * i] = value
            samples[2 * i + 1] = value
        }
        let byteCount = count * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        )
        guard let block, let format else { throw CocoaError(.fileWriteUnknown) }
        samples.withUnsafeBytes { bytes in
            _ = CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount
            )
        }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
            presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sample
        )
        guard let sample else { throw CocoaError(.fileWriteUnknown) }
        return sample
    }

    /// A photo: gradient with a band of noise, saved as JPEG (or HEIC, like an iPhone's) with GPS and
    /// an EXIF orientation of 6 (stored sideways, shown upright as portrait). `extra` adds more
    /// properties (an IPTC caption, say).
    static func makePhoto(width: Int, height: Int, type: UTType = .jpeg, extra: [CFString: Any] = [:]) throws -> URL {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        for y in 0..<(height * 3 / 4) {
            for x in 0..<width {
                let i = y * bytesPerRow + x * 4
                pixels[i] = UInt8(x % 256)
                pixels[i + 1] = UInt8((x + y) % 256)
                pixels[i + 2] = UInt8(y % 256)
                pixels[i + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        let url = temporaryURL(type.preferredFilenameExtension ?? "jpg")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw XCTSkip("This simulator can't write \(type.identifier) files")
        }
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 37.3349, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 122.0090, kCGImagePropertyGPSLongitudeRef: "W",
        ]
        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: gps,
        ]
        properties.merge(extra) { _, new in new }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }
}

/// Paints test frames with memcpy only, so making a 1080p test video stays fast in a Debug build.
private final class FramePainter {
    let width: Int, height: Int
    private let gradient: [UInt8]   // two frame-widths of BGRA, read at a moving offset
    private let noise: [UInt8]      // noise rows for the moving block
    private let blockWidth: Int, blockHeight: Int, noiseRowBytes: Int
    private let black: Bool

    init(width: Int, height: Int, black: Bool = false) {
        self.width = width
        self.height = height
        self.black = black
        var row = [UInt8](repeating: 255, count: width * 2 * 4)
        for x in 0..<(width * 2) {
            row[x * 4] = UInt8(x % 256)
            row[x * 4 + 1] = UInt8((x / 2) % 256)
            row[x * 4 + 2] = UInt8(255 - x % 256)
        }
        gradient = row
        blockWidth = width / 2
        blockHeight = height / 2
        noiseRowBytes = (blockWidth + 64) * 4
        var noise = [UInt8](repeating: 0, count: noiseRowBytes * height)
        noise.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        self.noise = noise
    }

    func paint(_ buffer: CVPixelBuffer, frame: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        if black {
            memset(base, 0, bytesPerRow * height)
            return
        }
        let gradientOffset = ((frame * 8) % width) * 4
        let blockX = (frame * 6) % (width - blockWidth)
        let blockY = (frame * 3) % (height - blockHeight)
        gradient.withUnsafeBytes { g in
            noise.withUnsafeBytes { n in
                for y in 0..<height {
                    let row = base + y * bytesPerRow
                    memcpy(row, g.baseAddress! + gradientOffset, width * 4)
                    if y >= blockY && y < blockY + blockHeight {
                        let source = n.baseAddress! + ((y + frame * 5) % height) * noiseRowBytes + ((frame * 3) % 64) * 4
                        memcpy(row + blockX * 4, source, blockWidth * 4)
                    }
                }
            }
        }
    }
}
