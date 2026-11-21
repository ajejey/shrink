import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrinkCore

final class PhotoShrinkerTests: XCTestCase {
    func testFitsUnderTheLimitAsAnUprightJPEGWithoutLocation() throws {
        let source = try TestMedia.makePhoto(width: 2000, height: 1500)
        let output = TestMedia.temporaryURL("jpg")
        let limit: Int64 = 200_000

        let result = try PhotoShrinker.shrink(imageAt: source, to: output, targetBytes: limit)

        XCTAssertLessThanOrEqual(result.bytes, limit)
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(image) as String?, UTType.jpeg.identifier)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary], "location removed")
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        XCTAssertGreaterThan(height, width, "orientation 6 means the picture is portrait once upright")
        XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int ?? 1, 1)
    }

    func testKeepsLocationWhenAsked() throws {
        let source = try TestMedia.makePhoto(width: 800, height: 600)
        let output = TestMedia.temporaryURL("jpg")

        _ = try PhotoShrinker.shrink(imageAt: source, to: output, targetBytes: nil, removeLocation: false)

        let image = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
        XCTAssertNotNil(properties[kCGImagePropertyGPSDictionary])
    }

    func testALimitTooSmallForAnyPhotoSaysSo() throws {
        let source = try TestMedia.makePhoto(width: 2000, height: 1500)
        let output = TestMedia.temporaryURL("jpg")

        XCTAssertThrowsError(try PhotoShrinker.shrink(imageAt: source, to: output, targetBytes: 500)) { error in
            XCTAssertEqual(error as? ShrinkError, .limitTooSmall)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "nothing over the limit is left behind")
    }

    func testIPhoneHEICBecomesAnUprightJPEG() throws {
        let source = try TestMedia.makePhoto(width: 1600, height: 1200, type: .heic)
        let output = TestMedia.temporaryURL("jpg")

        let result = try PhotoShrinker.shrink(imageAt: source, to: output, targetBytes: 1_000_000)

        XCTAssertLessThanOrEqual(result.bytes, 1_000_000)
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(image) as String?, UTType.jpeg.identifier)
        XCTAssertGreaterThan(result.pixelHeight, result.pixelWidth, "upright portrait")
    }

    /// (The caption isn't a test of this: ImageIO mirrors it into the TIFF description, which the usual
    /// settings keep with the other camera details. Keywords live only in IPTC.)
    func testKeepAllTheDetailsKeepsTheKeywordsButNotTheCity() throws {
        let iptc: [CFString: Any] = [kCGImagePropertyIPTCKeywords: ["Wedding"], kCGImagePropertyIPTCCity: "Paris"]
        let source = try TestMedia.makePhoto(width: 800, height: 600, extra: [kCGImagePropertyIPTCDictionary: iptc])
        XCTAssertEqual(iptcOf(source)?[kCGImagePropertyIPTCKeywords] as? [String], ["Wedding"],
                       "the test photo should start with a keyword")

        let usual = TestMedia.temporaryURL("jpg")
        _ = try PhotoShrinker.shrink(imageAt: source, to: usual, targetBytes: nil)
        XCTAssertNil(iptcOf(usual)?[kCGImagePropertyIPTCKeywords], "the usual settings leave the keywords out")

        let all = TestMedia.temporaryURL("jpg")
        _ = try PhotoShrinker.shrink(imageAt: source, to: all, targetBytes: nil, keepsAllDetails: true)
        let kept = try XCTUnwrap(iptcOf(all))
        XCTAssertEqual(kept[kCGImagePropertyIPTCKeywords] as? [String], ["Wedding"])
        XCTAssertNil(kept[kCGImagePropertyIPTCCity], "the city goes with the place while location is removed")
    }

    private func iptcOf(_ url: URL) -> [CFString: Any]? {
        guard let image = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any] else { return nil }
        return properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
    }

    func testAPhotoAlreadyUnderTheLimitNeverComesOutBigger() throws {
        // A small, already-compressed JPEG (a chat download): re-saving at top quality would grow it.
        let big = try TestMedia.makePhoto(width: 1200, height: 900)
        let small = TestMedia.temporaryURL("jpg")
        let first = try PhotoShrinker.shrink(imageAt: big, to: small, targetBytes: 120_000)
        let original = PhotoShrinker.fileSize(small)
        let output = TestMedia.temporaryURL("jpg")

        let result = try PhotoShrinker.shrink(imageAt: small, to: output, targetBytes: 20_000_000)

        XCTAssertLessThanOrEqual(result.bytes, original, "no bigger than the original")
        XCTAssertEqual(max(result.pixelWidth, result.pixelHeight), max(first.pixelWidth, first.pixelHeight),
                       "and still its full size")
    }

    func testNoLimitStillMakesAJPEG() throws {
        // "Convert a photo to JPG": no limit, good quality, plays everywhere.
        let source = try TestMedia.makePhoto(width: 1200, height: 900)
        let output = TestMedia.temporaryURL("jpg")

        let result = try PhotoShrinker.shrink(imageAt: source, to: output, targetBytes: nil)

        XCTAssertGreaterThan(result.bytes, 0)
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(image) as String?, UTType.jpeg.identifier)
    }
}
