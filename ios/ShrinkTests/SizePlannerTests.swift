import XCTest
@testable import ShrinkCore

final class SizePlannerTests: XCTestCase {
    func testTenMegabytesFor30SecondsOf4K60() throws {
        let plan = try XCTUnwrap(SizePlanner.plan(
            targetBytes: 10_000_000, durationSeconds: 30, hasAudio: true, sourceLongSide: 3840, sourceFrameRate: 60,
            choices: .standard
        ))
        XCTAssertEqual(plan.audioBitsPerSecond, 128_000)
        XCTAssertEqual(plan.maxFrameRate, 30, "a tight budget drops 60 fps to 30")
        XCTAssertEqual(plan.maxLongSide, 1280, "~2.3 Mbps looks decent at 720p, not at 1080p")
        let plannedBytes = Double(plan.videoBitsPerSecond + plan.audioBitsPerSecond) * 30 / 8
        XCTAssertLessThan(plannedBytes, 10_000_000)
    }

    func testTooLongToFitReturnsNil() {
        XCTAssertNil(SizePlanner.plan(
            targetBytes: 10_000_000, durationSeconds: 1800, hasAudio: true, sourceLongSide: 1920, sourceFrameRate: 30,
            choices: .standard
        ))
    }

    func testSilentVideoSpendsNothingOnSound() throws {
        let plan = try XCTUnwrap(SizePlanner.plan(
            targetBytes: 25_000_000, durationSeconds: 60, hasAudio: false, sourceLongSide: 1920, sourceFrameRate: 30,
            choices: .standard
        ))
        XCTAssertEqual(plan.audioBitsPerSecond, 0)
    }

    func testNeverSpendsMoreThanTheSourceHad() throws {
        let plan = try XCTUnwrap(SizePlanner.plan(
            targetBytes: 100_000_000, durationSeconds: 10, hasAudio: true, sourceLongSide: 1920,
            sourceFrameRate: 30, sourceVideoBitsPerSecond: 1_000_000, choices: .standard
        ))
        XCTAssertEqual(plan.videoBitsPerSecond, 1_000_000)
        XCTAssertEqual(plan.maxLongSide, 1920, "the limit isn't what holds it back, so it keeps its own size")
    }

    /// The CI sample video: 40 s at 960 × 540 with about 50 kbps of picture. It already fits any limit,
    /// so it must not be turned away as too long (it was, before the floor moved to the limit's budget).
    func testLowBitrateSourceStillFits() throws {
        let plan = try XCTUnwrap(SizePlanner.plan(
            targetBytes: 25_000_000, durationSeconds: 40, hasAudio: true, sourceLongSide: 960,
            sourceFrameRate: 30, sourceVideoBitsPerSecond: 74_000, choices: .standard
        ))
        XCTAssertEqual(plan.videoBitsPerSecond, 74_000)
        XCTAssertEqual(plan.maxLongSide, 960)
        XCTAssertEqual(plan.maxFrameRate, 30)
    }

    func testNeverAsksTheEncoderForAlmostNothing() throws {
        // A black clip can have a few kbps; the encoder is still asked for a sane minimum.
        let plan = try XCTUnwrap(SizePlanner.plan(
            targetBytes: 25_000_000, durationSeconds: 4, hasAudio: true, sourceLongSide: 640,
            sourceFrameRate: 30, sourceVideoBitsPerSecond: 3_000, choices: .standard
        ))
        XCTAssertEqual(plan.videoBitsPerSecond, SizePlanner.smallestRequestedVideoBitsPerSecond)
        XCTAssertEqual(plan.maxLongSide, 640)
    }

    func testNeverUpscales() throws {
        let plan = try XCTUnwrap(SizePlanner.plan(
            targetBytes: 100_000_000, durationSeconds: 10, hasAudio: false, sourceLongSide: 640, sourceFrameRate: 30,
            choices: .standard
        ))
        XCTAssertEqual(plan.maxLongSide, 640)
    }

    func testKeeps60FpsWhenTheBudgetAllows() throws {
        let plan = try XCTUnwrap(SizePlanner.plan(
            targetBytes: 100_000_000, durationSeconds: 10, hasAudio: true, sourceLongSide: 1920, sourceFrameRate: 60,
            choices: .standard
        ))
        XCTAssertEqual(plan.maxFrameRate, 60)
        XCTAssertEqual(plan.maxLongSide, 1920)
    }

