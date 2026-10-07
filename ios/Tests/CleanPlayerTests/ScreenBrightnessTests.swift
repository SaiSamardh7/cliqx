import XCTest
@testable import CleanPlayer

/// A player that dims the screen has to give it back, and must not fight a
/// change the user made themselves while it was open.
@MainActor
final class ScreenBrightnessTests: XCTestCase {
    private var level: CGFloat = 0.5

    override func setUp() {
        super.setUp()
        level = 0.5
        ScreenBrightness.read = { [self] in level }
        ScreenBrightness.write = { [self] in level = $0 }
        ScreenBrightness.restore()      // no carried-over entry value
    }

    override func tearDown() {
        ScreenBrightness.read = { UIScreen.main.brightness }
        ScreenBrightness.write = { UIScreen.main.brightness = $0 }
        super.tearDown()
    }

    func testRestoresWhatThePlayerFound() {
        ScreenBrightness.set(0.1)
        XCTAssertEqual(level, 0.1, accuracy: 0.001)
        XCTAssertTrue(ScreenBrightness.restore())
        XCTAssertEqual(level, 0.5, accuracy: 0.001)
    }

    func testKeepsTheFirstValueAcrossSeveralChanges() {
        ScreenBrightness.set(0.3)
        ScreenBrightness.set(0.2)
        ScreenBrightness.restore()
        XCTAssertEqual(level, 0.5, accuracy: 0.001)
    }

    /// Control Centre, mid-film. That is the user's choice, not ours to undo.
    func testLeavesAChangeTheUserMade() {
        ScreenBrightness.set(0.2)
        level = 0.9
        XCTAssertFalse(ScreenBrightness.restore())
        XCTAssertEqual(level, 0.9, accuracy: 0.001)
    }

    func testRestoringWithoutHavingSetAnythingDoesNothing() {
        XCTAssertFalse(ScreenBrightness.restore())
        XCTAssertEqual(level, 0.5, accuracy: 0.001)
    }

    func testClampsToTheScreensRange() {
        ScreenBrightness.set(1.4)
        XCTAssertEqual(level, 1, accuracy: 0.001)
        ScreenBrightness.set(-0.3)
        XCTAssertEqual(level, 0, accuracy: 0.001)
    }
}
