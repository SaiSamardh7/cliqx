import Foundation

/// The player chrome's own state machine: what is on screen, what is locked,
/// what the scrubber is holding, and whether the next item is counting down.
///
/// Pulled out of `PlayerOverlay` because none of it was reachable from a test.
/// The overlay only exists in theater, theater needs a real video, and the UI
/// tests have no network — so every rule below was enforced by a `@State`
/// variable nothing could inspect. They are real rules with real reasons, and
/// each one is now asserted:
///
/// - Controls auto-hide only while something is playing. Hiding them on a
///   paused video leaves a still frame the user cannot act on.
/// - A locked player reveals the padlock and nothing else, or a pocket can
///   seek.
/// - Only *finishing* offers the next item. An ordinary pause must not.
/// - Declining the next item is remembered for that video, so replaying the
///   last few seconds does not ask again — but a new item clears it.
///
/// Durations are injected so tests do not sleep for three and a half seconds.
@MainActor
public final class PlayerChromeModel: ObservableObject {
    @Published public private(set) var areControlsVisible = true
    @Published public private(set) var isLocked = false

    /// Non-nil only while a drag is in flight. The engine keeps reporting its
    /// own position, and without holding the target the thumb jumps back out
    /// from under the finger.
    @Published public private(set) var scrubTarget: Double?
    @Published public private(set) var isScrubbing = false

    /// Briefly shown after a double-tap, so the gesture has a visible result.
    @Published public private(set) var seekFlash: Double?

    /// Seconds left on the up-next countdown; nil when it is not running.
    @Published public private(set) var countdown: Int?

    /// Dismissed for this item once the user says no.
    private var declinedNext = false

    private let autoHide: Duration
    private let flashFor: Duration
    private let countdownStep: Duration

    /// What the countdown starts from. Public because the ring drawn around it
    /// needs the same number to compute its fraction — two copies drift.
    public let countdownFrom: Int

    private var hideTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?

    /// Fired when the countdown runs out, or the user takes the offer.
    public var onAdvance: () -> Void = {}
    /// Fired when a drag ends, with where it ended.
    public var onSeek: (Double) -> Void = { _ in }
    /// Fired when a drag begins, so the engine can stop reporting position.
    public var onBeginScrub: () -> Void = {}

    public init(autoHide: Duration = .seconds(3.5),
                flashFor: Duration = .seconds(0.6),
                countdownFrom: Int = 5,
                countdownStep: Duration = .seconds(1)) {
        self.autoHide = autoHide
        self.flashFor = flashFor
        self.countdownFrom = countdownFrom
        self.countdownStep = countdownStep
    }

    // MARK: Visibility

    /// A single tap. On a locked player this reveals the padlock and nothing
    /// else — the player still has to be unlockable.
    public func tapped() {
        if isLocked {
            areControlsVisible = true
        } else {
            areControlsVisible.toggle()
        }
        scheduleHide()
    }

    public func lock() {
        isLocked = true
        areControlsVisible = true
        scheduleHide()
    }

    public func unlock() {
        isLocked = false
        areControlsVisible = true
        scheduleHide()
    }

    /// Any deliberate action keeps the controls up for another full interval.
    public func interacted() {
        areControlsVisible = true
        scheduleHide()
    }

    /// Only auto-hides while something is actually playing.
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = nil
        guard areControlsVisible, isPlaying, !isCountingDown else { return }
        hideTask = Task { [autoHide] in
            try? await Task.sleep(for: autoHide)
            guard !Task.isCancelled else { return }
            self.areControlsVisible = false
        }
    }

    private var isPlaying = false
    private var isCountingDown: Bool { countdown != nil }

    // MARK: Playback signals

    public func playbackChanged(isPlaying playing: Bool) {
        isPlaying = playing
        // Resuming retracts a countdown: the video is no longer finished.
        if playing { stopCountdown(declined: false) }
        scheduleHide()
    }

    /// Playback finished. `hasNext` is what decides whether there is anything
    /// to offer — the countdown must not run to nowhere.
    public func playbackEnded(hasNext: Bool) {
        guard hasNext, !declinedNext else { return }
        countdownTask?.cancel()
        countdown = countdownFrom
        // The controls must not fade out from under a card about to navigate.
        hideTask?.cancel()
        hideTask = nil
        areControlsVisible = true

        countdownTask = Task { [countdownFrom, countdownStep] in
            for remaining in stride(from: countdownFrom - 1, through: 0, by: -1) {
                try? await Task.sleep(for: countdownStep)
                guard !Task.isCancelled else { return }
                self.countdown = remaining
            }
            guard !Task.isCancelled else { return }
            self.countdown = nil
            self.onAdvance()
        }
    }

    /// A new item is a new video: whatever was declined last time has nothing
    /// to do with this one.
    public func itemChanged() {
        declinedNext = false
        stopCountdown(declined: false)
    }

    /// The user took the offer.
    public func acceptNext() {
        stopCountdown(declined: false)
        onAdvance()
    }

    /// The user said no. Not asked again for this item.
    public func declineNext() {
        stopCountdown(declined: true)
    }

    private func stopCountdown(declined: Bool) {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
        if declined { declinedNext = true }
    }

    // MARK: Scrubbing

    public func scrubBegan() {
        guard !isScrubbing else { return }
        isScrubbing = true
        hideTask?.cancel()
        hideTask = nil
        onBeginScrub()
    }

    public func scrubMoved(to seconds: Double) {
        scrubTarget = seconds
    }

    /// Ends the drag and commits it. A drag that produced no target — a tap on
    /// the bar that never moved — still has to clear the flag, or position
    /// reporting stays suppressed for the rest of the video.
    public func scrubEnded() {
        if let scrubTarget { onSeek(scrubTarget) }
        scrubTarget = nil
        isScrubbing = false
        scheduleHide()
    }

    // MARK: Flash

    public func flashSeek(_ seconds: Double) {
        seekFlash = seconds
        flashTask?.cancel()
        flashTask = Task { [flashFor] in
            try? await Task.sleep(for: flashFor)
            guard !Task.isCancelled else { return }
            self.seekFlash = nil
        }
    }

    // MARK: Teardown

    /// Every timer this object owns. One outliving the view writes state on
    /// something that is gone.
    public func cancelEverything() {
        hideTask?.cancel(); hideTask = nil
        flashTask?.cancel(); flashTask = nil
        countdownTask?.cancel(); countdownTask = nil
    }
}