    // MARK: - Pro choices

    func testWholeLimitAimsCloserToTheLimit() throws {
        let standard = try XCTUnwrap(SizePlanner.plan(
            targetBytes: 20_000_000, durationSeconds: 60, hasAudio: true, sourceLongSide: 1920, sourceFrameRate: 30,
            choices: .standard
        ))
        let whole = try XCTUnwrap(SizePlanner.plan(
            targetBytes: 20_000_000, durationSeconds: 60, hasAudio: true, sourceLongSide: 1920, sourceFrameRate: 30,
            choices: SizeChoices(exactSize: true)
        ))
        XCTAssertGreaterThan(whole.videoBitsPerSecond, standard.videoBitsPerSecond)
        let plannedBytes = Double(whole.videoBitsPerSecond + whole.audioBitsPerSecond) * 60 / 8
        XCTAssertLessThanOrEqual(plannedBytes, 20_000_000 * SizePlanner.exactAim + 1)
    }

    func testChosenPictureSizeIsKeptButNeverUpscaled() throws {
        let choices = SizeChoices(longSide: 1280)
        let big = try XCTUnwrap(SizePlanner.plan(
            targetBytes: 100_000_000, durationSeconds: 10, hasAudio: true, sourceLongSide: 3840, sourceFrameRate: 30,
            choices: choices
        ))
        XCTAssertEqual(big.maxLongSide, 1280, "a roomy limit still makes 720p when 720p is chosen")
        let tight = try XCTUnwrap(SizePlanner.plan(
            targetBytes: 5_000_000, durationSeconds: 60, hasAudio: true, sourceLongSide: 3840, sourceFrameRate: 30,
            choices: choices
        ))
        XCTAssertEqual(tight.maxLongSide, 1280, "a tight limit keeps the chosen size too (softer, as asked)")
        let small = try XCTUnwrap(SizePlanner.plan(
            targetBytes: 100_000_000, durationSeconds: 10, hasAudio: true, sourceLongSide: 640, sourceFrameRate: 30,
            choices: choices
        ))
        XCTAssertEqual(small.maxLongSide, 640)
    }

    func testKeep60FpsHoldsEvenWhenTheLimitIsTight() throws {
        let plan = try XCTUnwrap(SizePlanner.plan(
            targetBytes: 10_000_000, durationSeconds: 30, hasAudio: true, sourceLongSide: 3840, sourceFrameRate: 60,
            choices: SizeChoices(keepsHighFrameRate: true)
        ))
        XCTAssertEqual(plan.maxFrameRate, 60)
    }

    func testHEVCAffordsABiggerPicture() throws {
        let h264 = try XCTUnwrap(SizePlanner.plan(
            targetBytes: 10_000_000, durationSeconds: 30, hasAudio: true, sourceLongSide: 3840, sourceFrameRate: 60,
            choices: .standard
        ))
        let hevc = try XCTUnwrap(SizePlanner.plan(
            targetBytes: 10_000_000, durationSeconds: 30, hasAudio: true, sourceLongSide: 3840, sourceFrameRate: 60,
            choices: SizeChoices(hevc: true)
        ))
        XCTAssertEqual(h264.maxLongSide, 1280)
        XCTAssertEqual(hevc.maxLongSide, 1920, "the same bits look decent at 1080p in HEVC")
        XCTAssertEqual(hevc.videoBitsPerSecond, h264.videoBitsPerSecond, "the format doesn't change the size")
    }

    func testFilledRaisesTheBitrateTowardTheLimit() throws {
        let plan = SizePlan(videoBitsPerSecond: 2_000_000, audioBitsPerSecond: 128_000, maxLongSide: 1280, maxFrameRate: 30)
        let next = try XCTUnwrap(SizePlanner.filled(
            plan, deliveredBytes: 1_750_000, targetBytes: 2_500_000, durationSeconds: 10,
            choices: SizeChoices(exactSize: true), maxVideoBitsPerSecond: nil
        ))
        XCTAssertGreaterThan(next.videoBitsPerSecond, plan.videoBitsPerSecond)
        XCTAssertLessThanOrEqual(next.videoBitsPerSecond, plan.videoBitsPerSecond * 2)
        XCTAssertEqual(next.maxLongSide, plan.maxLongSide)
        XCTAssertEqual(next.maxFrameRate, plan.maxFrameRate)
    }

