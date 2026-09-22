import Foundation

public struct BridgeOrigin: Equatable, Sendable {
    public let scheme: String
    public let host: String
    public let port: Int

    public init(scheme: String, host: String, port: Int? = nil) {
        let normalizedScheme = scheme.lowercased()
        self.scheme = normalizedScheme
        self.host = host.lowercased()
        self.port = port ?? Self.defaultPort(for: normalizedScheme)
    }

    public init?(url: URL) {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        self.init(scheme: scheme, host: host, port: url.port)
    }

    private static func defaultPort(for scheme: String) -> Int {
        switch scheme {
        case "http": 80
        case "https": 443
        default: 0
        }
    }
}

public struct BridgeFrame: Equatable, Sendable {
    public let id: String
    public let origin: BridgeOrigin
    public let width: Int
    public let height: Int
    public let isVisible: Bool
    public let isMainFrame: Bool

    public init(
        id: String,
        origin: BridgeOrigin,
        width: Int,
        height: Int,
        isVisible: Bool,
        isMainFrame: Bool = false
    ) {
        self.id = id
        self.origin = origin
        self.width = width
        self.height = height
        self.isVisible = isVisible
        self.isMainFrame = isMainFrame
    }

    fileprivate var visibleArea: Int {
        isVisible ? width * height : 0
    }
}

public enum BridgeMessageKind: Hashable, Sendable {
    case ready
    case frameGone
    case theater
    case theaterEnded
    case theaterFailed
    case ended
    case watchCleanTapped
    case blocked
    case popupBlocked
    case playback
    case episodeSourceChanged
    case volume
    case time
    case video
    case tracks
    case airplay
    case airplaySupport
}

/// Bounds high-frequency reports from an untrusted page frame. Player control
/// messages remain event-driven; only `blocked` is intentionally chatty and
/// therefore subject to this fixed-window budget.
public struct BridgeRateLimiter: Sendable {
    private struct Window: Sendable {
        var startedAt: TimeInterval
        var accepted: Int
    }

    public let blockedLimit: Int
    public let interval: TimeInterval
    private var blockedWindows: [String: Window] = [:]

    public init(blockedLimit: Int = 60, interval: TimeInterval = 1) {
        precondition(blockedLimit > 0)
        precondition(interval > 0)
        self.blockedLimit = blockedLimit
        self.interval = interval
    }

    public mutating func allow(
        _ kind: BridgeMessageKind,
        from frameID: String,
        at now: TimeInterval
    ) -> Bool {
        guard kind == .blocked || kind == .popupBlocked else { return true }

        guard var window = blockedWindows[frameID],
              now - window.startedAt < interval
        else {
            blockedWindows[frameID] = Window(startedAt: now, accepted: 1)
            return true
        }

        guard window.accepted < blockedLimit else { return false }
        window.accepted += 1
        blockedWindows[frameID] = window
        return true
    }

    public mutating func remove(frameID: String) {
        blockedWindows.removeValue(forKey: frameID)
    }

    public mutating func reset() {
        blockedWindows.removeAll()
    }
}

public struct FrameCapabilityModel: Sendable {
    public private(set) var knownFrames: [String: BridgeFrame] = [:]
    public private(set) var playerFrameID: String?

    public init() {}

    public mutating func register(_ frame: BridgeFrame) {
        knownFrames[frame.id] = frame
    }

    /// Returns whether a message may mutate global player state. Ready and
    /// blocked reports are spectator-safe. Theater is the sole capability
    /// acquisition message; everything else is player-only.
    public mutating func authorize(
        _ kind: BridgeMessageKind,
        from frameID: String,
        mainOrigin: BridgeOrigin?
    ) -> Bool {
        switch kind {
        case .ready, .frameGone, .blocked, .popupBlocked, .watchCleanTapped:
            return true
        case .theater:
            if playerFrameID == frameID { return true }
            guard playerFrameID == nil,
                  let frame = knownFrames[frameID],
                  isEligiblePlayer(frame, mainOrigin: mainOrigin)
            else { return false }
            playerFrameID = frameID
            return true
        case .theaterEnded, .theaterFailed, .ended, .playback,
             .episodeSourceChanged, .volume, .time, .video, .tracks,
             .airplay, .airplaySupport:
            return playerFrameID == frameID
        }
    }

    /// Hand the player capability to a frame that proved itself elsewhere.
    ///
    /// The warm standby runs its own bridge while it is off screen, so its
    /// frames were never registered here. When it is promoted it IS the page,
    /// and without this every message from the frame now holding the video
    /// would be refused as a spectator — the chrome would go dead the moment
    /// an episode cut over.
    public mutating func adoptPlayer(_ frame: BridgeFrame) {
        knownFrames[frame.id] = frame
        playerFrameID = frame.id
    }

    public mutating func releasePlayer(frameID: String) {
        if playerFrameID == frameID { playerFrameID = nil }
    }

    @discardableResult
    public mutating func remove(frameID: String) -> Bool {
        knownFrames.removeValue(forKey: frameID)
        guard playerFrameID == frameID else { return false }
        playerFrameID = nil
        return true
    }

    public mutating func reset() {
        knownFrames.removeAll()
        playerFrameID = nil
    }

    private func isEligiblePlayer(
        _ frame: BridgeFrame,
        mainOrigin: BridgeOrigin?
    ) -> Bool {
        if frame.isMainFrame || frame.origin == mainOrigin { return true }
        guard frame.visibleArea > 0 else { return false }
        // The main document contains every iframe and normally fills the whole
        // viewport, so including it would make a cross-origin player
        // ineligible by construction. Embedded frames compete with peers.
        let largestVisibleArea = knownFrames.values
            .filter { !$0.isMainFrame }
            .map(\.visibleArea)
            .max() ?? 0
        return frame.visibleArea == largestVisibleArea
    }
}

public struct BlockedFrameRegistry: Equatable, Sendable {
    private var countsByFrame: [String: Int] = [:]

    public init() {}

    public var total: Int {
        countsByFrame.values.reduce(0, +)
    }

    public var frameIDs: [String] {
        countsByFrame.keys.sorted()
    }

    public mutating func update(frameID: String, count: Int) {
        countsByFrame[frameID] = count
    }

    public mutating func remove(frameID: String) {
        countsByFrame.removeValue(forKey: frameID)
    }

    public mutating func zeroAll() {
        for frameID in countsByFrame.keys {
            countsByFrame[frameID] = 0
        }
    }

    public mutating func reset() {
        countsByFrame.removeAll()
    }
}
