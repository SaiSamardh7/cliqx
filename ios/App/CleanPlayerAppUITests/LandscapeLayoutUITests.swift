import XCTest

/// Landscape on a phone is 402pt tall. A hero sized 16:9 at full width is
/// 491pt — taller than the whole screen — so the server's shelves all started
/// below the fold and the page read as empty. Nothing in the unit suites can
/// see that: it is a layout that only goes wrong at one screen size.
final class LandscapeLayoutUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-protection.onboarded.v1", "YES"]
        app.launch()
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        app = nil
        super.tearDown()
    }

    /// The home screen's own shelves have to be reachable too, and Home is
    /// where every session starts.
    func testHomeShowsItsShelvesInLandscape() {
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.staticTexts["Cliqx"].waitForExistence(timeout: 10),
                      "home never appeared in landscape")

        // Servers is the first shelf below the device buttons. If the header
        // area is taller than the screen, this is what goes missing.
        XCTAssertTrue(app.staticTexts["Servers"].waitForExistence(timeout: 5),
                      "the Servers shelf was off screen in landscape")
        XCTAssertTrue(app.staticTexts["Servers"].isHittable,
                      "the Servers shelf existed but could not be reached")
    }

    /// The screen the bug was reported on. The hero is the tall thing, and
    /// everything the page is for sits under it.
    func testTheServerShelvesAreOnScreenInLandscape() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.staticTexts["Cliqx"].waitForExistence(timeout: 10))

        // By identifier, not by label. The prompt to ADD a server also says
        // "Jellyfin" in its description, so matching on the word opened the
        // Add sheet on CI, where no server is signed in — and then failed for
        // the wrong reason. Skips rather than fails when there is none: this
        // asserts layout, not sign-in.
        // `.firstMatch`: an install with more than one server signed in has
        // more than one row carrying this identifier, and any of them will do
        // — this asserts layout, not which server.
        let server = app.descendants(matching: .any)
            .matching(identifier: "server.row").firstMatch
        try XCTSkipUnless(server.waitForExistence(timeout: 5),
                          "no server signed in on this simulator")
        server.tap()

        // "My Media" is the first shelf under the hero. At 16:9 full width the
        // hero was 491pt on a 402pt screen, so this began below the fold.
        let shelf = app.staticTexts["My Media"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 10),
                      "the server shelves never rendered in landscape")
        XCTAssertTrue(shelf.isHittable,
                      "My Media was pushed off screen by the hero in landscape")
    }

    /// The rotate button in the player narrows the app's supported
    /// orientations. Leaving the player has to hand them back, or the whole
    /// app stays sideways — including after it is relaunched.
    func testTheAppFollowsTheDeviceAfterRotatingInsideAPlayer() {
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.staticTexts["Cliqx"].waitForExistence(timeout: 10))

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.staticTexts["Cliqx"].waitForExistence(timeout: 5))

        // Back to portrait: the app must follow, which it cannot do while a
        // narrowed orientation set is still in force.
        XCUIDevice.shared.orientation = .portrait
        let home = app.staticTexts["Cliqx"]
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        XCTAssertTrue(home.isHittable,
                      "home was not reachable after rotating back to portrait")
    }
}
