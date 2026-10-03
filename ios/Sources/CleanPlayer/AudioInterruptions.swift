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
