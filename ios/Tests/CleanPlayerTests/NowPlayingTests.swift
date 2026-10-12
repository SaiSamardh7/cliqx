import MediaPlayer
import XCTest
@testable import CleanPlayer

/// The decisions behind the lock-screen card. `NowPlayingController` itself
/// talks to MediaPlayer and cannot be observed from a test, so everything with
/// a judgement in it lives in these two functions.
final class NowPlayingTests: XCTestCase {

    private func snapshot(title: String = "A Film", playing: Bool = true,
                          at time: Double = 10, duration: Double = 100,
                          rate: Double = 1, live: Bool = false) -> NowPlayingSnapshot {
        NowPlayingSnapshot(title: title, isPlaying: playing, currentTime: time,
                           duration: duration, rate: rate, isLive: live)
    }

    // MARK: - The card

    func testCarriesTitleElapsedAndDuration() {
        let info = NowPlayingInfo.dictionary(for: snapshot())
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "A Film")
        XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 10)
        XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double, 100)
    }

    func testPausedReportsRateZero() {
        // The lock-screen clock runs off this. Sending the intended rate while
        // paused leaves it counting up on a video that is not moving.
        let info = NowPlayingInfo.dictionary(for: snapshot(playing: false, rate: 1))
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
    }

    func testPlayingAtDoubleSpeedReportsTheRealRate() {
        let info = NowPlayingInfo.dictionary(for: snapshot(rate: 2))
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 2)
    }

    func testLiveStreamIsMarkedLiveAndCarriesNoDuration() {
        // A live stream with a length draws a progress bar that fills up and
        // then lies about what is left.
        let info = NowPlayingInfo.dictionary(for: snapshot(duration: 100, live: true))
        XCTAssertEqual(info[MPNowPlayingInfoPropertyIsLiveStream] as? Bool, true)
        XCTAssertNil(info[MPMediaItemPropertyPlaybackDuration])
    }

    func testUnknownDurationIsOmittedRatherThanSentAsZero() {
        // Normal before metadata lands. Zero would render as a 0:00 track.
        let info = NowPlayingInfo.dictionary(for: snapshot(duration: 0))
        XCTAssertNil(info[MPMediaItemPropertyPlaybackDuration])
    }

    // MARK: - When to rewrite it

    func testFirstSnapshotAlwaysWrites() {
        XCTAssertTrue(NowPlayingInfo.needsRefresh(from: nil, to: snapshot()))
    }

    func testOrdinaryTickDoesNotWrite() {
        // The whole point: the system extrapolates the clock from the rate, so
        // a position tick four times a second needs no write at all.
        let before = snapshot(at: 10)
        let after = snapshot(at: 10.25)
        XCTAssertFalse(NowPlayingInfo.needsRefresh(from: before, to: after))
    }

    func testAnHourOfTicksNeverWrites() {
        // The test that was missing. Comparing each tick against the last
        // snapshot WRITTEN rather than the one before it looks correct on a
        // single pair and rewrites the card every couple of seconds forever;
        // that shipped briefly and showed up as a write every 2.3s in the
        // simulator log. Only a run proves the difference.
        var previous = snapshot(at: 0)
        for tick in 1...14_400 {                 // four ticks a second, an hour
            let next = snapshot(at: Double(tick) * 0.25)
            XCTAssertFalse(NowPlayingInfo.needsRefresh(from: previous, to: next),
                           "rewrote the card at \(next.currentTime)s of steady playback")
            previous = next
        }
    }

    func testSeekIsStillCaughtInARunOfTicks() {
        // The flip side: the run above must not pass by making needsRefresh
        // blind to real movement.
        var previous = snapshot(at: 0)
        for tick in 1...100 {
            previous = snapshot(at: Double(tick) * 0.25)
        }
        let skipped = snapshot(at: previous.currentTime + PlayerSkip.interval)
        XCTAssertTrue(NowPlayingInfo.needsRefresh(from: previous, to: skipped))
    }

    func testSeekWrites() {
        let before = snapshot(at: 10)
        let after = snapshot(at: 95)
        XCTAssertTrue(NowPlayingInfo.needsRefresh(from: before, to: after))
    }

    func testSeekBackwardsWrites() {
        // abs(), not a subtraction that only notices going forwards.
        XCTAssertTrue(NowPlayingInfo.needsRefresh(from: snapshot(at: 95),
                                                  to: snapshot(at: 10)))
    }

    func testPauseWrites() {
        XCTAssertTrue(NowPlayingInfo.needsRefresh(from: snapshot(playing: true),
                                                  to: snapshot(playing: false)))
    }

    func testRateChangeWrites() {
        XCTAssertTrue(NowPlayingInfo.needsRefresh(from: snapshot(rate: 1),
                                                  to: snapshot(rate: 1.5)))
    }

    func testDurationArrivingWrites() {
        // Duration is 0 until VLC has parsed the media; the card is wrong
        // until the real length replaces it.
        XCTAssertTrue(NowPlayingInfo.needsRefresh(from: snapshot(duration: 0),
                                                  to: snapshot(duration: 100)))
    }

    func testNextEpisodeWrites() {
        // Same player, new title: the commonest way for a stale card to
        // outlive what it describes.
        XCTAssertTrue(NowPlayingInfo.needsRefresh(from: snapshot(title: "Episode 1"),
                                                  to: snapshot(title: "Episode 2")))
    }

    func testGoingLiveWrites() {
        XCTAssertTrue(NowPlayingInfo.needsRefresh(from: snapshot(live: false),
                                                  to: snapshot(live: true)))
    }

    // MARK: - Skip

    func testSkipIntervalIsTheOneTheOnScreenButtonsUse() {
        // PlayerOverlay's buttons read this too. A lock screen that jumps a
        // different distance from the app is its own small bug.
        XCTAssertEqual(PlayerSkip.interval, 10)
    }
}
