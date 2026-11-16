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
}
