import XCTest

/// Uses the app the way a person would, slowly enough to watch, while the demo workflow records the
/// simulator's screen. Expects a video in the simulator's Photos (the workflow adds one with
/// `simctl addmedia`).
final class ShrinkDemoTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testCompressAVideoForDiscord() throws {
        let app = XCUIApplication()
        app.launch()
        // The workflow cuts the recording to start here (the minute or so before is test setup).
        print("DEMO_START \(Date().timeIntervalSince1970)")
        pause(2.5)

        // Home: pick where the video is going.
        let discord = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Compress for Discord'")).firstMatch
        XCTAssertTrue(discord.waitForExistence(timeout: 15), "the Discord row is on the home screen")
        discord.tap()
        pause(2)

        // The system photo picker: tap the video.
        let video = pickerItem(in: app)
        XCTAssertTrue(video.exists, "the photo picker shows the demo video")
        print("Tapping picker item: identifier=\(video.identifier) label=\(video.label)")
        // The picker runs in another process and XCUITest calls its thumbnail "not hittable"
        // (run 43856296362), so tap the spot on screen where it is instead.
        let spot = video.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: spot.midX, dy: spot.midY)).tap()
        pause(1.5)
        XCTAssertEqual(app.state, .runningForeground, "Shrink is still open after picking the video")

        // The trim screen: keep the whole video and shrink it.
        let shrinkIt = app.buttons["Shrink it"]
        XCTAssertTrue(shrinkIt.waitForExistence(timeout: 30), "the trim screen opened")
        pause(2.5)
        shrinkIt.tap()

        // Shrinking, then the result.
        XCTAssertTrue(app.staticTexts["Ready to send"].waitForExistence(timeout: 300), "the video shrank")
        pause(4)

        // The share sheet a person would send it from. No XCTest screenshots here: the screen
        // recording is the record, and run 43858737386 failed when one timed out.
        let send = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Send it'")).firstMatch
        if send.waitForExistence(timeout: 5) {
            send.tap()
            pause(4)
        }
    }

    /// The video's thumbnail in the system picker. On iOS 26.4 it is an Image with identifier
    /// "PXGGridLayout-Info" and a label like "Video, twenty seconds, November 16, 10:58 AM" (from the
    /// tree logged in run 43853509931). Loose matches went wrong twice: run 43850478006 tapped the
    /// "Private Access to Photos" banner icon, run 43853509931 the "Videos" tab.
    private func pickerItem(in app: XCUIApplication) -> XCUIElement {
        let candidates = [
            app.images.matching(identifier: "PXGGridLayout-Info").firstMatch,
            app.images.matching(NSPredicate(format: "label BEGINSWITH 'Video, '")).firstMatch,
        ]
        let deadline = Date().addingTimeInterval(25)
        var logged = false
        while Date() < deadline {
            if let hit = candidates.first(where: { $0.exists && !$0.frame.isEmpty }) { return hit }
            if !logged, Date() > deadline.addingTimeInterval(-20) {
                // Once the picker has had a few seconds to load: what it looks like, for the next fix.
                print("Picker accessibility tree:\n\(app.debugDescription)")
                logged = true
            }
            pause(0.5)
        }
        attach(app, name: "picker-not-found")
        return candidates[0]
    }

    private func pause(_ seconds: Double) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
