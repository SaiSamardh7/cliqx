import Foundation
@testable import CleanPlayer

/// A `PlaybackSource` with no engine behind it: it records what the chrome
/// asked for and lets a test set what the chrome would have seen.
///
/// This exists because of the `onProtectionChanged` bug — a control that was
/// wired at one end, unwired at the other, and silently did nothing for as long
/// as the parameter existed. Every control the player offers has that failure
/// mode, and until now none of them were reachable from a test.
@MainActor
final class FakePlaybackSource: PlaybackSource, PlaylistSource {
    let state = PlaybackState()

    /// Every call, in order, as the chrome made it. Compared against an
    /// expected list rather than counted: order and arguments both matter.
    private(set) var calls: [Call] = []

    enum Call: Equatable, CustomStringConvertible {
        case togglePlay
        case beginScrub
        case seek(Double)
        case setRate(Double)
        case selectSubtitleTrack(Int?)
        case selectVariant(Int)
        case setFit(VideoFit)
        case togglePictureInPicture
        case showAirPlayPicker
        case close
        case loadItems
        case go(String)

        var description: String {
            switch self {
            case .togglePlay:                 return "togglePlay"
            case .beginScrub:                 return "beginScrub"
            case .seek(let to):               return "seek(\(to))"
            case .setRate(let rate):          return "setRate(\(rate))"
            case .selectSubtitleTrack(let id): return "selectSubtitleTrack(\(String(describing: id)))"
            case .selectVariant(let id):      return "selectVariant(\(id))"
            case .setFit(let fit):            return "setFit(.\(fit.rawValue))"
            case .togglePictureInPicture:     return "togglePictureInPicture"
            case .showAirPlayPicker:          return "showAirPlayPicker"
            case .close:                      return "close"
            case .loadItems:                  return "loadItems"
            case .go(let id):                 return "go(\(id))"
            }
        }
    }

    func reset() { calls = [] }

    // MARK: PlaybackSource

    func togglePlay() {
        calls.append(.togglePlay)
        state.isPlaying.toggle()
        if state.isPlaying { state.hasEnded = false }
    }

    func beginScrub() { calls.append(.beginScrub) }

    func seek(to seconds: Double) {
        calls.append(.seek(seconds))
        state.currentTime = seconds
        if seconds < state.duration { state.hasEnded = false }
    }

    func setRate(_ rate: Double) {
        calls.append(.setRate(rate))
        state.rate = rate
    }

    func selectSubtitleTrack(_ id: Int?) {
        calls.append(.selectSubtitleTrack(id))
        state.subtitleTracks = state.subtitleTracks.map {
            MediaTrack(id: $0.id, label: $0.label, isActive: $0.id == id)
        }
    }

    func selectVariant(_ id: Int) {
        calls.append(.selectVariant(id))
        state.variants = state.variants.map {
            MediaTrack(id: $0.id, label: $0.label, isActive: $0.id == id)
        }
    }

    func setFit(_ fit: VideoFit) {
        calls.append(.setFit(fit))
        state.fit = fit
    }

    func togglePictureInPicture() { calls.append(.togglePictureInPicture) }
    func showAirPlayPicker() { calls.append(.showAirPlayPicker) }
    func close() { calls.append(.close) }

    // MARK: PlaylistSource

    var items: [PlaylistItem] = []
    var nextItem: PlaylistItem.ID?
    var previousItem: PlaylistItem.ID?

    func loadItems() { calls.append(.loadItems) }
    func go(to id: PlaylistItem.ID) { calls.append(.go(id)) }

    // MARK: Standing in for an engine

    /// What the chrome would be looking at partway through a video.
    func playing(at seconds: Double = 30, of duration: Double = 100) {
        state.duration = duration
        state.currentTime = seconds
        state.isPlaying = true
        state.hasEnded = false
    }

    /// Playback finished — the only state that may offer the next item.
    func reachedEnd() {
        state.currentTime = state.duration
        state.isPlaying = false
        state.hasEnded = true
    }
}
