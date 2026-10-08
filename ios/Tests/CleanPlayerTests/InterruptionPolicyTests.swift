import XCTest
@testable import CleanPlayer

/// The rule four players used to carry a copy of each, none of them reachable
/// from a test.
final class InterruptionPolicyTests: XCTestCase {
    func testPausesWhatWasPlayingAndResumesItWhenToldTo() {
        var policy = InterruptionPolicy()
        XCTAssertEqual(policy.response(to: .began, isPlaying: true), .pause)
        XCTAssertEqual(policy.response(to: .ended(shouldResume: true), isPlaying: false),
                       .resume)
    }

    func testDoesNotResumeSomethingThatWasAlreadyPaused() {
        var policy = InterruptionPolicy()
        XCTAssertEqual(policy.response(to: .began, isPlaying: false), .nothing)
        XCTAssertEqual(policy.response(to: .ended(shouldResume: true), isPlaying: false),
                       .nothing)
    }

    /// iOS saying the other app is not finished. Staying paused is correct.
    func testStaysPausedWhenNotToldToResume() {
        var policy = InterruptionPolicy()
        XCTAssertEqual(policy.response(to: .began, isPlaying: true), .pause)
        XCTAssertEqual(policy.response(to: .ended(shouldResume: false), isPlaying: false),
                       .nothing)
    }

    /// Headphones pulled out: pause, and never offer to resume afterwards.
    func testLosingTheOutputNeverResumes() {
        var policy = InterruptionPolicy()
        XCTAssertEqual(policy.response(to: .began, isPlaying: true), .pause)
        XCTAssertEqual(policy.response(to: .outputDeviceLost, isPlaying: true), .pause)
        XCTAssertEqual(policy.response(to: .ended(shouldResume: true), isPlaying: false),
                       .nothing)
    }

    /// The user pressed play themselves while the interruption was up.
    func testLeavesAPlayerTheUserRestartedAlone() {
        var policy = InterruptionPolicy()
        XCTAssertEqual(policy.response(to: .began, isPlaying: true), .pause)
        XCTAssertEqual(policy.response(to: .ended(shouldResume: true), isPlaying: true),
                       .nothing)
    }
}
