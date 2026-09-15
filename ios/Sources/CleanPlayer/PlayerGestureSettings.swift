import Foundation

/// On-device, user-controlled gesture preferences. These contain no browsing
/// data and never leave the app's UserDefaults container.
@MainActor
public final class PlayerGestureSettings: ObservableObject {
    @Published public var doubleTapPlayPause: Bool {
        didSet { store.set(doubleTapPlayPause, forKey: Keys.doubleTapPlayPause) }
    }
    @Published public var swipeSeeking: Bool {
        didSet { store.set(swipeSeeking, forKey: Keys.swipeSeeking) }
    }
    @Published public var brightnessAndVolume: Bool {
        didSet { store.set(brightnessAndVolume, forKey: Keys.brightnessAndVolume) }
    }
    @Published public var temporaryFastForward: Bool {
        didSet { store.set(temporaryFastForward, forKey: Keys.temporaryFastForward) }
    }
    @Published public var swipeToDismiss: Bool {
        didSet { store.set(swipeToDismiss, forKey: Keys.swipeToDismiss) }
    }

    private enum Keys {
        static let doubleTapPlayPause = "player.gesture.doubleTapPlayPause.v1"
        static let swipeSeeking = "player.gesture.swipeSeeking.v1"
        static let brightnessAndVolume = "player.gesture.brightnessAndVolume.v1"
        static let temporaryFastForward = "player.gesture.temporaryFastForward.v1"
        static let swipeToDismiss = "player.gesture.swipeToDismiss.v1"
    }

    private let store: UserDefaults

    public init(store: UserDefaults = .standard) {
        self.store = store
        doubleTapPlayPause = store.object(forKey: Keys.doubleTapPlayPause) as? Bool ?? true
        swipeSeeking = store.object(forKey: Keys.swipeSeeking) as? Bool ?? true
        brightnessAndVolume = store.object(forKey: Keys.brightnessAndVolume) as? Bool ?? true
        temporaryFastForward = store.object(forKey: Keys.temporaryFastForward) as? Bool ?? true
        swipeToDismiss = store.object(forKey: Keys.swipeToDismiss) as? Bool ?? true
    }
}

public enum PlayerDragAction: Equatable {
    case seek
    case brightness
    case volume
}

/// Pure gesture arbitration kept outside SwiftUI so edge cases are testable.
public enum PlayerGestureClassifier {
    public static func classify(dx: Double, dy: Double,
                                startXFraction: Double) -> PlayerDragAction? {
        let horizontal = abs(dx)
        let vertical = abs(dy)
        guard max(horizontal, vertical) >= 18 else { return nil }

        if horizontal >= vertical * 1.35 { return .seek }
        if vertical >= horizontal * 1.35 {
            return startXFraction < 0.5 ? .brightness : .volume
        }
        return nil
    }

    public static func shouldDismiss(dx: Double, dy: Double) -> Bool {
        dy >= 120 && abs(dy) >= abs(dx) * 1.35
    }

    /// A full-width drag seeks 90 seconds, with the same limit beyond the edge.
    public static func seekDelta(dx: Double, width: Double) -> Double {
        guard width > 0 else { return 0 }
        return min(max((dx / width) * 90, -90), 90)
    }
}
