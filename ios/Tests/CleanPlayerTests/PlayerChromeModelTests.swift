import XCTest
@testable import CleanPlayer

/// The rules the player chrome enforced with `@State` variables nothing could
/// see. Every one of these was real behaviour with a real reason before this
/// file existed — and none of it was asserted anywhere.
@MainActor
final class PlayerChromeModelTests: XCTestCase {

    /// Short enough that the whole suite stays fast, long enough that a
    /// cancelled task genuinely loses the race.
    private func makeModel() -> PlayerChromeModel {
        PlayerChromeModel(autoHide: .milliseconds(40),
                          flashFor: .milliseconds(40),
                          countdownFrom: 3,
                          countdownStep: .milliseconds(20))
    }

    /// Waits for a fixed period. Correct only for asserting that something
    /// did NOT happen — where a longer wait can only make the test stricter.
    private func settle(_ ms: UInt64 = 120) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    /// Waits until something becomes true, or gives up.
    ///
    /// The timers here are tens of milliseconds and the assertions used to sit
    /// behind a sleep of 120. That holds on a developer's machine and does not
    /// on CI, where this suite has been measured taking nine seconds to run a
    /// pure-logic assertion — the auto-hide task simply had not been scheduled
    /// yet, and the test reported the feature broken. A deadline this generous
    /// costs nothing when things are quick, because it returns the moment the
    /// condition holds.
    private func eventually(
        timeout: TimeInterval = 10,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: Auto-hide

    func testControlsHideThemselvesWhilePlaying() async {
        let chrome = makeModel()
        chrome.playbackChanged(isPlaying: true)
        XCTAssertTrue(chrome.areControlsVisible)

        let hid = await eventually { !chrome.areControlsVisible }
        XCTAssertTrue(hid, "controls never faded out during playback")
    }

    /// Hiding the controls on a paused video leaves a still frame the user
    /// cannot act on.
    func testControlsStayUpWhilePaused() async {
        let chrome = makeModel()
        chrome.playbackChanged(isPlaying: false)

        await settle()
        XCTAssertTrue(chrome.areControlsVisible,
                      "controls hid themselves on a paused video")
    }

    func testTapTogglesTheControls() {
        let chrome = makeModel()
        XCTAssertTrue(chrome.areControlsVisible)
        chrome.tapped()
        XCTAssertFalse(chrome.areControlsVisible)
        chrome.tapped()
        XCTAssertTrue(chrome.areControlsVisible)
    }

    // MARK: Lock

    /// A locked player has to stay unlockable, so a tap reveals the padlock
    /// rather than toggling everything away.
    func testTapOnALockedPlayerOnlyRevealsThePadlock() {
        let chrome = makeModel()
        chrome.lock()
        chrome.tapped()
        XCTAssertTrue(chrome.areControlsVisible)
        chrome.tapped()
        XCTAssertTrue(chrome.areControlsVisible,
                      "a second tap hid the only way to unlock")
        XCTAssertTrue(chrome.isLocked)
    }

    func testUnlockingBringsTheControlsBack() {
        let chrome = makeModel()
        chrome.lock()
        chrome.unlock()
        XCTAssertFalse(chrome.isLocked)
        XCTAssertTrue(chrome.areControlsVisible)
    }

    // MARK: Up next

    func testFinishingOffersTheNextItem() async {
        let chrome = makeModel()
        chrome.playbackEnded(hasNext: true)
        XCTAssertEqual(chrome.countdown, 3)

        var advanced = false
        chrome.onAdvance = { advanced = true }
        let finished = await eventually { advanced }
        XCTAssertTrue(finished, "the countdown never advanced")
        XCTAssertNil(chrome.countdown)
    }

    /// The distinction the whole thing rests on: an ordinary pause is not the
    /// end of the video and must not offer anything.
    func testPausingDoesNotOfferTheNextItem() async {
        let chrome = makeModel()
        chrome.playbackChanged(isPlaying: false)
        await settle()
        XCTAssertNil(chrome.countdown)
    }

    func testNothingIsOfferedWhenThereIsNoNextItem() {
        let chrome = makeModel()
        chrome.playbackEnded(hasNext: false)
        XCTAssertNil(chrome.countdown, "counted down to nowhere")
    }

    /// Declining is remembered, so replaying the last few seconds does not ask
    /// again.
    func testDecliningIsRememberedForThatItem() {
        let chrome = makeModel()
        chrome.playbackEnded(hasNext: true)
        chrome.declineNext()
        XCTAssertNil(chrome.countdown)

        chrome.playbackEnded(hasNext: true)
        XCTAssertNil(chrome.countdown, "asked again after being told no")
    }

    /// ...but a new item is a new video, and has nothing to do with what was
    /// declined on the last one.
    func testANewItemClearsTheDecline() {
        let chrome = makeModel()
        chrome.playbackEnded(hasNext: true)
        chrome.declineNext()

        chrome.itemChanged()
        chrome.playbackEnded(hasNext: true)
        XCTAssertEqual(chrome.countdown, 3,
                       "the previous item's decline suppressed this one")
    }

    /// Seeking back out of the end retracts the offer rather than navigating
    /// away from a video the user just resumed.
    func testResumingCancelsTheCountdown() async {
        let chrome = makeModel()
        var advanced = false
        chrome.onAdvance = { advanced = true }

        chrome.playbackEnded(hasNext: true)
        chrome.playbackChanged(isPlaying: true)
        XCTAssertNil(chrome.countdown)

        await settle(200)
        XCTAssertFalse(advanced, "navigated away from a resumed video")
    }

    func testTakingTheOfferAdvancesImmediately() {
        let chrome = makeModel()
        var advanced = 0
        chrome.onAdvance = { advanced += 1 }

        chrome.playbackEnded(hasNext: true)
        chrome.acceptNext()
        XCTAssertEqual(advanced, 1)
        XCTAssertNil(chrome.countdown)
    }

    /// The controls must not fade out from under a card that is about to
    /// navigate.
    func testControlsStayUpWhileTheCountdownRuns() async {
        let chrome = makeModel()
        chrome.playbackChanged(isPlaying: true)
        chrome.playbackEnded(hasNext: true)

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(chrome.areControlsVisible,
                      "the up-next card faded out from under itself")
    }

    // MARK: Scrubbing

    func testDraggingHoldsTheTargetAndCommitsItOnRelease() {
        let chrome = makeModel()
        var seeks: [Double] = []
        var begun = 0
        chrome.onSeek = { seeks.append($0) }
        chrome.onBeginScrub = { begun += 1 }

        chrome.scrubBegan()
        chrome.scrubMoved(to: 12)
        chrome.scrubMoved(to: 34)
        XCTAssertEqual(chrome.scrubTarget, 34)
        XCTAssertTrue(chrome.isScrubbing)

        chrome.scrubEnded()
        XCTAssertEqual(seeks, [34])
        XCTAssertEqual(begun, 1, "begin fired more than once for one drag")
        XCTAssertNil(chrome.scrubTarget)
        XCTAssertFalse(chrome.isScrubbing)
    }

    /// A drag that never moved still has to clear the flag. The engine
    /// suppresses position reporting while scrubbing, so a stuck flag silences
    /// the seek bar for the rest of the video — the same bug the page agent
    /// had.
    func testADragThatNeverMovedStillEndsTheScrub() {
        let chrome = makeModel()
        var seeks: [Double] = []
        chrome.onSeek = { seeks.append($0) }

        chrome.scrubBegan()
        chrome.scrubEnded()
        XCTAssertFalse(chrome.isScrubbing, "scrubbing stayed on after release")
        XCTAssertTrue(seeks.isEmpty, "committed a seek that never happened")
    }

    func testControlsDoNotHideMidDrag() async {
        let chrome = makeModel()
        chrome.playbackChanged(isPlaying: true)
        chrome.scrubBegan()

        await settle()
        XCTAssertTrue(chrome.areControlsVisible,
                      "the controls hid while the user was dragging them")
    }

    // MARK: Flash

    func testTheSeekFlashClearsItself() async {
        let chrome = makeModel()
        chrome.flashSeek(-10)
        XCTAssertEqual(chrome.seekFlash, -10)

        let cleared = await eventually { chrome.seekFlash == nil }
        XCTAssertTrue(cleared, "the seek flash never cleared itself")
    }

    /// Two quick double-taps: the first one's timer must not clear the second
    /// one's label early.
    func testASecondFlashReplacesTheFirstRatherThanRacingIt() async {
        let chrome = makeModel()
        chrome.flashSeek(-10)
        try? await Task.sleep(for: .milliseconds(30))
        chrome.flashSeek(10)

        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(chrome.seekFlash, 10,
                       "the first flash's timer cleared the second one")
    }

    // MARK: Teardown

    func testCancellingStopsEverythingInFlight() async {
        let chrome = makeModel()
        var advanced = false
        chrome.onAdvance = { advanced = true }

        chrome.playbackChanged(isPlaying: true)
        chrome.flashSeek(10)
        chrome.playbackEnded(hasNext: true)
        chrome.cancelEverything()

        await settle(200)
        XCTAssertFalse(advanced, "a cancelled countdown still navigated")
    }
}
