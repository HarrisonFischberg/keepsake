import XCTest

/// M3.4: Review filing, collections, settings consent, export.
final class OrganiseTests: XCTestCase {
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

    func testFileFromReviewIntoACollection() {
        let app = launch()
        let banner = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '1 save needs a collection'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        banner.tap()
        let suggestion = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'File in'")).firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5), "three suggestions from the categorizer")
        let name = suggestion.label.replacingOccurrences(of: "File in ", with: "")
        suggestion.tap()
        XCTAssertTrue(app.staticTexts["Filed in \(name)"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Nothing waiting. Everything has a home."].waitForExistence(timeout: 5))
    }

    /// Real photos (the demo library): a tall photo's hidden overflow must not take the filter chip's tap.
    func testFilterChipsWorkAboveCardsWithPhotos() {
        let demo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../demo/keepsake-demo.json").standardized.path
        let app = XCUIApplication()
        app.launchEnvironment["KEEPSAKE_DB"] = "uitest-\(UUID().uuidString)"
        app.launchArguments += ["-importOnLaunch", demo]
        app.launch()
        app.tabBars.buttons["Library"].tap()
        // The Library opens on its stacks; Products lays the saves out, photos and all.
        let products = app.scrollViews.buttons["Products"].firstMatch
        XCTAssertTrue(products.waitForExistence(timeout: 10))
        products.tap()
        let coffee = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Glass pour-over'")).firstMatch
        XCTAssertTrue(coffee.waitForExistence(timeout: 10))
        sleep(2)   // pictures load
        for chip in ["Places", "Recipes"] {
            app.scrollViews.buttons[chip].firstMatch.tap()
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Saved from'")).firstMatch.waitForExistence(timeout: 1.5), "\(chip): a card opened instead of the filter")
            XCTAssertTrue(app.scrollViews.buttons[chip].firstMatch.isSelected, "\(chip) chip is selected")
            XCTAssertFalse(coffee.exists, "\(chip): the product is filtered out")
            products.tap()
            XCTAssertTrue(coffee.waitForExistence(timeout: 3))
        }
    }

    func testLookupsAskFirst() {
        let app = launch()
        app.buttons["Settings"].tap()
        let places = app.switches["Places: OpenStreetMap"]
        XCTAssertTrue(places.waitForExistence(timeout: 5))
        XCTAssertEqual(places.value as? String, "0", "off by default")
        places.switches.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Look up places on OpenStreetMap?"].waitForExistence(timeout: 3))
        app.buttons["Not now"].tap()
        XCTAssertEqual(app.switches["Places: OpenStreetMap"].value as? String, "0", "still off after Not now")
    }

    func testCollectionsListShopping() {
        let app = launch()
        app.buttons["Collections"].tap()
        XCTAssertTrue(app.staticTexts["For things to buy"].waitForExistence(timeout: 5))
    }

    func card(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    func testSelectSeveralAndMove() {
        let app = launch()
        app.tabBars.buttons["Library"].tap()
        app.buttons["More"].tap()
        app.buttons["Select"].tap()
        card(app, "Push-up ladder").tap()
        card(app, "The case for slow cities").tap()
        app.buttons["Move to…"].tap()
        app.buttons["Clothing"].tap()
        XCTAssertTrue(app.staticTexts["Moved 2 saves to Clothing"].waitForExistence(timeout: 5))
    }

    func testFilterPurchased() {
        let app = launch()
        app.tabBars.buttons["Library"].tap()
        let filter = app.buttons["Filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.tap()
        app.buttons["Purchased"].tap()
        XCTAssertTrue(card(app, "Linen apron").waitForExistence(timeout: 3))
        XCTAssertFalse(card(app, "Café Azulejo").exists)
        app.buttons["Remove filter Purchased"].tap()
        XCTAssertTrue(card(app, "Push-up ladder").waitForExistence(timeout: 3))
    }
}
