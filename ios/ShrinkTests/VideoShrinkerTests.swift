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

    func testLocationIsKeptWhenThePersonChoosesTo() async throws {
        let source = try TestMedia.makeVideo(width: 640, height: 360, seconds: 2, fps: 30, audio: false, location: true)
        let output = TestMedia.temporaryURL("mp4")

        _ = try await VideoShrinker().shrink(asset: AVURLAsset(url: source), to: output,
                                             options: .init(targetBytes: 1_000_000, removeLocation: false))

        let items = try await AVURLAsset(url: output).load(.metadata)
        XCTAssertTrue(items.contains(where: isLocation))
        XCTAssertTrue(items.contains(where: isCreationDate), "the date it was filmed is kept")
    }

    // MARK: - Pro options

    func testHEVCMakesAnHEVCFileUnderTheLimit() async throws {
        let source = try TestMedia.makeVideo(width: 1920, height: 1080, seconds: 4, fps: 30, audio: true)
        let output = TestMedia.temporaryURL("mp4")
        let limit: Int64 = 1_500_000

        let result = try await VideoShrinker().shrink(asset: AVURLAsset(url: source), to: output,
                                                      options: .init(targetBytes: limit, choices: SizeChoices(hevc: true)))

        XCTAssertLessThanOrEqual(result.bytes, limit)
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let formats = try await track.load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_HEVC)
        try await assertGood(output, duration: 4, hasAudio: true, portrait: false)
    }

    func testWholeLimitLandsNearTheLimitButNeverOver() async throws {
        let source = try TestMedia.makeVideo(width: 1920, height: 1080, seconds: 6, fps: 30, audio: true)
        let output = TestMedia.temporaryURL("mp4")
        let limit: Int64 = 3_000_000

        let result = try await VideoShrinker().shrink(asset: AVURLAsset(url: source), to: output,
                                                      options: .init(targetBytes: limit, choices: SizeChoices(exactSize: true)))

        print("WHOLE-LIMIT \(result.bytes) of \(limit) in \(result.passes) passes")
        XCTAssertLessThanOrEqual(result.bytes, limit)
        XCTAssertLessThanOrEqual(fileSize(output), limit)
        XCTAssertEqual(fileSize(output), result.bytes, "the file handed back is the one measured")
        XCTAssertGreaterThan(Double(result.bytes), Double(limit) * 0.88, "lands near the limit")
        try await assertGood(output, duration: 6, hasAudio: true, portrait: false)
    }

    func testChosenPictureSizeIsUsed() async throws {
        let source = try TestMedia.makeVideo(width: 1920, height: 1080, seconds: 3, fps: 30, audio: false)
        let output = TestMedia.temporaryURL("mp4")

        let result = try await VideoShrinker().shrink(asset: AVURLAsset(url: source), to: output,
                                                      options: .init(targetBytes: 5_000_000, choices: SizeChoices(longSide: 854)))

        XCTAssertEqual(Int(max(result.outputSize.width, result.outputSize.height)), 854)
        try await assertGood(output, duration: 3, hasAudio: false, portrait: false)
    }

    func testAllTheDetailsOnlyWhenAskedAndNeverThePlace() async throws {
        let source = try TestMedia.makeVideo(width: 640, height: 360, seconds: 2, fps: 30, audio: false,
                                             location: true, camera: true)
        let usual = TestMedia.temporaryURL("mp4")
        _ = try await VideoShrinker().shrink(asset: AVURLAsset(url: source), to: usual,
                                             options: .init(targetBytes: 1_000_000))
        let usualItems = try await AVURLAsset(url: usual).load(.metadata)
        XCTAssertFalse(usualItems.contains(where: isCameraModel), "the usual settings leave the camera out")

        let options = VideoShrinkOptions(targetBytes: 1_000_000, keepsAllDetails: true)
        XCTAssertEqual(options.fileExtension, "mov", "MP4 can't hold the camera, so all the details make a .mov")
        let all = TestMedia.temporaryURL(options.fileExtension)
        _ = try await VideoShrinker().shrink(asset: AVURLAsset(url: source), to: all, options: options)
        let allItems = try await AVURLAsset(url: all).load(.metadata)
        XCTAssertTrue(allItems.contains(where: isCameraModel), "all the details keep the camera")
        XCTAssertTrue(allItems.contains(where: isCreationDate), "and the date")
        XCTAssertFalse(allItems.contains(where: isLocation), "the place still follows Remove location")
    }

    /// The CI sample video has about 50 kbps of picture. It used to be turned away as too long for
    /// any limit; now it's made at its own rate.
    func testVeryLowBitrateVideoIsNotTurnedAway() async throws {
        let source = try TestMedia.makeVideo(width: 640, height: 360, seconds: 4, fps: 30, audio: true,
                                             bitrate: 60_000, black: true)
        let output = TestMedia.temporaryURL("mp4")

        let result = try await VideoShrinker().shrink(asset: AVURLAsset(url: source), to: output,
                                                      options: .init(targetBytes: 25_000_000))

        XCTAssertLessThanOrEqual(result.bytes, 25_000_000)
        XCTAssertEqual(Int(max(result.outputSize.width, result.outputSize.height)), 640, "keeps its own size")
        try await assertGood(output, duration: 4, hasAudio: true, portrait: false)
    }

    // MARK: - Trim

    func testTrimKeepsOnlyThePickedPartAndStartsAtZero() async throws {
        let source = try TestMedia.makeVideo(width: 1280, height: 720, seconds: 8, fps: 30, audio: true)
        let output = TestMedia.temporaryURL("mp4")
        let part = CMTimeRange(start: CMTime(seconds: 2, preferredTimescale: 600), end: CMTime(seconds: 5, preferredTimescale: 600))

        let result = try await VideoShrinker().shrink(
            asset: AVURLAsset(url: source), to: output, options: .init(targetBytes: 1_000_000, timeRange: part)
        )

        XCTAssertLessThanOrEqual(result.bytes, 1_000_000)
        try await assertGood(output, duration: 3, hasAudio: true, portrait: false)
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
        let range = try await XCTUnwrap(tracks.first).load(.timeRange)
        XCTAssertEqual(range.start.seconds, 0, accuracy: 0.05, "the trimmed file starts at 0:00, with no gap")
    }

    func testTrimPastTheEndKeepsUpToTheEnd() async throws {
        let source = try TestMedia.makeVideo(width: 1280, height: 720, seconds: 4, fps: 30, audio: true)
        let output = TestMedia.temporaryURL("mp4")
        let part = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600), duration: CMTime(seconds: 60, preferredTimescale: 600))

        _ = try await VideoShrinker().shrink(
            asset: AVURLAsset(url: source), to: output, options: .init(targetBytes: 1_000_000, timeRange: part)
        )

        try await assertGood(output, duration: 3, hasAudio: true, portrait: false)
    }

    func testTooShortATrimSaysSo() async throws {
        let source = try TestMedia.makeVideo(width: 640, height: 360, seconds: 2, fps: 30, audio: false)
        let output = TestMedia.temporaryURL("mp4")
        let part = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600), duration: CMTime(seconds: 0.2, preferredTimescale: 600))

        do {
            _ = try await VideoShrinker().shrink(
                asset: AVURLAsset(url: source), to: output, options: .init(targetBytes: 1_000_000, timeRange: part)
            )
            XCTFail("expected trimTooShort")
        } catch let error as ShrinkError {
            XCTAssertEqual(error, .trimTooShort)
        }
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

    // An MP4 may hand items back in its own key space (iTunes, user data), so match the common key too.

    private func isLocation(_ item: AVMetadataItem) -> Bool {
        item.commonKey == .commonKeyLocation
            || item.identifier?.rawValue.lowercased().contains("location") == true
            || item.identifier?.rawValue.lowercased().contains("xyz") == true
    }

    private func isCreationDate(_ item: AVMetadataItem) -> Bool {
        item.commonKey == .commonKeyCreationDate
            || item.identifier?.rawValue.lowercased().contains("creationdate") == true
    }

    private func isCameraModel(_ item: AVMetadataItem) -> Bool {
        item.commonKey == .commonKeyModel || item.identifier?.rawValue.lowercased().contains("model") == true
    }

    private func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
