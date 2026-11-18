import XCTest
@testable import ShrinkCore

/// Photo cleanup's rules: which photos group together, which one stays, and what fits the free allowance.
final class PhotoPilesTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_748_772_000)

    private func vector(_ values: [Float]) -> FeatureVector {
        FeatureVector(values: values)!
    }

    /// A 16-value print pointing mostly along `axis`, nudged by `nudge` along the next one.
    private func along(_ axis: Int, nudge: Float = 0) -> FeatureVector {
        var values = [Float](repeating: 0.01, count: 16)
        values[axis] = 1
        values[(axis + 1) % 16] += nudge
        return vector(values)
    }

    private func shot(_ id: String, seconds: TimeInterval, _ print: FeatureVector) -> SimilarShots.Shot {
        SimilarShots.Shot(id: id, date: start.addingTimeInterval(seconds), vector: print)
    }

    // MARK: - Feature prints

    func testDistanceIsZeroForTheSamePrintAndLargeForUnrelatedOnes() {
        let a = along(0)
        XCTAssertEqual(a.distance(to: a), 0, accuracy: 0.001)
        XCTAssertEqual(a.distance(to: along(5)), Float(2).squareRoot(), accuracy: 0.05, "at right angles")
        let opposite = vector((0..<16).map { $0 == 0 ? -1 : -0.01 })
        XCTAssertEqual(a.distance(to: opposite), 2, accuracy: 0.01)
        XCTAssertLessThan(a.distance(to: along(0, nudge: 0.1)), 0.15)
    }

    func testScalingAPrintDoesNotChangeItsDistance() {
        let values: [Float] = (0..<768).map { sin(Float($0) * 0.37) * 0.04 }
        let small = FeatureVector(values: values)!
        let large = FeatureVector(values: values.map { $0 * 25 })!
        XCTAssertEqual(small.bytes.count, 768, "one byte per value")
        XCTAssertEqual(small.distance(to: large), 0, accuracy: 0.001)
    }

    func testAnEmptyOrMismatchedPrintIsAsFarAsCanBe() {
        XCTAssertNil(FeatureVector(values: [0, 0, 0]))
        XCTAssertEqual(along(0).distance(to: FeatureVector(bytes: Data([1, 2]))), 2)
    }

    // MARK: - Similar shots

    func testShotsOfOneMomentGroupTogether() {
        let groups = SimilarShots.groups([
            shot("a", seconds: 0, along(0)),
            shot("b", seconds: 10, along(0, nudge: 0.1)),
            shot("c", seconds: 25, along(0, nudge: 0.2)),
        ])
        XCTAssertEqual(groups.map { $0.map(\.id) }, [["a", "b", "c"]])
    }

    func testADifferentSceneEndsTheGroup() {
        let groups = SimilarShots.groups([
            shot("a", seconds: 0, along(0)),
            shot("b", seconds: 10, along(0, nudge: 0.1)),
            shot("selfie", seconds: 20, along(7)),
            shot("c", seconds: 30, along(3)),
            shot("d", seconds: 40, along(3, nudge: 0.1)),
        ])
        XCTAssertEqual(groups.map { $0.map(\.id) }, [["a", "b"], ["c", "d"]])
    }

    func testALongPauseEndsTheGroup() {
        let groups = SimilarShots.groups([
            shot("a", seconds: 0, along(0)),
            shot("b", seconds: 60, along(0)),
            shot("next day", seconds: 86_400, along(0)),
        ])
        XCTAssertEqual(groups.map { $0.map(\.id) }, [["a", "b"]])
    }

    func testAGroupCannotDriftFromOneSceneToAnother() {
        // Each shot is close to the one before, but the last is far from the first.
        let steps = (0..<6).map { step -> SimilarShots.Shot in
            var values = [Float](repeating: 0, count: 16)
            values[0] = cos(Float(step) * 0.25)
            values[1] = sin(Float(step) * 0.25)
            return shot("s\(step)", seconds: Double(step) * 5, vector(values))
        }
        let groups = SimilarShots.groups(steps, maxDistance: 0.6)
        XCTAssertGreaterThan(groups.count, 1, "the drift is split")
        for group in groups {
            XCTAssertLessThanOrEqual(group.first!.vector.distance(to: group.last!.vector), 0.6)
        }
    }

    func testOrderOfInputDoesNotMatterAndSinglesAreLeftOut() {
        let groups = SimilarShots.groups([
            shot("c", seconds: 20, along(0)),
            shot("alone", seconds: 5_000, along(9)),
            shot("a", seconds: 0, along(0)),
            shot("b", seconds: 10, along(0)),
        ])
        XCTAssertEqual(groups.map { $0.map(\.id) }, [["a", "b", "c"]])
    }

    // MARK: - Duplicates

    func testDuplicateCandidatesNeedTheSameSizeAndHash() {
        let groups = Duplicates.candidates([
            .init(id: "1", width: 4032, height: 3024, hash: 42),
            .init(id: "2", width: 4032, height: 3024, hash: 42),
            .init(id: "3", width: 3024, height: 4032, hash: 42),
            .init(id: "4", width: 4032, height: 3024, hash: 43),
            .init(id: "5", width: 640, height: 480, hash: 7),
            .init(id: "6", width: 640, height: 480, hash: 7),
            .init(id: "7", width: 640, height: 480, hash: 7),
        ])
        XCTAssertEqual(groups, [["1", "2"], ["5", "6", "7"]])
    }

    func testOnlyMatchingPixelsConfirmADuplicate() {
        let groups = Duplicates.confirmed(["1": "aa", "2": "aa", "3": "bb", "4": "", "5": ""])
        XCTAssertEqual(groups, [["1", "2"]], "an unreadable picture (no fingerprint) is never a duplicate")
    }

    // MARK: - Which one stays

    func testTheFavoriteCopyStaysThenTheOneInAlbumsThenTheOldest() {
        let older = start, newer = start.addingTimeInterval(60)
        XCTAssertEqual(Keeper.forDuplicates([
            KeepFacts(id: "plain", date: older), KeepFacts(id: "loved", date: newer, isFavorite: true),
        ]), "loved")
        XCTAssertEqual(Keeper.forDuplicates([
            KeepFacts(id: "plain", date: older), KeepFacts(id: "in album", date: newer, albumCount: 1),
        ]), "in album")
        XCTAssertEqual(Keeper.forDuplicates([
            KeepFacts(id: "copy", date: newer), KeepFacts(id: "first", date: older),
        ]), "first")
        XCTAssertNil(Keeper.forDuplicates([]))
    }

    func testTheBestShotIsTheFavoriteThenTheBestScoreThenTheSharpest() {
        XCTAssertEqual(Keeper.bestShot([
            KeepFacts(id: "pretty", date: start, score: 0.9), KeepFacts(id: "loved", date: start, isFavorite: true, score: -0.2),
        ]), "loved")
        XCTAssertEqual(Keeper.bestShot([
            KeepFacts(id: "meh", date: start, pixels: 12_000_000, score: 0.1),
            KeepFacts(id: "great", date: start, pixels: 12_000_000, score: 0.6),
        ]), "great")
        XCTAssertEqual(Keeper.bestShot([
            KeepFacts(id: "small", date: start, pixels: 3_000_000), KeepFacts(id: "big", date: start, pixels: 12_000_000),
        ]), "big")
    }

    // MARK: - Bursts

    private func member(_ id: String, user: Bool = false, auto: Bool = false, shown: Bool = false,
                        seconds: TimeInterval = 0) -> Bursts.Member {
        Bursts.Member(id: id, date: start.addingTimeInterval(seconds), userPick: user, autoPick: auto,
                      representative: shown)
    }

    func testABurstKeepsThePersonsPicks() {
        XCTAssertEqual(Bursts.keep([member("a", shown: true), member("b", user: true), member("c", user: true),
                                    member("d", auto: true)]), ["b", "c"])
    }

    func testABurstWithoutPicksKeepsTheOnePhotosShows() {
        XCTAssertEqual(Bursts.keep([member("a", auto: true), member("b", shown: true), member("c")]), ["b"])
        XCTAssertEqual(Bursts.keep([member("a"), member("b", auto: true), member("c")]), ["b"])
        XCTAssertEqual(Bursts.keep([member("late", seconds: 2), member("first", seconds: 0)]), ["first"])
        XCTAssertEqual(Bursts.keep([]), [])
    }

    // MARK: - Quality, months, allowance

    func testPoorPhotosButNotReceipts() {
        XCTAssertTrue(PhotoQuality.isPoor(score: -0.6, isUtility: false))
        XCTAssertFalse(PhotoQuality.isPoor(score: -0.6, isUtility: true), "receipts have their own pile")
        XCTAssertFalse(PhotoQuality.isPoor(score: 0.4, isUtility: false))
    }

    func testMonthsNewestFirstWithUndatedLast() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let june3 = start.addingTimeInterval(2 * 86_400)
        let june1 = start
        let july = start.addingTimeInterval(40 * 86_400)
        let items: [(String, Date?)] = [("june1", june1), ("none", nil), ("july", july), ("june3", june3)]
        let sections = Months.sections(items, calendar: calendar) { $0.1 }
        XCTAssertEqual(sections.map { $0.items.map { $0.0 } }, [["july"], ["june3", "june1"], ["none"]])
        XCTAssertNil(sections.last?.start)
    }

    func testTheFreeAllowanceTakesTheBiggestThatFit() {
        let sizes: [Int64] = [300, 2_000, 900, 1_500]
        XCTAssertEqual(Allowance.fitting(sizes, left: 2_500, unlimited: false) { $0 }, [2_000, 300])
        XCTAssertEqual(Allowance.fitting(sizes, left: 0, unlimited: false) { $0 }, [])
        XCTAssertEqual(Allowance.fitting(sizes, left: 0, unlimited: true) { $0 }, [2_000, 1_500, 900, 300])
    }
}
