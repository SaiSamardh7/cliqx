import AVFoundation
import AVKit
import Foundation

/// `PlaybackSource` over `AVPlayer`: local files, direct URLs, HLS.
///
/// This is the half the web path cannot do well. Picture in Picture, AirPlay,
/// background audio and the lock-screen controls all depend on the page
/// cooperating when playback lives inside a `WKWebView`, and they are ordinary
/// platform features here.
///
/// What it cannot do is Matroska. `AVFoundation` has no MKV support at all, and
/// no amount of wrapping changes that — closing the gap means FFmpeg or
/// VLCKit, and their LGPL terms are a licensing decision for this project, not
/// a detail. See `NOTICE.md` before taking it.
@MainActor
public final class AVPlaybackSource: NSObject, PlaybackSource {
    public let state = PlaybackState()
    public let player: AVPlayer

    /// What the user asked for, which is not `player.rate`: that reads 0 while
    /// paused, so driving the speed menu from it would show "0×" for a paused
    /// video and reset the choice on every pause.
    private var desiredRate: Double = 1

    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var endObserver: NSObjectProtocol?
    private var pictureInPicture: AVPictureInPictureController?

    /// True from the first touch on the scrubber until the seek lands.
    private var isScrubbing = false

    public init(url: URL, title: String = "") {
        self.player = AVPlayer(url: url)
        super.init()
        state.title = title
        observe()
    }

    deinit {
        // Not `stopObserving()` — that is main-actor isolated and deinit is
        // not. The observer holds the player, not the other way round, so
        // removing it here is both safe and necessary.
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    // MARK: Transport

    public func togglePlay() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            // Re-applying the rate is what resumes: setting `rate` directly is
            // how AVPlayer plays at anything other than 1×, and `play()` would
            // reset a 1.5× choice back to normal.
            // A player parked at the end ignores a new rate; rewind first.
            if state.hasEnded { player.seek(to: .zero) }
            player.rate = Float(desiredRate)
            state.hasEnded = false
        }
        state.isPlaying = player.timeControlStatus == .playing
    }

    public func beginScrub() {
        isScrubbing = true
    }

    public func seek(to seconds: Double) {
        let clamped = state.duration > 0
            ? min(max(0, seconds), state.duration)
            : max(0, seconds)
        // Zero tolerance: a scrub that lands on the nearest keyframe instead of
        // where the finger was reads as the control being broken.
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isScrubbing = false
            }
        }
        state.currentTime = clamped
        if clamped < state.duration { state.hasEnded = false }
    }

    public func setRate(_ rate: Double) {
        desiredRate = rate
        state.rate = rate
        // Only push it to the engine if something is playing; setting a
        // non-zero rate on a paused player starts it.
        if player.timeControlStatus != .paused { player.rate = Float(rate) }
    }

    public func setFit(_ fit: VideoFit) {
        // The layer owns gravity, so the view applies this — the source just
        // records the choice so the chrome and the layer agree on it.
        state.fit = fit
    }

    public func close() {
        player.pause()
        stopObserving()
        state.reset()
    }

    // MARK: Subtitles

    public func selectSubtitleTrack(_ id: Int?) {
        guard let item = player.currentItem else { return }
        Task { [weak self] in
            guard let group = try? await item.asset
                .loadMediaSelectionGroup(for: .legible) else { return }
            if let id, group.options.indices.contains(id) {
                item.select(group.options[id], in: group)
            } else {
                item.select(nil, in: group)   // "Off"
            }
            await self?.refreshSubtitleTracks()
        }
    }

    private func refreshSubtitleTracks() async {
        guard let item = player.currentItem,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .legible)
        else {
            state.subtitleTracks = []
            return
        }
        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        state.subtitleTracks = group.options.enumerated().map { index, option in
            MediaTrack(id: index,
                       label: option.displayName,
                       isActive: option == selected)
        }
    }

    // MARK: Picture in Picture

    /// PiP needs the layer the video is actually rendering into, which the view
    /// owns and this object does not. The view hands it over once it exists.
    public func attach(to layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            state.canPictureInPicture = false
            return
        }
        pictureInPicture = AVPictureInPictureController(playerLayer: layer)
        state.canPictureInPicture = pictureInPicture != nil
    }

    public func togglePictureInPicture() {
        guard let pictureInPicture else { return }
        if pictureInPicture.isPictureInPictureActive {
            pictureInPicture.stopPictureInPicture()
        } else {
            pictureInPicture.startPictureInPicture()
        }
    }

    /// AVKit has no programmatic "present the route picker" call. `AVRoutePickerView`
    /// has to be in the view hierarchy and tapped by the user, so on this path
    /// the chrome hosts that view rather than calling a method — which is why
    /// this stays a no-op and `state.canAirPlay` is what the chrome reads.
    ///
    /// The web path is the opposite: `webkitShowPlaybackTargetPicker()` is a
    /// method, and whether it needs a user gesture is still unverified.
    public func showAirPlayPicker() {}

    // MARK: Observation

    private func observe() {
        // Four times a second. The web path throttles `timeupdate` to the same
        // rate for the same reason: more than that is more than a seek bar
        // needs, and every one of them invalidates SwiftUI.
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval,
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(at: time) }
        }

        observations = [
            player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                MainActor.assumeIsolated {
                    self?.state.isPlaying = player.timeControlStatus == .playing
                }
            }
        ]

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.state.hasEnded = true
                self?.state.isPlaying = false
            }
        }

        Task { [weak self] in
            await self?.refreshSubtitleTracks()
            await self?.refreshPresentationSize()
        }
    }

    private func stopObserving() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        observations = []
        pictureInPicture = nil
    }

    private func tick(at time: CMTime) {
        guard !isScrubbing else { return }
        state.currentTime = time.seconds.isFinite ? time.seconds : 0

        guard let item = player.currentItem else { return }
        let duration = item.duration
        // `.indefinite` is a live stream; a duration that is simply not loaded
        // yet is `.invalid`. Both are unusable as a number and they are not the
        // same thing — only the first earns a LIVE badge.
        state.isLive = duration.isIndefinite
        state.duration = (duration.isNumeric && duration.seconds.isFinite)
            ? duration.seconds : 0
        state.bufferedTo = Self.bufferedAhead(in: item)
    }

    private func refreshPresentationSize() async {
        guard let track = try? await player.currentItem?.asset
            .loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize)
        else { return }
        state.videoHeight = Int(size.height)
    }

    /// How far the buffer runs from where playback currently is — not the
    /// largest loaded range, which on a seek-heavy session is somewhere else
    /// entirely and would draw the buffer bar behind the playhead.
    static func bufferedAhead(in item: AVPlayerItem) -> Double {
        let now = item.currentTime().seconds
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = (range.start + range.duration).seconds
            if start <= now && now <= end { return end }
        }
        return now.isFinite ? now : 0
    }
}
