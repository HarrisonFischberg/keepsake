import XCTest

/// The M3.2 vertical slice: save → Library → open the save, on the Simulator.
final class SaveFlowTests: XCTestCase {
    /// A Chrome export made by the extension's own code (ios/tools/make-fixtures.mjs).
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../KeepsakeKit/Tests/KeepsakeKitTests/Fixtures/chrome-export.json").standardized.path

    override func setUp() { continueAfterFailure = false }

    func launch(seeded: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["KEEPSAKE_DB"] = "uitest-\(UUID().uuidString)"
        if seeded { app.launchArguments += ["-importOnLaunch", fixture] }
        app.launch()
        return app
    }

    func tab(_ app: XCUIApplication, _ name: String) {
        let button = app.tabBars.buttons[name]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
    }

    func card(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    func testOpenAPlaceAndStampIt() {
        let app = launch(seeded: true)
        tab(app, "Library")
        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Places,'")).firstMatch.tap()
        let place = card(app, "Café Azulejo")
        for _ in 0..<6 where !place.isHittable { app.swipeUp() }
        place.tap()
        XCTAssertTrue(app.buttons["Directions"].waitForExistence(timeout: 5), "a place's one primary action")
        let been = app.buttons["Been"]
        XCTAssertTrue(been.exists)
        been.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["Been, stamped"].waitForExistence(timeout: 3))
    }

    func testPasteALinkThenUndo() {
        let app = launch(seeded: false)
        tab(app, "Library")
        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 5))
        UIPasteboard.general.url = URL(string: "https://www.youtube.com/watch?v=abcdefghijk")
        let paste = app.buttons["Save the link you copied"]
        XCTAssertTrue(paste.waitForExistence(timeout: 3))
        paste.tap()
        XCTAssertTrue(app.staticTexts["Saved to Videos"].waitForExistence(timeout: 5), "Chrome's rule: anything on YouTube is a video")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Video'")).firstMatch.waitForExistence(timeout: 3))
        app.buttons["Undo"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Nothing saved yet'")).firstMatch.waitForExistence(timeout: 5))
    }

    func testSearchForgivesATypo() {
        let app = launch(seeded: true)
        tab(app, "Library")
        let search = app.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("lisbon")
        XCTAssertTrue(app.staticTexts["Showing results for “lisboa”"].waitForExistence(timeout: 5))
        XCTAssertTrue(card(app, "Café Azulejo").exists)
    }

    func testReviewShowsWhatNeedsACollection() {
        let app = launch(seeded: true)
        tab(app, "Library")
        let review = app.buttons["Review 1"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        review.tap()
        XCTAssertTrue(card(app, "Dutch oven").waitForExistence(timeout: 3))
        XCTAssertFalse(card(app, "Café Azulejo").exists)
    }
}
