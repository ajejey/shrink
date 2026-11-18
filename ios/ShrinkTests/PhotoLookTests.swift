import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrinkCore

/// Photo cleanup's look at each picture: fingerprints, Vision's feature print and quality score, and
/// camera details. Pictures are drawn on the fly.
final class PhotoLookTests: XCTestCase {
    // MARK: - Pictures

    /// Repeatable random numbers, so each scene is drawn the same way every time.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    /// A made-up scene: a sky gradient with coloured shapes. `shift` moves every shape a little, like
    /// the next shot of the same moment.
    private func scene(_ seed: UInt64, shift: CGFloat = 0, width: Int = 480, height: Int = 360) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var random = Seeded(state: seed &* 2_654_435_761 &+ 1)
        func color() -> CGColor {
            CGColor(srgbRed: .random(in: 0...1, using: &random), green: .random(in: 0...1, using: &random),
                    blue: .random(in: 0...1, using: &random), alpha: 1)
        }
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  colors: [color(), color()] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
        for index in 0..<14 {
            context.setFillColor(color())
            let size = CGFloat.random(in: 30...140, using: &random)
            let rect = CGRect(x: .random(in: 0...CGFloat(width), using: &random) + shift,
                              y: .random(in: 0...CGFloat(height), using: &random) + shift / 2,
                              width: size, height: size * .random(in: 0.5...1.5, using: &random))
            if index % 2 == 0 { context.fillEllipse(in: rect) } else { context.fill(rect) }
        }
        return context.makeImage()!
    }

    /// The same picture out of focus: drawn tiny, then stretched back.
    private func blurred(_ image: CGImage) -> CGImage {
        func draw(_ source: CGImage, width: Int, height: Int) -> CGImage {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()!
        }
        return draw(draw(image, width: image.width / 24, height: image.height / 24), width: image.width, height: image.height)
    }

    private func black(width: Int = 480, height: Int = 360) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.02, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// The picture as a JPEG file, with camera details when `camera` names one.
    private func jpeg(_ image: CGImage, camera: (make: String, model: String)? = nil) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if let camera {
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: camera.make,
                                                          kCGImagePropertyTIFFModel: camera.model]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    // MARK: - Fingerprints

    func testTheSamePictureHasTheSameDifferenceHash() throws {
        let a = try XCTUnwrap(PhotoLook.differenceHash(scene(1)))
        let again = try XCTUnwrap(PhotoLook.differenceHash(scene(1)))
        let other = try XCTUnwrap(PhotoLook.differenceHash(scene(2)))
        XCTAssertEqual(a, again)
        XCTAssertGreaterThan(PhotoLook.hammingDistance(a, other), 10, "different scenes differ in many bits")
    }

    func testPixelHashMatchesOnlyTheVerySamePixels() throws {
        let a = try XCTUnwrap(PhotoLook.pixelHash(scene(1)))
        XCTAssertEqual(a, PhotoLook.pixelHash(scene(1)))
        XCTAssertNotEqual(a, PhotoLook.pixelHash(scene(1, shift: 1)), "moved by one pixel")
        XCTAssertTrue(a.hasPrefix("480x360-"))
    }

    func testAPictureReadBackFromItsFileHasTheSamePixels() throws {
        // What the app does with two copies of one file in the library.
        let data = jpeg(scene(3))
        let first = try XCTUnwrap(PhotoLook.decode(data))
        let second = try XCTUnwrap(PhotoLook.decode(data))
        XCTAssertEqual(PhotoLook.pixelHash(first), PhotoLook.pixelHash(second))
    }

    // MARK: - Camera details

    func testCameraPhotosNameTheirCameraAndDownloadsDont() {
        XCTAssertTrue(PhotoLook.hasCameraDetails(jpeg(scene(4), camera: ("Apple", "iPhone 15 Pro"))))
        XCTAssertFalse(PhotoLook.hasCameraDetails(jpeg(scene(4))), "saved from a chat or the web")
        XCTAssertFalse(PhotoLook.hasCameraDetails(Data("not a picture".utf8)))
    }

    // MARK: - Vision

    func testNextShotOfTheSameMomentIsCloserThanAnotherScene() throws {
        let a: FeatureVector, nextShot: FeatureVector, other: FeatureVector, same: FeatureVector
        do {
            a = try PhotoLook.featureVector(scene(5))
            same = try PhotoLook.featureVector(scene(5))
            nextShot = try PhotoLook.featureVector(scene(5, shift: 6))
            other = try PhotoLook.featureVector(scene(6))
        } catch {
            throw XCTSkip("Vision feature prints don't run on this simulator: \(error)")
        }
        let toNext = a.distance(to: nextShot), toOther = a.distance(to: other)
        print("PHOTO-LOOK: feature print distance same \(a.distance(to: same)), next shot \(toNext), other scene \(toOther), \(a.bytes.count) values")
        XCTAssertEqual(a.distance(to: same), 0, accuracy: 0.02)
        XCTAssertLessThan(toNext, toOther)
    }

    func testVisionQualityScoreIsInRange() throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("Vision's quality score needs iOS 18") }
        let sharp: PhotoLook.Quality?, soft: PhotoLook.Quality?, dark: PhotoLook.Quality?
        do {
            sharp = try PhotoLook.quality(scene(7))
            soft = try PhotoLook.quality(blurred(scene(7)))
            dark = try PhotoLook.quality(black())
        } catch {
            throw XCTSkip("Vision's quality score doesn't run on this simulator: \(error)")
        }
        for (name, quality) in [("sharp", sharp), ("blurred", soft), ("dark", dark)] {
            let value = try XCTUnwrap(quality, name)
            print("PHOTO-LOOK: quality \(name) score \(value.score) utility \(value.isUtility)")
            XCTAssertTrue((-1...1).contains(value.score), "\(name) score in −1…1")
        }
    }
}
