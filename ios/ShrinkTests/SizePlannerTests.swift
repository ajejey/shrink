import XCTest
@testable import ShrinkCore

final class SizePlannerTests: XCTestCase {
    func testTenMegabytesFor30SecondsOf4K60() throws {
        let plan = try XCTUnwrap(SizePlanner.plan(
            targetBytes: 10_000_000, durationSeconds: 30, hasAudio: true, sourceLongSide: 3840, sourceFrameRate: 60
        ))
        XCTAssertEqual(plan.audioBitsPerSecond, 128_000)
        XCTAssertEqual(plan.maxFrameRate, 30, "a tight budget drops 60 fps to 30")
        XCTAssertEqual(plan.maxLongSide, 1280, "~2.3 Mbps looks decent at 720p, not at 1080p")
        let plannedBytes = Double(plan.videoBitsPerSecond + plan.audioBitsPerSecond) * 30 / 8
        XCTAssertLessThan(plannedBytes, 10_000_000)
    }

    func testTooLongToFitReturnsNil() {
        XCTAssertNil(SizePlanner.plan(
            targetBytes: 10_000_000, durationSeconds: 1800, hasAudio: true, sourceLongSide: 1920, sourceFrameRate: 30
        ))
    }

    func testSilentVideoSpendsNothingOnSound() throws {
        let plan = try XCTUnwrap(SizePlanner.plan(
            targetBytes: 25_000_000, durationSeconds: 60, hasAudio: false, sourceLongSide: 1920, sourceFrameRate: 30
        ))
        XCTAssertEqual(plan.audioBitsPerSecond, 0)
    }

    func testNeverSpendsMoreThanTheSourceHad() throws {
        let plan = try XCTUnwrap(SizePlanner.plan(
            targetBytes: 100_000_000, durationSeconds: 10, hasAudio: true, sourceLongSide: 1920,
            sourceFrameRate: 30, sourceVideoBitsPerSecond: 1_000_000
        ))
        XCTAssertEqual(plan.videoBitsPerSecond, 1_000_000)
    }

    func testNeverUpscales() throws {
        let plan = try XCTUnwrap(SizePlanner.plan(
            targetBytes: 100_000_000, durationSeconds: 10, hasAudio: false, sourceLongSide: 640, sourceFrameRate: 30
        ))
        XCTAssertEqual(plan.maxLongSide, 640)
    }

    func testKeeps60FpsWhenTheBudgetAllows() throws {
        let plan = try XCTUnwrap(SizePlanner.plan(
            targetBytes: 100_000_000, durationSeconds: 10, hasAudio: true, sourceLongSide: 1920, sourceFrameRate: 60
        ))
        XCTAssertEqual(plan.maxFrameRate, 60)
        XCTAssertEqual(plan.maxLongSide, 1920)
    }

    func testSmallOvershootLowersOnlyTheBitrate() throws {
        let plan = SizePlan(videoBitsPerSecond: 2_000_000, audioBitsPerSecond: 128_000, maxLongSide: 1280, maxFrameRate: 30)
        let next = try XCTUnwrap(SizePlanner.corrected(
            plan, deliveredBytes: 2_800_000, targetBytes: 2_500_000, durationSeconds: 10
        ))
        XCTAssertLessThan(next.videoBitsPerSecond, plan.videoBitsPerSecond)
        XCTAssertGreaterThanOrEqual(next.videoBitsPerSecond, SizePlanner.minimumVideoBitsPerSecond)
        XCTAssertEqual(next.maxLongSide, plan.maxLongSide)
    }

    /// From CI run 43846722967: grainy 60 fps footage stayed at 741 KB for a 600 KB limit on every
    /// bitrate we tried. A big overshoot means the encoder is at its floor, so the picture gets smaller.
    func testBigOvershootAlsoShrinksThePicture() throws {
        let plan = SizePlan(videoBitsPerSecond: 1_104_000, audioBitsPerSecond: 0, maxLongSide: 960, maxFrameRate: 30)
        let next = try XCTUnwrap(SizePlanner.corrected(
            plan, deliveredBytes: 741_288, targetBytes: 600_000, durationSeconds: 4
        ))
        XCTAssertLessThan(next.maxLongSide, 960)
        XCTAssertLessThan(next.videoBitsPerSecond, plan.videoBitsPerSecond)
    }

    func testOutputSizeKeepsShapeAndEvenNumbers() {
        let portrait = VideoShrinker.outputSize(width: 1080, height: 1920, maxLongSide: 1280)
        XCTAssertEqual(portrait, CGSize(width: 720, height: 1280))
        let odd = VideoShrinker.outputSize(width: 1001, height: 501, maxLongSide: 4000)
        XCTAssertEqual(Int(odd.width) % 2, 0)
        XCTAssertEqual(Int(odd.height) % 2, 0)
    }
}
