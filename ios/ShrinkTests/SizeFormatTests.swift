import ShrinkCore
import XCTest

final class SizeFormatTests: XCTestCase {
    private let us = Locale(identifier: "en_US")

    func testMegabytesAlwaysHaveOneDecimal() {
        // The first demo showed "19 MB (was 61.5 MB)": both sides must look alike.
        XCTAssertEqual(SizeFormat.string(19_000_000, locale: us), "19.0 MB")
        XCTAssertEqual(SizeFormat.string(61_500_000, locale: us), "61.5 MB")
    }

    func testNeverRoundsUpPastALimit() {
        // 19.96 MB is under Discord's 20 MB; it must not read as "20.0 MB".
        XCTAssertEqual(SizeFormat.string(19_960_000, locale: us), "19.9 MB")
        XCTAssertEqual(SizeFormat.string(20_000_000, locale: us), "20.0 MB")
    }

    func testSmallAndLargeFiles() {
        XCTAssertEqual(SizeFormat.string(850_400, locale: us), "850 KB")
        XCTAssertEqual(SizeFormat.string(0, locale: us), "0 KB")
        XCTAssertEqual(SizeFormat.string(2_345_000_000, locale: us), "2.3 GB")
        XCTAssertEqual(SizeFormat.string(999_990_000, locale: us), "999.9 MB")
    }
}
