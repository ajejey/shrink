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
    /// iPhones store portrait video. `location` adds a filming location to the metadata. `black` paints
    /// every frame black instead (a copy whose picture was lost, or a video filmed in the dark).
    static func makeVideo(
        width: Int, height: Int, seconds: Double, fps: Int32,
        audio: Bool, rotated: Bool = false, location: Bool = false, bitrate: Int = 20_000_000, black: Bool = false
    ) throws -> URL {
        let url = temporaryURL("mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
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
        writer.metadata = metadata

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
        var audioFramesWritten = 0
        for frame in 0..<frames {
            wait(for: videoInput)
            guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            painter.paint(buffer, frame: frame)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))

            if let audioInput {
                let until = Int(Double(frame + 1) / Double(fps) * Double(sampleRate))
                while audioFramesWritten < until {
                    let count = min(1024, until - audioFramesWritten)
                    wait(for: audioInput)
                    audioInput.append(try toneSample(start: audioFramesWritten, count: count, sampleRate: sampleRate))
                    audioFramesWritten += count
                }
            }
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()

        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }

    private static func wait(for input: AVAssetWriterInput) {
        while !input.isReadyForMoreMediaData { usleep(2_000) }
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
    /// an EXIF orientation of 6 (stored sideways, shown upright as portrait).
    static func makePhoto(width: Int, height: Int, type: UTType = .jpeg) throws -> URL {
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
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: gps,
        ]
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
