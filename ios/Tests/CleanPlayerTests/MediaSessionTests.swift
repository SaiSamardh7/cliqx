import AVFoundation
import XCTest
@testable import CleanPlayer

/// `.playback` interrupts whatever else was making sound. Without a matching
/// deactivation the interruption never ends: a podcast paused when the user
/// opened a video stayed paused after they closed it, for the life of the
/// process. There was no `setActive(false)` anywhere in the app.
final class MediaSessionTests: XCTestCase {
    override func tearDown() {
        MediaSession.deactivate()
        super.tearDown()
    }

    func testActivateClaimsTheSession() {
        XCTAssertTrue(MediaSession.activate())
        XCTAssertTrue(MediaSession.active)
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
        XCTAssertEqual(AVAudioSession.sharedInstance().mode, .moviePlayback)
    }

    func testDeactivateReleasesIt() {
        MediaSession.activate()
        XCTAssertTrue(MediaSession.deactivate())
        XCTAssertFalse(MediaSession.active)
    }

    /// Every player calls this on the way out, including ones that never
    /// started, so it has to be a no-op rather than an error.
    func testDeactivateWithoutActivateIsHarmless() {
        MediaSession.deactivate()
        XCTAssertTrue(MediaSession.deactivate())
        XCTAssertFalse(MediaSession.active)
    }

    func testReactivationWorksAfterRelease() {
        MediaSession.activate()
        MediaSession.deactivate()
        XCTAssertTrue(MediaSession.activate())
        XCTAssertTrue(MediaSession.active)
    }
}
