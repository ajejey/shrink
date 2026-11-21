import XCTest
@testable import ShrinkCore

/// Send several at once: how the files share a place's limit.
final class BatchPlannerTests: XCTestCase {
    private let halfMinute = BatchPlanner.Item.video(seconds: 30, hasAudio: true, longSide: 1920, frameRate: 30)
    private let minute = BatchPlanner.Item.video(seconds: 60, hasAudio: true, longSide: 1920, frameRate: 30)
    private let photo = BatchPlanner.Item.photo(longSide: 4032)

    func testEachFileGetsTheWholeLimitWhenTheLimitIsPerFile() {
        let shares = BatchPlanner.shares(for: [halfMinute, photo], limit: 20_000_000, together: false, choices: .standard)
        XCTAssertEqual(shares.map(\.targetBytes), [20_000_000, 20_000_000])
        XCTAssertEqual(shares[0].fit, .sharp)
        XCTAssertEqual(shares[1].fit, .sharp)
    }

    func testTooLongOnItsOwnDoesNotFit() {
        let long = BatchPlanner.Item.video(seconds: 3_000, hasAudio: true, longSide: 1920, frameRate: 30)
        let shares = BatchPlanner.shares(for: [long, halfMinute], limit: 20_000_000, together: false, choices: .standard)
        XCTAssertEqual(shares[0].fit, .doesNotFit)
        XCTAssertEqual(shares[1].fit, .sharp, "one that's too long doesn't hold back the others")
    }

    func testOneEmailSplitsTheLimitByLengthAndNeverGoesOver() throws {
        let shares = BatchPlanner.shares(for: [halfMinute, minute, photo], limit: 25_000_000, together: true, choices: .standard)
        let total = shares.compactMap(\.targetBytes).reduce(0, +)
        XCTAssertLessThanOrEqual(total, 25_000_000)
        XCTAssertEqual(shares[2].targetBytes, BatchPlanner.sharpPhotoBytes, "a photo gets what a sharp JPEG needs")
        let first = try XCTUnwrap(shares[0].targetBytes)
        let second = try XCTUnwrap(shares[1].targetBytes)
        XCTAssertEqual(Double(second) / Double(first), 2, accuracy: 0.01, "twice as long, twice the bytes")
        XCTAssertTrue(shares.allSatisfy { $0.fit != .doesNotFit })
    }

    func testTooMuchVideoForOneEmailDoesNotFit() {
        let tenMinutes = BatchPlanner.Item.video(seconds: 600, hasAudio: true, longSide: 1920, frameRate: 30)
        let shares = BatchPlanner.shares(for: [tenMinutes, tenMinutes], limit: 25_000_000, together: true, choices: .standard)
        XCTAssertTrue(shares.allSatisfy { $0.fit == .doesNotFit })
    }

    func testPhotosAloneShareTheEmailEvenly() {
        let shares = BatchPlanner.shares(for: [photo, photo, photo, photo], limit: 20_000_000, together: true, choices: .standard)
        XCTAssertEqual(shares.map(\.targetBytes), [5_000_000, 5_000_000, 5_000_000, 5_000_000])
    }

    func testPhotosNeverTakeMoreThanHalfTheEmailFromVideos() throws {
        let photos = Array(repeating: photo, count: 10)
        let shares = BatchPlanner.shares(for: [minute] + photos, limit: 20_000_000, together: true, choices: .standard)
        let video = try XCTUnwrap(shares[0].targetBytes)
        XCTAssertGreaterThanOrEqual(video, 10_000_000)
        XCTAssertLessThanOrEqual(shares.compactMap(\.targetBytes).reduce(0, +), 20_000_000)
    }

    func testNoLimitMakesJPGs() {
        let shares = BatchPlanner.shares(for: [photo, photo], limit: nil, together: false, choices: .standard)
        XCTAssertEqual(shares, [BatchPlanner.Share(targetBytes: nil, fit: .sharp), BatchPlanner.Share(targetBytes: nil, fit: .sharp)])
    }
}
