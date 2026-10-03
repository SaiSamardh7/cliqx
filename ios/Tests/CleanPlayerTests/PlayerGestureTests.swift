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

    // MARK: Volume ceiling

    func testBoostIsOfferedWhenNoRouteCouldCarryTheVideo() {
        XCTAssertEqual(
            PlayerVolume.ceiling(current: 100, airplayCouldSendVideo: false), 200)
        XCTAssertEqual(PlayerVolume.levels(upTo: 200), PlayerVolume.levels)
    }

    /// Amplifying routes the element through Web Audio and a routed element
    /// cannot follow AirPlay, so the television would get the picture and no
    /// sound.
    func testBoostIsWithheldWhileARouteCouldCarryTheVideo() {
        XCTAssertEqual(
            PlayerVolume.ceiling(current: 100, airplayCouldSendVideo: true), 100)
        XCTAssertEqual(PlayerVolume.levels(upTo: 100), [0, 25, 50, 75, 100])
    }

    /// The routing is irreversible for the element's lifetime, so once it has
    /// happened there is nothing left to protect. Withholding the level the
    /// video is already playing at would only leave the menu showing a
    /// selection that none of its rows carry.
    func testAnAlreadyBoostedVideoKeepsTheLevelsItIsUsing() {
        XCTAssertEqual(
            PlayerVolume.ceiling(current: 150, airplayCouldSendVideo: true), 200)
        XCTAssertTrue(PlayerVolume.levels(upTo: 200).contains(150))
    }

    /// The bug this closes: the menu withheld boost and the vertical drag did
    /// not, so a swipe could amplify past a ceiling the menu was refusing to
    /// offer — breaking AirPlay by the one route that skipped the check.
    func testTheDragCannotAmplifyPastTheMenusCeiling() {
        let ceiling = PlayerVolume.ceiling(current: 100,
                                           airplayCouldSendVideo: true)
        XCTAssertEqual(PlayerVolume.clamp(180, to: ceiling), 100)
        XCTAssertEqual(PlayerVolume.clamp(-40, to: ceiling), 0)
        XCTAssertEqual(PlayerVolume.clamp(75, to: ceiling), 75)
    }
}
