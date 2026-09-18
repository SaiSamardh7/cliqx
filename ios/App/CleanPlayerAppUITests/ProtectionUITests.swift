import XCTest

/// The rule this project keeps failing: a passing test on a component no user
/// can reach counts for zero. These drive the real app through the real
/// screens, so anything that stops being reachable fails here.
final class ProtectionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        // A clean install every time: onboarding is shown once, so a leftover
        // flag from a previous run would silently skip half of this.
        app.launchArguments = ["-protection.onboarded.v1", "NO"]
        app.launch()
    }

    private func finishOnboarding() {
        let skip = app.buttons["Skip"]
        if skip.waitForExistence(timeout: 5) { skip.tap() }
    }

    /// Scrolls until a row exists. A SwiftUI Form renders lazily, so a row
    /// below the fold does not merely fail to be hittable — it does not exist
    /// yet, and `.exists` is false.
    @discardableResult
    private func scrollToRow(_ label: String) -> Bool {
        for _ in 0..<8 {
            if app.staticTexts[label].exists { return true }
            app.swipeUp()
        }
        return app.staticTexts[label].exists
    }

    /// A row in a SwiftUI Form is not reliably a button — a NavigationLink can
    /// surface as its label's static text — and the About section sits below
    /// the fold. Scroll to it, then tap whichever element actually exists.
    private func tapRow(_ label: String, file: StaticString = #filePath,
                        line: UInt = #line) {
        for _ in 0..<8 {
            let button = app.buttons[label]
            if button.exists && button.isHittable { button.tap(); return }
            let text = app.staticTexts[label]
            if text.exists && text.isHittable { text.tap(); return }
            app.swipeUp()
        }
        XCTFail("never found a tappable row labelled \(label)", file: file, line: line)
    }

    func testOnboardingAppearsAndCanBeCompleted() {
        XCTAssertTrue(app.staticTexts["A browser for watching"]
            .waitForExistence(timeout: 5), "onboarding never appeared")
        finishOnboarding()
        XCTAssertTrue(app.staticTexts["Cliqx"].waitForExistence(timeout: 5),
                      "skipping onboarding did not reach the home screen")
    }

    /// Protection has to be visible, and it has to say it is on. A silent
    /// failure here is the whole reason the status exists.
    func testSettingsReportsProtectionActive() {
        finishOnboarding()
        app.buttons["Settings"].tap()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        // Compiling EasyList on a cold container takes a while; the readout
        // moves from Preparing to Active on its own.
        let active = app.staticTexts["Active"]
        XCTAssertTrue(active.waitForExistence(timeout: 90),
                      "protection never reported Active")
    }

    func testAttributionIsReachableFromSettings() {
        finishOnboarding()
        app.buttons["Settings"].tap()
        tapRow("Attribution and licences")

        // A CC BY-SA obligation, not a nicety: this screen has to exist and be
        // reachable for the shipped rule data to be redistributable.
        XCTAssertTrue(app.staticTexts["EasyList"].waitForExistence(timeout: 5),
                      "attribution screen does not name its sources")
        XCTAssertTrue(scrollToRow("Public Suffix List"),
                      "the bundled security-boundary data is not attributed in-app")
    }

    func testPrivacyPolicyIsReachableFromSettings() {
        finishOnboarding()
        app.buttons["Settings"].tap()
        tapRow("Privacy policy")

        XCTAssertTrue(app.staticTexts["The short version"]
            .waitForExistence(timeout: 5), "privacy policy is not reachable")
    }

    func testFilterListsAreListedWithTheirRuleCounts() {
        finishOnboarding()
        app.buttons["Settings"].tap()

        // All four shipped lists, each reached by scrolling — the Form renders
        // lazily and only the first two or three fit on screen.
        for list in ["Cliqx rules", "Fanboy's Annoyance",
                     "EasyList", "EasyPrivacy"] {
            XCTAssertTrue(scrollToRow(list), "\(list) is not listed in Settings")
        }
    }

    /// Brave's 944 compatibility exceptions are compiled INTO every shipped
    /// list, so their MPL-2.0 attribution obligation is live — the app ships
    /// the rule data, not just a build tool that touched it. The attribution
    /// string existed in `FilterSource.braveUnbreak` and reached no screen,
    /// because `FilterSource.all` does not contain it.
    func testCompiledInExceptionsAreAttributed() {
        finishOnboarding()
        app.buttons["Settings"].tap()
        tapRow("Attribution and licences")

        XCTAssertTrue(scrollToRow("Brave Unbreak"),
                      "the shipped MPL-2.0 rule data is not attributed in-app")
        // The obligation is the credit line itself, not the heading above it.
        XCTAssertTrue(scrollToRow("Site-compatibility exceptions from Brave "
                                  + "Unbreak (github.com/brave/adblock-lists), "
                                  + "used under MPL-2.0."),
                      "the MPL-2.0 attribution text is not shown")
    }

    /// Strict is a real superset of Standard, so choosing it must leave
    /// protection reporting Active on a larger set — not degraded, and not
    /// stuck on Preparing. This is the path that recompiles and re-attaches.
    func testChoosingStrictKeepsProtectionActive() {
        finishOnboarding()
        app.buttons["Settings"].tap()

        let active = app.staticTexts["Active"]
        XCTAssertTrue(active.waitForExistence(timeout: 90),
                      "protection never reported Active at the default level")

        app.buttons["Strict"].tap()
        XCTAssertTrue(active.waitForExistence(timeout: 120),
                      "protection did not come back to Active on Strict")
        XCTAssertFalse(app.staticTexts["Limited"].exists,
                       "switching to Strict left protection degraded")
    }

    /// Private browsing is a promise about what touches the disk. The control
    /// has to be reachable and has to hold its state, because the web view is
    /// rebuilt from it and a data store cannot be swapped on a live one.
    func testPrivateBrowsingTogglesAndSticks() {
        finishOnboarding()
        app.buttons["Settings"].tap()

        XCTAssertTrue(scrollToRow("Private browsing"),
                      "private browsing is not reachable in Settings")
        let toggle = app.switches["Private browsing"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))

        let before = toggle.value as? String
        // A Form row's switch does not reliably take a tap at the cell centre;
        // the control itself is at the trailing edge.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()

        // SwiftUI republishes on the next runloop pass, so poll rather than
        // reading the value straight back.
        var changed = false
        for _ in 0..<20 where !changed {
            if (toggle.value as? String) != before { changed = true; break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(changed, "the private browsing toggle did not change state")
    }
}
