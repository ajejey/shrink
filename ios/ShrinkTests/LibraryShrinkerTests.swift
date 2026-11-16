import AVFoundation
import XCTest
@testable import ShrinkCore

/// Free up space's copies: smaller, upright, same length, sound kept and in sync, and still carrying
/// the date and place it was filmed (unlike sending, nothing personal is removed from your own library).
final class LibraryShrinkerTests: XCTestCase {
    private let hevc = AVOutputSettingsAssistant.availableOutputSettingsPresets().contains(.hevc1920x1080)

    func testABigVideoBecomesASmaller1080pCopyThatKeepsItsDateAndPlace() async throws {
        let source = try TestMedia.makeVideo(width: 2560, height: 1440, seconds: 2, fps: 30, audio: true,
                                             location: true, bitrate: 30_000_000)
        let output = TestMedia.temporaryURL("mov")
        let original = fileSize(source)

        let result = try await LibraryShrinker().shrink(
            asset: AVURLAsset(url: source), to: output,
            options: .init(size: .hd, hevc: hevc, originalBytes: original)
        )

        XCTAssertEqual(result.outputSize.width, 1920)
        XCTAssertEqual(result.outputSize.height, 1080)
        XCTAssertLessThan(result.bytes, original / 2, "much smaller than the original")
        try await assertGood(output, duration: 2, hasAudio: true, portrait: false)

        let items = try await AVURLAsset(url: output).load(.metadata)
        let ids = items.compactMap { $0.identifier?.rawValue.lowercased() }
        XCTAssertTrue(ids.contains { $0.contains("location") }, "keeps where it was filmed")
        XCTAssertTrue(ids.contains { $0.contains("creationdate") }, "keeps when it was filmed")
    }

    func testPortraitVideoComesOutUpright() async throws {
        let source = try TestMedia.makeVideo(width: 1920, height: 1080, seconds: 3, fps: 30, audio: true,
                                             rotated: true, bitrate: 30_000_000)
        let output = TestMedia.temporaryURL("mov")

        let result = try await LibraryShrinker().shrink(asset: AVURLAsset(url: source), to: output,
                                                        options: .init(size: .hd, hevc: hevc))

        XCTAssertGreaterThan(result.outputSize.height, result.outputSize.width)
        try await assertGood(output, duration: 3, hasAudio: true, portrait: true)
    }

    func testUsesHEVCWhenTheIPhoneHasIt() async throws {
        try XCTSkipUnless(hevc, "this simulator can't write HEVC")
        let source = try TestMedia.makeVideo(width: 1920, height: 1080, seconds: 2, fps: 30, audio: false,
                                             bitrate: 30_000_000)
        let output = TestMedia.temporaryURL("mov")

        let result = try await LibraryShrinker().shrink(asset: AVURLAsset(url: source), to: output,
                                                        options: .init(size: .hd, hevc: true))

        XCTAssertTrue(result.usedHEVC)
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let formats = try await track.load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_HEVC)
        try await assertGood(output, duration: 2, hasAudio: false, portrait: false)
    }

    /// A copy that isn't clearly smaller than the original replaces nothing and leaves nothing behind.
    /// (The scan only lists videos expected to save 30%, so this catches estimates that were wrong.)
    func testACopyThatIsNotClearlySmallerIsThrownAway() async throws {
        let source = try TestMedia.makeVideo(width: 1280, height: 720, seconds: 2, fps: 30, audio: false)
        let output = TestMedia.temporaryURL("mov")

        do {
            // Claim the original is tiny: any real copy is bigger than 90% of it.
            _ = try await LibraryShrinker().shrink(
                asset: AVURLAsset(url: source), to: output,
                options: .init(size: .hd, hevc: hevc, originalBytes: 10_000)
            )
            XCTFail("expected notSmaller")
        } catch let error as ShrinkError {
            XCTAssertEqual(error, .notSmaller)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "no copy left behind")
    }

    func testStandardVideoIsTaggedStandardColor() {
        let sdr = LibraryShrinker.colorProperties(hdr: false, transfer: nil)
        XCTAssertEqual(sdr[AVVideoTransferFunctionKey], AVVideoTransferFunction_ITU_R_709_2)
        let hlg = LibraryShrinker.colorProperties(hdr: true, transfer: nil)
        XCTAssertEqual(hlg[AVVideoTransferFunctionKey], AVVideoTransferFunction_ITU_R_2100_HLG)
        XCTAssertEqual(hlg[AVVideoColorPrimariesKey], AVVideoColorPrimaries_ITU_R_2020)
        let pq = LibraryShrinker.colorProperties(
            hdr: true, transfer: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
        )
        XCTAssertEqual(pq[AVVideoTransferFunctionKey], AVVideoTransferFunction_SMPTE_ST_2084_PQ)
    }

    // MARK: - Checks

    private func assertGood(_ url: URL, duration: Double, hasAudio: Bool, portrait: Bool,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable, "plays", file: file, line: line)
        let actual = try await asset.load(.duration).seconds
        XCTAssertEqual(actual, duration, accuracy: 0.25, "duration unchanged", file: file, line: line)

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(videoTracks.first, file: file, line: line)
        let (size, transform, videoRange) = try await video.load(.naturalSize, .preferredTransform, .timeRange)
        let upright = size.applying(transform)
        XCTAssertEqual(abs(upright.height) > abs(upright.width), portrait, "rotation", file: file, line: line)

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(!audioTracks.isEmpty, hasAudio, "sound present", file: file, line: line)
        if let audio = audioTracks.first {
            let audioRange = try await audio.load(.timeRange)
            XCTAssertEqual(audioRange.start.seconds, videoRange.start.seconds, accuracy: 0.1,
                           "sound starts with the picture", file: file, line: line)
            XCTAssertEqual(audioRange.duration.seconds, videoRange.duration.seconds, accuracy: 0.25,
                           "sound lasts as long as the picture", file: file, line: line)
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        _ = try await generator.image(at: CMTime(seconds: min(1, duration / 2), preferredTimescale: 600))
    }

    private func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
