import AVFoundation
import ImageIO
import XCTest
@testable import ShrinkCore

/// The quick extras on Home, on real generated videos: the sound on its own, a muted copy, one frame
/// as a photo, and a GIF.
final class QuickExtrasTests: XCTestCase {

    // MARK: - Sound

    func testTheSoundComesOutOnItsOwnAtTheSameLength() async throws {
        let video = try TestMedia.makeVideo(width: 640, height: 360, seconds: 4, fps: 30, audio: true, location: true)
        let output = TestMedia.temporaryURL("m4a")
        let bytes = try await QuickExtras.extractSound(from: AVURLAsset(url: video), to: output)
        XCTAssertGreaterThan(bytes, 1_000)

        let sound = AVURLAsset(url: output)
        let audio = try await sound.loadTracks(withMediaType: .audio)
        let picture = try await sound.loadTracks(withMediaType: .video)
        XCTAssertEqual(audio.count, 1, "one sound track")
        XCTAssertTrue(picture.isEmpty, "no picture in an audio file")
        let duration = try await sound.load(.duration).seconds
        XCTAssertEqual(duration, 4, accuracy: 0.2)
        let format = try await audio[0].load(.formatDescriptions).first
        XCTAssertEqual(format.map { CMFormatDescriptionGetMediaSubType($0) }, kAudioFormatMPEG4AAC, "AAC, as M4A")
        let facts = await QuickExtras.facts(of: sound)
        XCTAssertNil(facts.latitude, "the place it was filmed doesn't go with the sound")
    }

    func testAVideoWithoutSoundSaysSo() async throws {
        let video = try TestMedia.makeVideo(width: 640, height: 360, seconds: 2, fps: 30, audio: false)
        do {
            _ = try await QuickExtras.extractSound(from: AVURLAsset(url: video), to: TestMedia.temporaryURL("m4a"))
            XCTFail("a silent video has no sound to get")
        } catch ShrinkError.noSound {
        }
    }

    // MARK: - Mute

    func testTheMutedCopyHasNoSoundAndTheSamePicture() async throws {
        let video = try TestMedia.makeVideo(width: 1280, height: 720, seconds: 3, fps: 30, audio: true,
                                            rotated: true, location: true)
        let output = TestMedia.temporaryURL("mov")
        let bytes = try await QuickExtras.mute(AVURLAsset(url: video), to: output, keepLocation: false)
        XCTAssertGreaterThan(bytes, 10_000)

        let original = AVURLAsset(url: video), muted = AVURLAsset(url: output)
        let audio = try await muted.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audio.isEmpty, "no sound")
        let mutedDuration = try await muted.load(.duration).seconds
        let originalDuration = try await original.load(.duration).seconds
        XCTAssertEqual(mutedDuration, originalDuration, accuracy: 0.05)

        guard let mutedTrack = try await muted.loadTracks(withMediaType: .video).first,
              let originalTrack = try await original.loadTracks(withMediaType: .video).first else {
            return XCTFail("both have a picture")
        }
        let (mutedSize, mutedTransform, mutedFormat) = try await mutedTrack.load(.naturalSize, .preferredTransform, .formatDescriptions)
        let (originalSize, originalTransform, originalFormat) = try await originalTrack.load(.naturalSize, .preferredTransform, .formatDescriptions)
        XCTAssertEqual(mutedSize, originalSize)
        XCTAssertEqual(mutedTransform, originalTransform, "still stands upright")
        XCTAssertEqual(mutedFormat.first.map { CMFormatDescriptionGetMediaSubType($0) },
                       originalFormat.first.map { CMFormatDescriptionGetMediaSubType($0) },
                       "the picture is copied, not re-encoded")

