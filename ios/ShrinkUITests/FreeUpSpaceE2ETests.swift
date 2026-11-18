import XCTest

/// Free up space from start to finish on the simulator's real Photos library, the way a person does it:
/// open Free up space, pick every video, shrink them, leave the app partway and come back, then answer
/// iOS's own "Allow Shrink to delete…?" prompt. The freeup-on-photos job in .github/workflows/ios.yml
/// adds the videos first and checks the library afterwards (scripts/check-freeup-e2e.mjs).
///
/// Screenshots go to the folder in TEST_RUNNER_E2E_SHOTS (the simulator can write to the Mac's disk).
final class FreeUpSpaceE2ETests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private var shotNumber = 0

    override func setUp() {
        continueAfterFailure = false
    }

    func testFreeUpSpaceOnARealPhotosLibrary() throws {
        let app = XCUIApplication()

        // 1. Set up the library (dates, a place, a favorite in an album) and record what's in it.
        runHook("prepare", in: app)

        // 2. Home → Free up space.
        app.launchArguments = []
        app.launch()
        let seeVideos = app.buttons["See the videos"]
        XCTAssertTrue(seeVideos.waitForExistence(timeout: 90), "Home's Free up space card has Photos access")
        // The card shows what the videos could free once the scan is done.
        let couldFree = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Your videos could free'")).firstMatch
        _ = couldFree.waitForExistence(timeout: 60)
        shot(app, "home")
        seeVideos.tap()

        // 3. Pick every video, then check.
        let pickAll = app.buttons["Pick all"]
        if !pickAll.waitForExistence(timeout: 60) {
            shot(app, "pick-failed")
            XCTFail(app.staticTexts["Your videos are already small"].exists
                    ? "The scan found nothing worth shrinking (are the sizes readable?)"
                    : "The pick screen didn't show its list")
        }
        pickAll.tap()
        shot(app, "pick")
        app.buttons["Next"].tap()
        let shrink = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Shrink '")).firstMatch
        XCTAssertTrue(shrink.waitForExistence(timeout: 15), "the check screen's button")
        shot(app, "check")
        print("E2E: tapping \"\(shrink.label)\"")
        shrink.tap()

        // 4. Shrinking. Leave partway, as people do, and come back.
        XCTAssertTrue(app.staticTexts["Shrinking your videos"].waitForExistence(timeout: 60), "the run started")
        sleep(10)
        shot(app, "working")
        XCUIDevice.shared.press(.home)
        print("E2E: left the app")
        sleep(30)
        app.activate()
        sleep(3)
        shot(app, "came-back")
        let keepGoing = app.buttons["Keep going"]
        if keepGoing.exists {
            print("E2E: it paused while away; tapping Keep going")
            shot(app, "paused")
            keepGoing.tap()
        } else {
            print("E2E: it kept going while away")
        }

        // 5. iOS's delete prompt for the originals.
        let deadline = Date().addingTimeInterval(25 * 60)
        var deleteButton: XCUIElement?
        var lastLog = Date.distantPast
        while Date() < deadline {
            if let button = deletePromptButton(app) {
                deleteButton = button
                break
            }
            if keepGoing.exists {
                print("E2E: paused again; tapping Keep going")
                keepGoing.tap()
            }
            if app.staticTexts["Space freed"].exists || app.staticTexts["Nothing was shrunk"].exists
                || app.staticTexts["Copies saved, originals kept"].exists {
                break
            }
            if Date().timeIntervalSince(lastLog) > 30 {
                let progress = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Video '")).firstMatch
                print("E2E: waiting… \(progress.exists ? progress.label : "(no progress line)")")
                lastLog = Date()
            }
            sleep(2)
        }
        guard let deleteButton else {
            shot(app, "no-delete-prompt")
            print("E2E: screen at the end:\n\(app.debugDescription)")
            XCTFail("iOS never asked to delete the originals")
            return
        }
        let alert = [app, springboard].map { $0.alerts.firstMatch }.first { $0.exists }
        print("E2E: delete prompt: \(alert?.label ?? "?") / \(alert?.staticTexts.allElementsBoundByIndex.map(\.label) ?? [])")
        shot(app, "delete-prompt")
        deleteButton.tap()

        // 6. The result.
        let freed = app.staticTexts["Space freed"]
        if !freed.waitForExistence(timeout: 120) {
            shot(app, "result-failed")
            print("E2E: screen at the end:\n\(app.debugDescription)")
            XCTFail("\"Space freed\" never showed")
        }
        sleep(1)
        shot(app, "space-freed")
        let problems = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'couldn' OR label CONTAINS 'already about as small'"))
        for line in problems.allElementsBoundByIndex { print("E2E: result note: \(line.label)") }
        app.buttons["Done"].tap()
        sleep(3)
        shot(app, "home-after")
        app.terminate()

        // 7. What's in the library now.
        runHook("report", in: app)
    }

    // MARK: - Helpers

    /// Launches the app's Debug-only E2E hook and waits for it to finish, allowing Photos access if asked.
    private func runHook(_ mode: String, in app: XCUIApplication) {
        app.launchArguments = ["-e2e", mode]
        app.launch()
        let status = app.staticTexts["e2e-status"]
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            for label in ["Allow Full Access", "Allow Access to All Photos", "Allow"] {
                let allow = springboard.buttons[label]
                if allow.exists {
                    print("E2E: allowing Photos access (\(label))")
                    allow.tap()
                }
            }
            if status.exists, status.label.hasPrefix("E2E done") || status.label.hasPrefix("E2E failed") { break }
            sleep(1)
        }
        print("E2E: \(mode): \(status.exists ? status.label : "no status")")
        shot(app, "hook-\(mode)")
        XCTAssertTrue(status.exists && status.label.hasPrefix("E2E done"), "the \(mode) hook finished")
        app.terminate()
    }

    /// The Delete button of iOS's "Allow Shrink to delete…?" prompt, wherever iOS draws it.
    private func deletePromptButton(_ app: XCUIApplication) -> XCUIElement? {
        for owner in [app, springboard] {
            let button = owner.alerts.buttons["Delete"]
            if button.exists { return button }
        }
        return nil
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        shotNumber += 1
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["E2E_SHOTS"] else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent(String(format: "%02d-%@.png", shotNumber, name))
        try? screenshot.pngRepresentation.write(to: url)
    }
}
