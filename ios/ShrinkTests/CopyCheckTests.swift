import AVFoundation
import XCTest
@testable import ShrinkCore

/// Free up space never lets an original go unless its copy plays, has its picture and sound, and is the
/// same length. Each test hands the check a broken "copy" and expects it to say no.
final class CopyCheckTests: XCTestCase {
    private func expectation(_ url: URL) async throws -> CopyExpectation {
        try await CopyCheck.expectation(for: AVURLAsset(url: url))
    }

    private func assertRejected(_ copy: URL, against original: URL, saying words: String,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let expected = try await expectation(original)
        do {
            try await CopyCheck.verify(AVURLAsset(url: copy), matches: expected)
            XCTFail("the check let a bad copy through", file: file, line: line)
        } catch ShrinkError.copyCheckFailed(let why) {
            XCTAssertTrue(why.contains(words), "said: \(why)", file: file, line: line)
        }
    }

    func testARealCopyPasses() async throws {
        let original = try TestMedia.makeVideo(width: 1280, height: 720, seconds: 3, fps: 30, audio: true,
                                               bitrate: 20_000_000)
        let output = TestMedia.temporaryURL("mov")
        let result = try await LibraryShrinker().shrink(asset: AVURLAsset(url: original), to: output,
                                                        options: .init(size: .hd, hevc: false))
        // The shrinker already checked it; checking it again from the file must agree.
        try await CopyCheck.verify(AVURLAsset(url: output), matches: result.expectation)
        XCTAssertEqual(result.expectation.duration, 3, accuracy: 0.1)
        XCTAssertNotNil(result.expectation.audioDuration, "the original has sound")
        XCTAssertGreaterThan(result.expectation.brightness ?? 0, CopyCheck.darkOriginal)
    }

    func testACopyThatLostItsSoundIsRejected() async throws {
        let original = try TestMedia.makeVideo(width: 640, height: 360, seconds: 2, fps: 30, audio: true)
        let silent = try TestMedia.makeVideo(width: 640, height: 360, seconds: 2, fps: 30, audio: false)
        try await assertRejected(silent, against: original, saying: "sound")
    }

    func testACopyThatIsShorterIsRejected() async throws {
        let original = try TestMedia.makeVideo(width: 640, height: 360, seconds: 3, fps: 30, audio: true)
        let short = try TestMedia.makeVideo(width: 640, height: 360, seconds: 2, fps: 30, audio: true)
        try await assertRejected(short, against: original, saying: "length")
    }

    func testABrokenFileIsRejected() async throws {
        let original = try TestMedia.makeVideo(width: 640, height: 360, seconds: 2, fps: 30, audio: true)
        // Half a file, the way an interrupted save would leave it.
        let data = try Data(contentsOf: original)
        let broken = TestMedia.temporaryURL("mov")
        try data.prefix(data.count / 2).write(to: broken)
        try await assertRejected(broken, against: original, saying: "play")
    }

    func testACopyWhosePictureCameOutBlackIsRejected() async throws {
        let original = try TestMedia.makeVideo(width: 640, height: 360, seconds: 2, fps: 30, audio: true)
        let black = try TestMedia.makeVideo(width: 640, height: 360, seconds: 2, fps: 30, audio: true, black: true)
        try await assertRejected(black, against: original, saying: "black")
    }

    /// A video filmed in the dark makes a dark copy, and that's right.
    func testADarkOriginalMayHaveADarkCopy() async throws {
        let original = try TestMedia.makeVideo(width: 640, height: 360, seconds: 2, fps: 30, audio: true, black: true)
        let copy = try TestMedia.makeVideo(width: 640, height: 360, seconds: 2, fps: 30, audio: true, black: true)
        try await CopyCheck.verify(AVURLAsset(url: copy), matches: try await expectation(original))
    }

    func testAnOriginalWithoutSoundNeedsNoSound() async throws {
        let original = try TestMedia.makeVideo(width: 640, height: 360, seconds: 2, fps: 30, audio: false)
        let expected = try await expectation(original)
        XCTAssertNil(expected.audioDuration)
        let copy = try TestMedia.makeVideo(width: 640, height: 360, seconds: 2, fps: 30, audio: false)
        try await CopyCheck.verify(AVURLAsset(url: copy), matches: expected)
    }
}
