import Foundation

/// What the player chrome needs from whatever is actually playing.
///
/// `PlayerOverlay` already talks to playback through a flat set of closures —
/// `togglePlay`, `seek`, `skip`, `setRate`, `selectTrack`, `togglePiP`. That is
/// a player protocol written by accident, and everything in it except overlay
/// blocking and theater staging is true of any video, not just a `<video>`
/// inside a web page. This makes the boundary explicit so a second engine can
/// sit behind the same chrome.
///
/// Three things are deliberately NOT here, because they are web-only and
/// belong to the browser rather than to playback: hiding ad overlays, staging
/// the page around the video, and the curtain held across an episode change.

// MARK: - Values

/// A selectable option — a subtitle track, or a quality variant.
///
/// The id is an index into whatever the source is offering, never a URL or a
/// label round-tripped back to the source. That rule comes from the web path,
/// where sending page text back across the bridge would be a script injection
/// into our own content world, and it costs nothing to keep everywhere.
public struct MediaTrack: Identifiable, Equatable, Sendable {
    public let id: Int
    public let label: String
    public let isActive: Bool

    public init(id: Int, label: String, isActive: Bool) {
        self.id = id
        self.label = label
        self.isActive = isActive
    }
}

/// `contain` shows the whole frame with bars; `cover` fills the screen and
/// crops. `fill` is deliberately absent — it distorts, and users read that as
/// a bug rather than as a setting.
public enum VideoFit: String, Sendable, CaseIterable {
    case contain
    case cover

    public var toggled: VideoFit { self == .cover ? .contain : .cover }
}

/// One entry in whatever comes next — an episode on a site, a file in a
/// folder, a track in a queue.
public struct PlaylistItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let isCurrent: Bool

    public init(id: String, label: String, isCurrent: Bool) {
        self.id = id
        self.label = label
        self.isCurrent = isCurrent
    }
}

// MARK: - State

/// Everything the chrome reads. Separated from `PageState`, which currently
/// holds browser concerns (host, TLS, back/forward, blocked counts) and
/// playback concerns in one object — only the second half means anything to a
/// local file.
@MainActor
public final class PlaybackState: ObservableObject {
    @Published public var isPlaying = false
    @Published public var currentTime: Double = 0

    /// 0 both for a live stream and before metadata arrives. `isLive` is what
    /// separates them: only one of those deserves a LIVE badge.
    @Published public var duration: Double = 0
    @Published public var isLive = false
    @Published public var bufferedTo: Double = 0

    /// The rate the user asked for, which is not the same as the engine's
    /// current rate: AVPlayer reports 0 while paused, and showing "0×" in the
    /// speed menu because someone hit pause would be wrong.
    @Published public var rate: Double = 1

    /// Playback reached the end. Only this offers the next item; an ordinary
    /// pause must not.
    @Published public var hasEnded = false

    @Published public var title = ""
    @Published public var subtitleTracks: [MediaTrack] = []
    @Published public var variants: [MediaTrack] = []

    /// Decoded frame height. 0 until metadata lands.
    @Published public var videoHeight = 0
    @Published public var fit: VideoFit = .contain

    @Published public var canPictureInPicture = false
    @Published public var canAirPlay = false

    public init() {}

    /// Resolution as a person reads it.
    public var qualityLabel: String { videoHeight > 0 ? "\(videoHeight)p" : "--" }

    public var activeSubtitleTrack: MediaTrack? {
        subtitleTracks.first(where: \.isActive)
    }

    /// Back to nothing, for a source about to load something else. Every field
    /// resets: a stale duration or track list from the previous item is worse
    /// than an empty one, because the chrome renders it as real.
    public func reset() {
        isPlaying = false
        currentTime = 0
        duration = 0
        isLive = false
        bufferedTo = 0
        rate = 1
        hasEnded = false
        title = ""
        subtitleTracks = []
        variants = []
        videoHeight = 0
        fit = .contain
        canPictureInPicture = false
        canAirPlay = false
    }
}

// MARK: - Sources

/// Transport. Implemented by the web agent bridge today, and by `AVPlayer` for
/// local files and direct URLs.
///
/// Capabilities that not every engine has get default no-op implementations
/// rather than a `canDoX` flag per method — a source advertises what it can do
/// through `state`, and the chrome hides controls it should not offer.
@MainActor
public protocol PlaybackSource: AnyObject {
    var state: PlaybackState { get }

    func togglePlay()
    func seek(to seconds: Double)
    func skip(by seconds: Double)
    func setRate(_ rate: Double)

    /// The user has started dragging the scrubber. Position reporting must
    /// stop until the seek lands, or the thumb fights the finger holding it.
    func beginScrub()

    func selectSubtitleTrack(_ id: Int?)
    func selectVariant(_ id: Int)
    func setFit(_ fit: VideoFit)
    func togglePictureInPicture()
    func showAirPlayPicker()

    /// Leave the player. For the web source this unstages the page; for a
    /// file it tears the engine down.
    func close()
}

public extension PlaybackSource {
    func beginScrub() {}
    func selectSubtitleTrack(_ id: Int?) {}
    func selectVariant(_ id: Int) {}
    func setFit(_ fit: VideoFit) {}
    func togglePictureInPicture() {}
    func showAirPlayPicker() {}

    /// Skip is seek with the arithmetic done once, in one place, with the
    /// clamping that goes with it.
    func skip(by seconds: Double) {
        seek(to: max(0, state.currentTime + seconds))
    }
}

/// What comes next, where there is such a thing.
///
/// Separate from `PlaybackSource` because plenty of playback has no next: a
/// single file, a live stream. A source that does not conform simply leaves
/// the episode controls out of the chrome.
///
/// Addressed by `PlaylistItem.ID` rather than by URL — the web source's ids
/// happen to be URLs and are re-validated against the current host before it
/// navigates, but a folder source's are paths and a queue's are indices.
@MainActor
public protocol PlaylistSource: AnyObject {
    var items: [PlaylistItem] { get }
    var nextItem: PlaylistItem.ID? { get }
    var previousItem: PlaylistItem.ID? { get }

    /// The full list is fetched on demand: on a season page it means walking
    /// every link in the document, which is not worth doing until asked.
    func loadItems()
    func go(to id: PlaylistItem.ID)
}

public extension PlaylistSource {
    var hasNext: Bool { nextItem != nil }
    var hasPrevious: Bool { previousItem != nil }

    func goToNext() { if let nextItem { go(to: nextItem) } }
    func goToPrevious() { if let previousItem { go(to: previousItem) } }
}
