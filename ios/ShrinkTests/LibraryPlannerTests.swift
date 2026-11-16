import XCTest
@testable import ShrinkCore

/// Free up space's size math: what a library copy should weigh, and which videos are worth it.
final class LibraryPlannerTests: XCTestCase {
    func testA4KVideoBecomes1080pWithTheSameShape() {
        let landscape = LibraryPlanner.outputDimensions(width: 3840, height: 2160, size: .hd)
        XCTAssertEqual(landscape.width, 1920)
        XCTAssertEqual(landscape.height, 1080)
        let portrait = LibraryPlanner.outputDimensions(width: 2160, height: 3840, size: .hd)
        XCTAssertEqual(portrait.width, 1080)
        XCTAssertEqual(portrait.height, 1920)
    }

    func testKeep4KAndSmallVideosAreNeverMadeBigger() {
        let kept = LibraryPlanner.outputDimensions(width: 3840, height: 2160, size: .keep4K)
        XCTAssertEqual(kept.width, 3840)
        let small = LibraryPlanner.outputDimensions(width: 1280, height: 720, size: .hd)
        XCTAssertEqual(small.width, 1280)
        XCTAssertEqual(small.height, 720)
    }

    func testBitratesFollowSizeAndFrameRate() {
        let hd30 = LibraryPlanner.videoBitsPerSecond(width: 1920, height: 1080, frameRate: 30, hevc: true)
        XCTAssertEqual(hd30, 4_500_000)
        let hd60 = LibraryPlanner.videoBitsPerSecond(width: 1920, height: 1080, frameRate: 60, hevc: true)
        XCTAssertGreaterThan(hd60, hd30)
        XCTAssertLessThan(hd60, hd30 * 2)
        let uhd30 = LibraryPlanner.videoBitsPerSecond(width: 3840, height: 2160, frameRate: 30, hevc: true)
        XCTAssertGreaterThan(uhd30, hd30 * 2)
        XCTAssertLessThan(uhd30, hd30 * 4)
        let h264 = LibraryPlanner.videoBitsPerSecond(width: 1920, height: 1080, frameRate: 30, hevc: false)
        XCTAssertGreaterThan(h264, hd30)
    }

    /// A minute of iPhone 4K at 30 fps is about 170 MB; the 1080p copy should be around 35 MB.
    func testAMinuteOf4KShrinksToAboutAFifth() {
        let copy = LibraryPlanner.estimatedBytes(durationSeconds: 60, width: 3840, height: 2160, frameRate: 30,
                                                 size: .hd, hevc: true)
        XCTAssertGreaterThan(copy, 30_000_000)
        XCTAssertLessThan(copy, 40_000_000)
        XCTAssertTrue(LibraryPlanner.isWorthShrinking(originalBytes: 170_000_000, estimatedBytes: copy))
    }

    func testSmallSavingsAreNotListed() {
        // Saves 40 MB: under 50 MB.
        XCTAssertFalse(LibraryPlanner.isWorthShrinking(originalBytes: 100_000_000, estimatedBytes: 60_000_000))
        // Saves 60 MB, but only 20% of the video.
        XCTAssertFalse(LibraryPlanner.isWorthShrinking(originalBytes: 300_000_000, estimatedBytes: 240_000_000))
        // A copy bigger than the original.
        XCTAssertFalse(LibraryPlanner.isWorthShrinking(originalBytes: 50_000_000, estimatedBytes: 80_000_000))
        XCTAssertTrue(LibraryPlanner.isWorthShrinking(originalBytes: 300_000_000, estimatedBytes: 100_000_000))
    }
}
