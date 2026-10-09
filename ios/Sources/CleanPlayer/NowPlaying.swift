import Foundation
import MediaPlayer

/// What is playing, as the lock screen, Control Centre, a car head unit and a
/// pair of AirPods need to hear it.
///
/// Cliqx had the whole audio foundation and none of this: `MediaSession` sets
/// `.playback`, Info.plist declares the `audio` background mode, and
/// `AudioInterruptions` handles calls and route changes — so sound kept coming
/// out of a Bluetooth speaker with no title, no scrubber, and buttons that
/// reached nothing. iOS has nowhere to deliver a remote event unless an app
/// registers for it, and nothing to draw unless an app says what is playing.
///
/// Split in two on purpose. `NowPlayingSnapshot` and the two pure functions
/// below carry the logic and are unit-tested; `NowPlayingController` is the
/// thin part that talks to MediaPlayer, which no test can observe.

// MARK: - What is playing

/// Everything the system card needs, in plain values, so the three players can
/// each describe themselves without sharing a protocol they do not have.
public struct NowPlayingSnapshot: Equatable, Sendable {
    public var title: String
    public var isPlaying: Bool
    /// Seconds.
    public var currentTime: Double
    /// Seconds. Zero means unknown, which is normal before metadata lands.
    public var duration: Double
    public var rate: Double
    public var isLive: Bool

    public init(title: String = "", isPlaying: Bool = false,
                currentTime: Double = 0, duration: Double = 0,
                rate: Double = 1, isLive: Bool = false) {
        self.title = title
        self.isPlaying = isPlaying
        self.currentTime = currentTime
        self.duration = duration
        self.rate = rate
        self.isLive = isLive
    }
}

public enum NowPlayingInfo {
    /// How far the clock may drift from the card before it is rewritten.
    ///
    /// The system interpolates elapsed time from the rate, so an ordinary tick
    /// needs no write at all. Anything larger than a tick is a seek, and that
    /// does: the card would otherwise keep counting from where the video no
    /// longer is.
    static let seekTolerance: Double = 2

    /// The dictionary for `MPNowPlayingInfoCenter`.
    ///
    /// A live stream gets no duration: `MPNowPlayingInfoPropertyIsLiveStream`
    /// is what makes the system draw a live indicator instead of a scrubber,
    /// and handing it a length as well produces a progress bar that fills up
    /// and then lies.
    public static func dictionary(for snapshot: NowPlayingSnapshot) -> [String: Any] {
        // Zero is what stops the clock on the lock screen while paused.
        // Sending the intended rate instead leaves it ticking on a video that
        // is not moving.
        //
        // Annotated, not inferred. Written inline in a `[String: Any]` literal
        // the ternary has `Any` for context, so Swift boxes each branch on its
        // own and the paused case goes in as `Int` — which MediaPlayer ignores
        // and `as? Double` reads back as nil.
        let rate: Double = snapshot.isPlaying ? snapshot.rate : 0
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
        ]
        if snapshot.isLive {
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
        } else if snapshot.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = snapshot.duration
        }
        return info
    }

    /// Whether the card is now wrong.
    ///
    /// Called on every position tick, so the answer is usually no. Writing to
    /// `MPNowPlayingInfoCenter` four times a second is waste the system does
    /// not need: it extrapolates the clock from the rate it was last given,
    /// and only a change in that rate, in what is playing, or in where it is
    /// playing from requires telling it again.
    ///
    /// `previous` is the PRECEDING OBSERVATION, not the last snapshot written.
    /// Measured against the last write, ordinary playback drifts past the
    /// tolerance every couple of seconds and rewrites the card forever — which
    /// is what this did at first, visible in the log as a write every 2.3s.
    /// Between consecutive ticks the position moves a fraction of a second,
    /// and only a seek moves it further.
    public static func needsRefresh(from previous: NowPlayingSnapshot?,
                                    to next: NowPlayingSnapshot) -> Bool {
        guard let previous else { return true }
        if previous.title != next.title { return true }
        if previous.isPlaying != next.isPlaying { return true }
        if previous.rate != next.rate { return true }
        if previous.isLive != next.isLive { return true }
        if previous.duration != next.duration { return true }
        return abs(previous.currentTime - next.currentTime) > seekTolerance
    }
}

