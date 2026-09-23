import UIKit
import XCTest
@testable import CleanPlayer

/// The player's rotate button called `requestGeometryUpdate(.landscape)`, which
/// does not turn the screen so much as REPLACE what the app supports. The scene
/// then stopped following the device, and stayed landscape after the player
/// closed, because nothing restored the original set.
final class InterfaceOrientationPolicyTests: XCTestCase {
    func testPhonePlistNamesBecomeAMask() {
        let mask = InterfaceOrientationPolicy.mask(from: [
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight",
        ])
        XCTAssertTrue(mask.contains(.portrait))
        XCTAssertTrue(mask.contains(.landscapeLeft))
        XCTAssertTrue(mask.contains(.landscapeRight))
        XCTAssertFalse(mask.contains(.portraitUpsideDown))
    }

    /// An iPad declares upside down and a phone does not, which is why this is
    /// read rather than hard-coded.
    func testPadPlistNamesIncludeUpsideDown() {
        let mask = InterfaceOrientationPolicy.mask(from: [
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight",
        ])
        XCTAssertTrue(mask.contains(.portraitUpsideDown))
    }

    func testEmptyOrUnknownFallsBackRatherThanLockingTheApp() {
        XCTAssertEqual(InterfaceOrientationPolicy.mask(from: []), .allButUpsideDown)
        XCTAssertEqual(InterfaceOrientationPolicy.mask(from: ["nonsense"]), .allButUpsideDown)
    }

    func testUnknownNamesAreIgnoredButKnownOnesSurvive() {
        let mask = InterfaceOrientationPolicy.mask(from: [
            "nonsense", "UIInterfaceOrientationPortrait",
        ])
        XCTAssertEqual(mask, .portrait)
    }

    func testTheKeyDiffersByIdiom() {
        XCTAssertEqual(InterfaceOrientationPolicy.plistKey(for: .pad),
                       "UISupportedInterfaceOrientations~ipad")
        XCTAssertEqual(InterfaceOrientationPolicy.plistKey(for: .phone),
                       "UISupportedInterfaceOrientations")
    }

    func testFlippedAsksForTheOtherOne() {
        XCTAssertEqual(InterfaceOrientationPolicy.flipped(from: .portrait), .landscape)
        XCTAssertEqual(InterfaceOrientationPolicy.flipped(from: .landscapeLeft), .portrait)
        XCTAssertEqual(InterfaceOrientationPolicy.flipped(from: .landscapeRight), .portrait)
    }

    /// The restore has to be a SET, not one orientation: restoring to a single
    /// value would leave the app locked, just to a different side.
    func testDeclaredIsMoreThanOneOrientation() {
        let mask = InterfaceOrientationPolicy.mask(from: [
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight",
        ])
        XCTAssertNotEqual(mask, .portrait)
        XCTAssertNotEqual(mask, .landscape)
    }
}

// MARK: - Coming back from a forced orientation

extension InterfaceOrientationPolicyTests {
    /// The inversion that is silent when wrong: a device rotated LEFT presents
    /// a RIGHT-hand landscape interface. Swap these and the screen still
    /// rotates, just to the upside-down version of what the user wanted.
    func testDeviceOrientationMapsToTheOppositeLandscape() {
        XCTAssertEqual(InterfaceOrientationPolicy.mask(matching: .landscapeLeft),
                       .landscapeRight)
        XCTAssertEqual(InterfaceOrientationPolicy.mask(matching: .landscapeRight),
                       .landscapeLeft)
        XCTAssertEqual(InterfaceOrientationPolicy.mask(matching: .portrait), .portrait)
        XCTAssertEqual(InterfaceOrientationPolicy.mask(matching: .portraitUpsideDown),
                       .portraitUpsideDown)
    }

    /// Flat on a table says nothing about how it is being held.
    func testUnreadableDeviceOrientationsHaveNoTarget() {
        XCTAssertNil(InterfaceOrientationPolicy.mask(matching: .faceUp))
        XCTAssertNil(InterfaceOrientationPolicy.mask(matching: .faceDown))
        XCTAssertNil(InterfaceOrientationPolicy.mask(matching: .unknown))
    }

    private var phoneMask: UIInterfaceOrientationMask {
        InterfaceOrientationPolicy.mask(from: [
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight",
        ])
    }

    func testRestoreTargetPrefersTheDevicesOwnOrientation() {
        XCTAssertEqual(
            InterfaceOrientationPolicy.restoreTarget(
                device: .portrait, before: .landscapeLeft, allowed: phoneMask),
            .portrait)
        XCTAssertEqual(
            InterfaceOrientationPolicy.restoreTarget(
                device: .landscapeLeft, before: .portrait, allowed: phoneMask),
            .landscapeRight)
    }

    /// The case that made this necessary. A phone flat on a table reports
    /// faceUp and a simulator reports unknown — and "no answer" meant the app
    /// stayed in whatever orientation the rotate button chose, which is the
    /// bug. Falling back to where the interface was before the button is the
    /// honest answer to "put it back".
    func testUnreadableDeviceFallsBackToWhereItWasBefore() {
        for device: UIDeviceOrientation in [.faceUp, .faceDown, .unknown] {
            XCTAssertEqual(
                InterfaceOrientationPolicy.restoreTarget(
                    device: device, before: .portrait, allowed: phoneMask),
                .portrait,
                "\(device) should fall back")
        }
    }

    /// A phone declares no upside down, so lying on your back with the phone
    /// inverted must not rotate the app somewhere the app does not support.
    func testRestoreTargetRefusesAnOrientationTheAppDoesNotAllow() {
        XCTAssertNil(InterfaceOrientationPolicy.restoreTarget(
            device: .portraitUpsideDown, before: nil, allowed: phoneMask))
    }

    /// Nothing readable and nothing remembered: leave the interface alone
    /// rather than guessing portrait and turning the screen under someone.
    func testRestoreTargetIsNilWithNothingToGoOn() {
        XCTAssertNil(InterfaceOrientationPolicy.restoreTarget(
            device: .faceUp, before: nil, allowed: .allButUpsideDown))
    }
}
