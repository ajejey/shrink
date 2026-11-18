import XCTest

/// Clean up photos from start to finish on the simulator's real Photos library, the way a person does
/// it. The app's Debug hook (E2EPhotos.swift) adds a camera photo, a picture saved from a chat, the same
/// picture twice (one a favorite, one in an album) and a Live Photo (a favorite with a place, in an
/// album). The test keeps the pre-picked duplicate, turns the Live Photo into a still, answers iOS's
/// delete prompt, then the hook reports the library and scripts/check-cleanup-e2e.mjs checks it.
///
/// Screenshots go to the folder in TEST_RUNNER_E2E_SHOTS.
final class PhotoCleanupE2ETests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private var shotNumber = 0

    override func setUp() {
        continueAfterFailure = false
    }

    func testCleanUpPhotosOnARealPhotosLibrary() throws {
        let app = XCUIApplication()

        // 1. Add the test photos and record the library.
        runHook("prepare-photos", in: app)

        // 2. Home → Clean up photos.
        app.launchArguments = []
        app.launch()
        let seePhotos = app.buttons["See the photos"]
        XCTAssertTrue(seePhotos.waitForExistence(timeout: 90), "Home's Clean up photos part")
        sleep(3)
        shot(app, "home")
        seePhotos.tap()

        // 3. The closer look finds the duplicates last (their row shows "Looking…" until then).
        let found = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'extra cop'")).firstMatch
        if !found.waitForExistence(timeout: 300) {
            shot(app, "no-duplicates-found")
            print("E2E: piles screen:\n\(app.debugDescription)")
            XCTFail("the closer look never found the duplicate")
            return
        }
        guard let duplicates = waitForRow("Duplicates", in: app, timeout: 10) else {
            shot(app, "no-duplicates")
            print("E2E: piles screen:\n\(app.debugDescription)")
            XCTFail("the Duplicates pile never showed")
            return
        }
        sleep(2)
        shot(app, "piles")
        print("E2E: piles: \(app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))")
        duplicates.tap()
        sleep(2)
        shot(app, "duplicates")
        goBack(app)

        // 4. Live Photos: keep just the photo.
        guard let live = waitForRow("Live Photos", in: app, timeout: 10) else {
            shot(app, "no-live-photos")
            XCTFail("the Live Photos pile never showed (did the hook make a real Live Photo?)")
            return
        }
        live.tap()
        let tile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Photo, '")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 15), "the Live Photo's tile")
        tile.tap()
        sleep(1)
        shot(app, "live-picked")

        // 5. Check, then clean up.
        app.buttons["Next"].tap()
        let cleanUp = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Clean up '")).firstMatch
        XCTAssertTrue(cleanUp.waitForExistence(timeout: 15), "the check screen's button")
        shot(app, "check")
        print("E2E: tapping \"\(cleanUp.label)\"")
        cleanUp.tap()

        // 6. iOS's delete prompt (after the still is saved and checked).
        var deleteButton: XCUIElement?
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if let button = deletePromptButton(app) {
                deleteButton = button
                break
            }
            if app.staticTexts["Space freed"].exists || app.staticTexts["Nothing was deleted"].exists
                || app.staticTexts["Nothing was cleaned up"].exists {
                break
            }
            sleep(1)
        }
        guard let deleteButton else {
            shot(app, "no-delete-prompt")
            print("E2E: screen at the end:\n\(app.debugDescription)")
            XCTFail("iOS never asked to delete")
            return
        }
        let alert = [app, springboard].map { $0.alerts.firstMatch }.first { $0.exists }
        print("E2E: delete prompt: \(alert?.label ?? "?") / \(alert?.staticTexts.allElementsBoundByIndex.map(\.label) ?? [])")
        shot(app, "delete-prompt")
        deleteButton.tap()

        // 7. The result.
        let freed = app.staticTexts["Space freed"]
        if !freed.waitForExistence(timeout: 60) {
            shot(app, "result-failed")
            print("E2E: screen at the end:\n\(app.debugDescription)")
            XCTFail("\"Space freed\" never showed")
        }
        sleep(1)
        shot(app, "space-freed")
        print("E2E: result: \(app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))")
        app.buttons["Done"].tap()
        sleep(3)
        shot(app, "home-after")
        app.terminate()

        // 8. What's in the library now.
        runHook("report-photos", in: app)
    }

    // MARK: - Helpers

    /// A pile's row on the piles screen, found by its title.
    private func waitForRow(_ title: String, in app: XCUIApplication, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastLog = Date()
        while Date() < deadline {
            let text = app.staticTexts[title]
            if text.exists { return text }
            let button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
            if button.exists { return button }
            if Date().timeIntervalSince(lastLog) > 30 {
                let progress = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Taking a closer look'")).firstMatch
                print("E2E: waiting for \(title)… \(progress.exists ? progress.label : "")")
                lastLog = Date()
            }
            sleep(1)
        }
        return nil
    }

    private func goBack(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        sleep(1)
    }

    /// Launches the app's Debug-only E2E hook and waits for it to finish, allowing Photos access if asked.
    private func runHook(_ mode: String, in app: XCUIApplication) {
        app.launchArguments = ["-e2e", mode]
        app.launch()
        let status = app.staticTexts["e2e-status"]
        // Saving the Live Photo takes the simulator's Photos about two minutes.
        let deadline = Date().addingTimeInterval(420)
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
