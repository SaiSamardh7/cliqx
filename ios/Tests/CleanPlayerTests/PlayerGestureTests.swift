import XCTest
@testable import CleanPlayer

@MainActor
final class PlayerGestureTests: XCTestCase {
    func testGesturePreferencesDefaultToEnabled() {
        let store = UserDefaults(suiteName: #function)!
        store.removePersistentDomain(forName: #function)

        let settings = PlayerGestureSettings(store: store)

        XCTAssertTrue(settings.doubleTapPlayPause)
        XCTAssertTrue(settings.swipeSeeking)
        XCTAssertTrue(settings.brightnessAndVolume)
        XCTAssertTrue(settings.temporaryFastForward)
        XCTAssertTrue(settings.swipeToDismiss)
    }

    func testGesturePreferencesPersist() {
        let store = UserDefaults(suiteName: #function)!
        store.removePersistentDomain(forName: #function)
        let settings = PlayerGestureSettings(store: store)
        settings.swipeSeeking = false
        settings.temporaryFastForward = false

        let restored = PlayerGestureSettings(store: store)

        XCTAssertFalse(restored.swipeSeeking)
        XCTAssertFalse(restored.temporaryFastForward)
        XCTAssertTrue(restored.doubleTapPlayPause)
    }

    func testHorizontalDragBecomesSeek() {
        XCTAssertEqual(
            PlayerGestureClassifier.classify(dx: 90, dy: 12, startXFraction: 0.3),
            .seek
        )
    }

    func testVerticalDragUsesStartingHalf() {
        XCTAssertEqual(
            PlayerGestureClassifier.classify(dx: 8, dy: -80, startXFraction: 0.25),
            .brightness
        )
        XCTAssertEqual(
            PlayerGestureClassifier.classify(dx: 8, dy: 80, startXFraction: 0.75),
            .volume
        )
    }

    func testSmallDragStaysUnclaimedAndDiagonalUsesWholeSideZone() {
        XCTAssertNil(PlayerGestureClassifier.classify(dx: 9, dy: 8, startXFraction: 0.2))
        XCTAssertEqual(
            PlayerGestureClassifier.classify(dx: 50, dy: 45, startXFraction: 0.2),
            .brightness
        )
        XCTAssertEqual(
            PlayerGestureClassifier.classify(dx: -45, dy: 50, startXFraction: 0.8),
            .volume
        )
    }

    func testDownwardDragCanDismissButUpwardCannot() {
        XCTAssertTrue(PlayerGestureClassifier.shouldDismiss(dx: 20, dy: 130))
        XCTAssertFalse(PlayerGestureClassifier.shouldDismiss(dx: 20, dy: -130))
        XCTAssertFalse(PlayerGestureClassifier.shouldDismiss(dx: 100, dy: 100))
    }

    func testLongDownwardSideGesturesNeverBecomeDismissals() {
        let oneInchOnIPhone15Pro = 180.0
        XCTAssertEqual(
            PlayerGestureClassifier.classify(
                dx: 4, dy: oneInchOnIPhone15Pro, startXFraction: 0.2),
            .brightness
        )
        XCTAssertEqual(
            PlayerGestureClassifier.classify(
                dx: 4, dy: oneInchOnIPhone15Pro, startXFraction: 0.8),
            .volume
        )
        XCTAssertEqual(
            PlayerGestureClassifier.classify(
                dx: 4, dy: oneInchOnIPhone15Pro, startXFraction: 0.5),
            .dismiss
        )
    }

    func testSeekDeltaIsBounded() {
        XCTAssertEqual(PlayerGestureClassifier.seekDelta(dx: 500, width: 300), 90)
        XCTAssertEqual(PlayerGestureClassifier.seekDelta(dx: -500, width: 300), -90)
        XCTAssertEqual(PlayerGestureClassifier.seekDelta(dx: 150, width: 300), 45)
    }
}
