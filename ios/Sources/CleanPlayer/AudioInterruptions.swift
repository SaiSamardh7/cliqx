import AVFoundation
import Foundation

/// Phone calls, alarms, Siri, and headphones being pulled out.
///
/// Neither is optional behaviour for a media app. iOS pauses the audio for an
/// interruption but tells nobody, so a player that does not listen comes back
/// showing "playing" over silence with its scrubber frozen. And an unplugged
/// pair of headphones is the one route change with a rule attached: every
/// Apple media app pauses, because continuing means the video starts playing
/// out loud in a quiet room.
public final class AudioInterruptions {
    public enum Event: Equatable, Sendable {
        /// Something took the session. Pause, and remember whether you were
        /// playing.
        case began
        /// The interruption ended. `shouldResume` is iOS saying the other app
        /// has finished with it; when false, staying paused is correct.
        case ended(shouldResume: Bool)
        /// The route lost the device the sound was going to — headphones out,
        /// Bluetooth away. Always pause.
        case outputDeviceLost
    }

    private var observers: [NSObjectProtocol] = []
    private let centre: NotificationCenter

    public init(centre: NotificationCenter = .default) {
        self.centre = centre
    }

    deinit { stop() }

    /// `handler` runs on the main queue, because everything it will touch is
    /// player state.
    public func start(_ handler: @escaping (Event) -> Void) {
        stop()
        observers = [
            centre.addObserver(forName: AVAudioSession.interruptionNotification,
                               object: nil, queue: .main) { note in
                guard let event = Self.interruption(from: note.userInfo) else { return }
                // iOS took the session to give it to whatever interrupted, and
                // says nothing when that is over. A player that resumes without
                // claiming it back calls play() into a session it no longer
                // owns: the button moves, the scrubber runs, and no sound comes
                // out — which is most of "I came back to the app and it was
                // dead". Claimed here rather than in each of the four engines
                // that handle this event, because all four need it and none of
                // them did it.
                if case .ended = event { MediaSession.activate() }
                handler(event)
            },
            centre.addObserver(forName: AVAudioSession.routeChangeNotification,
                               object: nil, queue: .main) { note in
                guard Self.isOutputDeviceLost(note.userInfo) else { return }
                handler(.outputDeviceLost)
            },
        ]
    }

    public func stop() {
        for observer in observers { centre.removeObserver(observer) }
        observers.removeAll()
    }

    /// Pure, so the mapping can be tested without an audio session.
    public static func interruption(from userInfo: [AnyHashable: Any]?) -> Event? {
        guard let raw = userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return nil }
        switch type {
        case .began:
            return .began
        case .ended:
            let options = (userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            return .ended(shouldResume: options.contains(.shouldResume))
        @unknown default:
            return nil
        }
    }

    /// Only `oldDeviceUnavailable` means the sound lost its destination. A new
    /// device arriving, or a category change, is not a reason to pause.
    public static func isOutputDeviceLost(_ userInfo: [AnyHashable: Any]?) -> Bool {
        guard let raw = userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        else { return false }
        return reason == .oldDeviceUnavailable
    }
}

/// What a player should do about an interruption, and the single piece of
/// state that decision needs.
///
/// Four players carried this rule: three VLC engines holding byte-identical
/// copies, and the web coordinator holding the same logic spelled with
/// `togglePlay`. A rule copied four times is a rule nobody can change, and
/// none of the four copies was reachable from a test — the engines need a
/// decoder and an audio session to exist at all.
///
/// Pure, so the rule itself is checkable: it answers what to do and leaves
/// doing it to whoever owns the player.
public struct InterruptionPolicy {
    public enum Response: Equatable, Sendable {
        case pause
        case resume
        case nothing
    }

    /// Whether the player was running when something took the session. The
    /// whole reason this type holds state: resuming is only offered to a video
    /// that was actually playing.
    private var wasPlaying = false

    public init() {}

    public mutating func response(to event: AudioInterruptions.Event,
                                  isPlaying: Bool) -> Response {
        switch event {
        case .began:
            wasPlaying = isPlaying
            return isPlaying ? .pause : .nothing
        case .ended(let shouldResume):
            // `shouldResume` is iOS saying the other app has finished with the
            // session. Without it, staying paused is correct.
            guard shouldResume, wasPlaying, !isPlaying else { return .nothing }
            wasPlaying = false
            return .resume
        case .outputDeviceLost:
            // Headphones out. Always pause, and never offer to resume: the
            // alternative is the film playing out loud in a quiet room.
            wasPlaying = false
            return isPlaying ? .pause : .nothing
        }
    }
}
