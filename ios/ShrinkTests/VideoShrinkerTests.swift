import AVFoundation
import XCTest
@testable import ShrinkCore

/// The checks CLAUDE.md asks for on every output: under the limit, plays, sound present and in
/// sync, rotation right, duration unchanged.
final class VideoShrinkerTests: XCTestCase {
    func testLandscapeWithSoundFitsUnderTheLimit() async throws {
        let source = try TestMedia.makeVideo(width: 1920, height: 1080, seconds: 6, fps: 30, audio: true)
        let output = TestMedia.temporaryURL("mp4")
        let limit: Int64 = 2_000_000

        let result = try await VideoShrinker().shrink(asset: AVURLAsset(url: source), to: output, options: .init(targetBytes: limit))

        XCTAssertLessThanOrEqual(result.bytes, limit)
        XCTAssertLessThanOrEqual(fileSize(output), limit)
        try await assertGood(output, duration: 6, hasAudio: true, portrait: false)
    }

    func testPortraitVideoStaysPortrait() async throws {
        let source = try TestMedia.makeVideo(width: 1920, height: 1080, seconds: 4, fps: 30, audio: true, rotated: true)
        let output = TestMedia.temporaryURL("mp4")

        let result = try await VideoShrinker().shrink(asset: AVURLAsset(url: source), to: output, options: .init(targetBytes: 1_500_000))

        XCTAssertGreaterThan(result.outputSize.height, result.outputSize.width)
        try await assertGood(output, duration: 4, hasAudio: true, portrait: true)
    }

    func testSilentVideoStaysSilent() async throws {
        let source = try TestMedia.makeVideo(width: 1280, height: 720, seconds: 4, fps: 30, audio: false)
        let output = TestMedia.temporaryURL("mp4")

        _ = try await VideoShrinker().shrink(asset: AVURLAsset(url: source), to: output, options: .init(targetBytes: 1_000_000))

        try await assertGood(output, duration: 4, hasAudio: false, portrait: false)
    }

    func testSixtyFpsDropsToThirtyWhenTheLimitIsTight() async throws {
        let source = try TestMedia.makeVideo(width: 1280, height: 720, seconds: 4, fps: 60, audio: false)
        let output = TestMedia.temporaryURL("mp4")

        let result = try await VideoShrinker().shrink(asset: AVURLAsset(url: source), to: output, options: .init(targetBytes: 600_000))

        XCTAssertEqual(result.plan.maxFrameRate, 30)
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let rate = try await track.load(.nominalFrameRate)
        XCTAssertLessThanOrEqual(rate, 31)
        try await assertGood(output, duration: 4, hasAudio: false, portrait: false)
    }

    func testLocationIsRemovedByDefault() async throws {
        let source = try TestMedia.makeVideo(width: 1280, height: 720, seconds: 3, fps: 30, audio: true, location: true)
        let sourceItems = try await AVURLAsset(url: source).load(.metadata)
        XCTAssertTrue(sourceItems.contains(where: isLocation), "the test video should start with a location")
        let output = TestMedia.temporaryURL("mp4")

        _ = try await VideoShrinker().shrink(asset: AVURLAsset(url: source), to: output, options: .init(targetBytes: 1_000_000))

        let items = try await AVURLAsset(url: output).load(.metadata)
        XCTAssertFalse(items.contains(where: isLocation))
    }

    func testTooLongForTheLimitSaysSoInsteadOfMakingMush() async throws {
        let source = try TestMedia.makeVideo(width: 1280, height: 720, seconds: 6, fps: 30, audio: true)
        let output = TestMedia.temporaryURL("mp4")

        do {
            _ = try await VideoShrinker().shrink(asset: AVURLAsset(url: source), to: output, options: .init(targetBytes: 50_000))
            XCTFail("expected tooLongToFit")
        } catch let error as ShrinkError {
            XCTAssertEqual(error, .tooLongToFit)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
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
            XCTAssertEqual(audioRange.start.seconds, videoRange.start.seconds, accuracy: 0.1, "sound starts with the picture", file: file, line: line)
            XCTAssertEqual(audioRange.duration.seconds, videoRange.duration.seconds, accuracy: 0.25, "sound lasts as long as the picture", file: file, line: line)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        _ = try await generator.image(at: CMTime(seconds: min(1, duration / 2), preferredTimescale: 600))
    }

    private func isLocation(_ item: AVMetadataItem) -> Bool {
        item.identifier?.rawValue.lowercased().contains("location") == true
    }

    private func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
