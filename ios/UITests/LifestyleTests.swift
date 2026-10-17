import XCTest

/// M3.3: Places by state with Places review, cooking mode, workout goals and check-ins.
final class LifestyleTests: XCTestCase {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../KeepsakeKit/Tests/KeepsakeKitTests/Fixtures/chrome-export.json").standardized.path

    override func setUp() { continueAfterFailure = false }

    func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["KEEPSAKE_DB"] = "uitest-\(UUID().uuidString)"
        app.launchArguments += ["-importOnLaunch", fixture]
        app.launch()
        return app
    }

    func open(_ app: XCUIApplication, kind chip: String, save title: String) {
        app.tabBars.buttons["Library"].tap()
        let chipButton = app.buttons[chip]
        XCTAssertTrue(chipButton.waitForExistence(timeout: 5))
        chipButton.tap()
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 3))
        card.tap()
    }

    func testLibraryGroupsCollectionsThenLifestyle() {
        let app = launch()
        app.tabBars.buttons["Library"].tap()
        let collections = app.staticTexts["Collections"], lifestyle = app.staticTexts["Lifestyle"]
        XCTAssertTrue(collections.waitForExistence(timeout: 5) && lifestyle.exists)
        XCTAssertLessThan(collections.frame.minY, lifestyle.frame.minY, "Collections sits above Lifestyle")
        app.buttons["Collection Clothing"].tap()
        XCTAssertTrue(app.buttons["Collection Clothing"].isSelected, "a collection is a chip too")
        app.buttons["All"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Workouts,'")).firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Push-up ladder'")).firstMatch.waitForExistence(timeout: 3))
    }

    func testPlacesReviewFixMovesItToItsState() {
        let app = launch()
        app.tabBars.buttons["Places"].tap()
        XCTAssertTrue(app.staticTexts["Portugal"].waitForExistence(timeout: 5), "Café Azulejo, by country")
        app.buttons["Review 1"].tap()
        XCTAssertTrue(app.staticTexts["Needs a state or country"].waitForExistence(timeout: 3))
        app.buttons["Fix Ramen Kiri"].tap()
        let region = app.textFields["State or region"]
        XCTAssertTrue(region.waitForExistence(timeout: 3))
        region.tap(); region.typeText("Tokyo")
        let country = app.textFields["Country"]
        country.tap(); country.typeText("Japan")
        app.buttons["Save"].tap()
        app.buttons["List"].tap()
        XCTAssertTrue(app.staticTexts["Japan"].waitForExistence(timeout: 5), "now listed under its country")
        XCTAssertTrue(app.buttons["List"].exists)
    }

    func testCookingStepByStep() {
        let app = launch()
        open(app, kind: "Recipes", save: "Brown butter pasta")
        app.buttons["Start cooking"].tap()
        XCTAssertTrue(app.staticTexts["Step 1 of 3"].waitForExistence(timeout: 3))
        app.buttons["Next step"].tap()
        app.buttons["Next step"].tap()
        XCTAssertTrue(app.staticTexts["Step 3 of 3"].waitForExistence(timeout: 3))
        app.buttons["Mark as cooked"].tap()
        XCTAssertTrue(app.buttons["Cooked, stamped"].waitForExistence(timeout: 5))
    }

    func testWorkoutGoalAndCheckIn() {
        let app = launch()
        open(app, kind: "Workouts", save: "Push-up ladder")
        XCTAssertTrue(app.staticTexts["Push-ups 3×12 rest 60s"].waitForExistence(timeout: 5), "Chrome's formatExercise")
        app.buttons["Make it a goal"].tap()
        app.buttons["Start the goal"].tap()
        XCTAssertTrue(app.staticTexts["0 of 3 this week · week 1 of 4"].waitForExistence(timeout: 5))
        app.buttons["Done today"].press(forDuration: 0.8)
        XCTAssertTrue(app.staticTexts["1 of 3 this week · week 1 of 4"].waitForExistence(timeout: 5))
        app.buttons["Undo"].tap()
        XCTAssertTrue(app.staticTexts["0 of 3 this week · week 1 of 4"].waitForExistence(timeout: 5))
    }

    func testHomeShowsReviewAndLifestyle() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["1 save needs a collection"].waitForExistence(timeout: 5))
        // Collections first, then Lifestyle: each folded into one row that opens its page.
        let collections = app.buttons["Collections"], lifestyle = app.buttons["Lifestyle"]
        XCTAssertTrue(collections.exists && lifestyle.exists)
        XCTAssertLessThan(collections.frame.minY, lifestyle.frame.minY, "Collections sits above Lifestyle")
        lifestyle.tap()
        XCTAssertTrue(app.buttons["Places, 2 saves"].waitForExistence(timeout: 3))
        app.buttons["Recipes, 2 saves"].tap()
        XCTAssertTrue(app.staticTexts["Recipes"].waitForExistence(timeout: 3))
    }
}