// MARK: - The system card and its buttons

@MainActor
public final class NowPlayingController {
    /// What a remote button does. Closures rather than a protocol because the
    /// three players conform to nothing in common, and giving them a shared
    /// one is a refactor this does not need to drag in.
    public struct Commands {
        public var play: () -> Void
        public var pause: () -> Void
        public var toggle: () -> Void
        /// Absolute position, seconds.
        public var seek: (Double) -> Void
        /// Relative, seconds, signed.
        public var skip: (Double) -> Void

        public init(play: @escaping () -> Void, pause: @escaping () -> Void,
                    toggle: @escaping () -> Void,
                    seek: @escaping (Double) -> Void,
                    skip: @escaping (Double) -> Void) {
            self.play = play
            self.pause = pause
            self.toggle = toggle
            self.seek = seek
            self.skip = skip
        }
    }

    /// Seconds a skip button moves. The same number the on-screen buttons
    /// use — see `PlayerSkip.interval`. A lock screen that jumps a different
    /// distance from the one in the app is its own small bug.
    private let skipInterval: Double
    /// The preceding observation, which is what a seek is measured against.
    /// Not the last snapshot written — see `needsRefresh`.
    private var lastObserved: NowPlayingSnapshot?
    private var started = false

    public init(skipInterval: Double = PlayerSkip.interval) {
        self.skipInterval = skipInterval
    }

    /// Claim the card and the buttons. Safe to call twice.
    public func begin(_ commands: Commands) {
        guard !started else { return }
        started = true
        let centre = MPRemoteCommandCenter.shared()

        centre.playCommand.isEnabled = true
        centre.playCommand.addTarget { _ in commands.play(); return .success }
        centre.pauseCommand.isEnabled = true
        centre.pauseCommand.addTarget { _ in commands.pause(); return .success }
        // What a single AirPods pinch and most steering-wheel buttons send.
        centre.togglePlayPauseCommand.isEnabled = true
        centre.togglePlayPauseCommand.addTarget { _ in commands.toggle(); return .success }

        centre.skipForwardCommand.isEnabled = true
        centre.skipForwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        centre.skipForwardCommand.addTarget { [skipInterval] _ in
            commands.skip(skipInterval); return .success
        }
        centre.skipBackwardCommand.isEnabled = true
        centre.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        centre.skipBackwardCommand.addTarget { [skipInterval] _ in
            commands.skip(-skipInterval); return .success
        }

        centre.changePlaybackPositionCommand.isEnabled = true
        centre.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            commands.seek(event.positionTime)
            return .success
        }
    }

    /// Tell the system where playback is, if it has moved somewhere the system
    /// could not have worked out for itself.
    public func update(_ snapshot: NowPlayingSnapshot) {
        guard started else { return }
        let previous = lastObserved
        lastObserved = snapshot
        guard NowPlayingInfo.needsRefresh(from: previous, to: snapshot) else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo =
            NowPlayingInfo.dictionary(for: snapshot)
    }

    /// Give the card back.
    ///
    /// Without this a finished video sits on the lock screen with a dead
    /// scrubber, and its buttons still answer — to a player that has gone.
    public func end() {
        guard started else { return }
        started = false
        lastObserved = nil
        let centre = MPRemoteCommandCenter.shared()
        for command: MPRemoteCommand in [
            centre.playCommand, centre.pauseCommand, centre.togglePlayPauseCommand,
            centre.skipForwardCommand, centre.skipBackwardCommand,
            centre.changePlaybackPositionCommand,
        ] {
            command.removeTarget(nil)
            command.isEnabled = false
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}

/// How far the skip controls move, in one place.
///
/// It was written as a literal `10` in three places in `PlayerOverlay` and
/// would have become a fourth here.
public enum PlayerSkip {
    public static let interval: Double = 10
}