    func testFilledStopsAtWhatTheSourceHad() {
        let plan = SizePlan(videoBitsPerSecond: 2_000_000, audioBitsPerSecond: 128_000, maxLongSide: 1280, maxFrameRate: 30)
        XCTAssertNil(SizePlanner.filled(
            plan, deliveredBytes: 1_750_000, targetBytes: 2_500_000, durationSeconds: 10,
            choices: SizeChoices(exactSize: true), maxVideoBitsPerSecond: 2_000_000
        ))
    }

    // MARK: - Corrections

    func testSmallOvershootLowersOnlyTheBitrate() throws {
        let plan = SizePlan(videoBitsPerSecond: 2_000_000, audioBitsPerSecond: 128_000, maxLongSide: 1280, maxFrameRate: 30)
        let next = try XCTUnwrap(SizePlanner.corrected(
            plan, deliveredBytes: 2_800_000, targetBytes: 2_500_000, durationSeconds: 10, choices: .standard
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
            plan, deliveredBytes: 741_288, targetBytes: 600_000, durationSeconds: 4, choices: .standard
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

    // MARK: - Trim hints

    func testLongestThatFitsAgreesWithThePlanner() {
        // The trim screen's "make it shorter than…" must match what the planner will accept.
        for choices in [SizeChoices.standard, SizeChoices(exactSize: true), SizeChoices(longSide: 1280, hevc: true)] {
            for hasAudio in [true, false] {
                let longest = SizePlanner.longestSeconds(targetBytes: 20_000_000, hasAudio: hasAudio, sourceLongSide: 1920,
                                                         sourceFrameRate: 30, sharp: false, choices: choices)
                XCTAssertNotNil(SizePlanner.plan(targetBytes: 20_000_000, durationSeconds: longest * 0.99, hasAudio: hasAudio,
                                                 sourceLongSide: 1920, sourceFrameRate: 30, choices: choices), "fits just under")
                XCTAssertNil(SizePlanner.plan(targetBytes: 20_000_000, durationSeconds: longest * 1.01, hasAudio: hasAudio,
                                              sourceLongSide: 1920, sourceFrameRate: 30, choices: choices), "too long just over")
            }
        }
    }

    func testSharpLengthForDiscord() throws {
        // 20 MB with sound: about a minute and a half stays sharp at 720p.
        let sharp = SizePlanner.longestSeconds(targetBytes: 20_000_000, hasAudio: true, sourceLongSide: 1920,
                                               sourceFrameRate: 30, sharp: true, choices: .standard)
        XCTAssertEqual(sharp, 100, accuracy: 10)
        let plan = try XCTUnwrap(SizePlanner.plan(targetBytes: 20_000_000, durationSeconds: sharp, hasAudio: true,
                                                  sourceLongSide: 1920, sourceFrameRate: 30, choices: .standard))
        XCTAssertGreaterThanOrEqual(plan.maxLongSide, 1280, "a video of the sharp length keeps 720p")
        let watchable = SizePlanner.longestSeconds(targetBytes: 20_000_000, hasAudio: true, sourceLongSide: 1920,
                                                   sourceFrameRate: 30, sharp: false, choices: .standard)
        XCTAssertGreaterThan(watchable, sharp)
    }

    func testSharpLengthFollowsTheChoices() {
        func sharp(_ choices: SizeChoices) -> Double {
            SizePlanner.longestSeconds(targetBytes: 20_000_000, hasAudio: true, sourceLongSide: 1920,
                                       sourceFrameRate: 60, sharp: true, choices: choices)
        }
        XCTAssertGreaterThan(sharp(SizeChoices(hevc: true)), sharp(.standard), "HEVC stays sharp for longer")
        XCTAssertLessThan(sharp(SizeChoices(longSide: 1920)), sharp(.standard), "1080p needs more bits than 720p")
        XCTAssertLessThan(sharp(SizeChoices(keepsHighFrameRate: true)), sharp(.standard), "60 fps needs more bits")
    }
}