        let facts = await QuickExtras.facts(of: muted)
        XCTAssertNotNil(facts.created, "the date it was filmed stays")
        XCTAssertNil(facts.latitude, "the place goes when it isn't kept")
    }

    func testTheMutedCopyKeepsThePlaceWhenAsked() async throws {
        let video = try TestMedia.makeVideo(width: 640, height: 360, seconds: 2, fps: 30, audio: true, location: true)
        let output = TestMedia.temporaryURL("mov")
        _ = try await QuickExtras.mute(AVURLAsset(url: video), to: output, keepLocation: true)
        let facts = await QuickExtras.facts(of: AVURLAsset(url: output))
        XCTAssertEqual(facts.latitude ?? 0, 37.3349, accuracy: 0.0001)
        XCTAssertEqual(facts.longitude ?? 0, -122.009, accuracy: 0.0001)
    }

    // MARK: - Frame

    func testAFrameIsUprightAndFullSize() async throws {
        let video = try TestMedia.makeVideo(width: 1280, height: 720, seconds: 2, fps: 30, audio: false, rotated: true)
        let image = try await QuickExtras.frame(of: AVURLAsset(url: video), at: 1)
        XCTAssertEqual(image.width, 720, "portrait, as filmed")
        XCTAssertEqual(image.height, 1280)

        let output = TestMedia.temporaryURL("jpg")
        let bytes = try QuickExtras.writeJPEG(image, to: output)
        XCTAssertGreaterThan(bytes, 10_000)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
        let saved = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(saved.width, 720)
        XCTAssertEqual(saved.height, 1280)
    }

    func testTheVideoSaysWhenAndWhereItWasFilmed() async throws {
        let video = try TestMedia.makeVideo(width: 640, height: 360, seconds: 1, fps: 30, audio: false, location: true)
        let facts = await QuickExtras.facts(of: AVURLAsset(url: video))
        XCTAssertEqual(facts.created?.timeIntervalSince1970 ?? 0, 1_794_823_200, accuracy: 1, "2026-11-16 10:00 UTC")
        XCTAssertEqual(facts.latitude ?? 0, 37.3349, accuracy: 0.0001)
        XCTAssertEqual(facts.longitude ?? 0, -122.009, accuracy: 0.0001)
    }

    func testPlacesAreReadFromISO6709() {
        XCTAssertEqual(QuickExtras.parseISO6709("+48.8584+002.2945+035.000/")?.0 ?? 0, 48.8584, accuracy: 0.0001)
        XCTAssertEqual(QuickExtras.parseISO6709("-33.8688+151.2093/")?.1 ?? 0, 151.2093, accuracy: 0.0001)
        XCTAssertNil(QuickExtras.parseISO6709("somewhere"))
        XCTAssertNil(QuickExtras.parseISO6709("+95.0+010.0/"), "no such latitude")
    }

    // MARK: - GIF

    func testAGIFHasEveryFrameAtTheSizeAskedAndLoops() async throws {
        let video = try TestMedia.makeVideo(width: 1280, height: 720, seconds: 3, fps: 30, audio: true)
        let output = TestMedia.temporaryURL("gif")
        let options = QuickExtras.GIFOptions(start: 0.5, end: 2.5, longSide: 480, framesPerSecond: 10)
        let steps = Steps()
        let bytes = try await QuickExtras.makeGIF(from: AVURLAsset(url: video), options: options, to: output) { value in
            steps.add(value)
        }
        XCTAssertGreaterThan(bytes, 10_000)
        XCTAssertEqual(steps.last, 1, accuracy: 0.001, "progress reaches the end")

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "com.compuserve.gif")
        XCTAssertEqual(CGImageSourceGetCount(source), 20, "2 seconds at 10 frames a second")
        let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(first.width, 480)
        XCTAssertEqual(first.height, 270)

        let file = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let loop = (file?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
        XCTAssertEqual(loop, 0, "loops forever")
        let frame = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let delay = (frame?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        XCTAssertEqual(delay ?? 0, 0.1, accuracy: 0.005)
    }

    func testAGIFOfAPortraitVideoStandsUpright() async throws {
        let video = try TestMedia.makeVideo(width: 1280, height: 720, seconds: 2, fps: 30, audio: false, rotated: true)
        let output = TestMedia.temporaryURL("gif")
        _ = try await QuickExtras.makeGIF(from: AVURLAsset(url: video),
                                          options: .init(start: 0, end: 1, longSide: 320), to: output)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(first.width, 180)
        XCTAssertEqual(first.height, 320)
        XCTAssertEqual(CGImageSourceGetCount(source), 12, "1 second at the usual 12 frames a second")
    }

    func testAGIFThatIsTooShortOrTooLongIsRefused() async throws {
        let video = try TestMedia.makeVideo(width: 640, height: 360, seconds: 2, fps: 30, audio: false)
        do {
            _ = try await QuickExtras.makeGIF(from: AVURLAsset(url: video), options: .init(start: 1, end: 1.2, longSide: 320),
                                              to: TestMedia.temporaryURL("gif"))
            XCTFail("too short")
        } catch ShrinkError.trimTooShort {
        }
        do {
            _ = try await QuickExtras.makeGIF(from: AVURLAsset(url: video), options: .init(start: 0, end: 20, longSide: 320),
                                              to: TestMedia.temporaryURL("gif"))
            XCTFail("too long")
        } catch ShrinkError.couldNotMake(let why) {
            XCTAssertTrue(why.contains("15 seconds"), why)
        }
    }
}

/// Progress values reported from another thread.
private final class Steps: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ value: Double) { lock.lock(); values.append(value); lock.unlock() }
    var last: Double { lock.lock(); defer { lock.unlock() }; return values.last ?? 0 }
}
