import CleanPlayer
import MobileVLCKit
import SwiftUI
import os

/// Plays a stream recovered from a web page in the app's own player.
///
/// The reason this exists is volume, and the reason volume needed it is worth
/// stating plainly: while a site's player decodes the media inside WebKit, the
/// app only gets to watch. `HTMLMediaElement.volume` is ignored on iOS, device
/// volume has no supported setter, and Web Audio can only capture what the
/// renderer itself decodes — never MSE or native HLS, which is nearly every
/// real site. There is no arrangement of those three that yields a working
/// volume control.
///
/// Decoding it here removes the problem rather than working around it. VLC owns
/// the audio, so volume, boost, speed and track selection are all ordinary
/// local operations — the same ones that have always worked for Jellyfin and
/// for local files, through the same `PlayerOverlay`.
///
/// What it cannot take: DRM, which has to stay inside WebKit, and any stream
/// whose manifest never appears in resource timing. Those keep the in-page
/// player and the device-volume slider.
@MainActor
final class WebStreamEngine: NSObject, ObservableObject, @preconcurrency VLCMediaPlayerDelegate {
    let page = PageState()
    let player: VLCMediaPlayer

    private let stream: URL
    private let pageURL: URL
    private let subtitleStyle: SubtitleStyle
    private let interruptions = AudioInterruptions()
    private var wasPlayingBeforeInterruption = false
    private var didReadTracks = false
    private var desiredRate: Float = 1
    private let startAt: Double
    private var didSeekToStart = false
    var onClose: (Double) -> Void = { _ in }

    private static let log = Logger(subsystem: "com.saisamardh.cleanplayer",
                                    category: "handoff")

    init(stream: URL, pageURL: URL, title: String, startAt: Double = 0,
         subtitleStyle: SubtitleStyle = SubtitleStyle()) {
        self.stream = stream
        self.pageURL = pageURL
        self.startAt = startAt
        self.subtitleStyle = subtitleStyle
        player = VLCMediaPlayer(options: subtitleStyle.playerOptions)
        super.init()

        page.isTheater = true
        page.title = title
        page.host = pageURL.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
        page.overlayBlocking = false
        // The whole point of coming here. VLC decodes, so the app owns the
        // audio outright: no Web Audio, no CORS, nothing to fail.
        page.mediaVolumeAvailable = true

        page.actions = PageState.Actions(
            exitTheater: { [weak self] in self?.close() },
            togglePlay: { [weak self] in self?.togglePlay() },
            beginScrub: {},
            seek: { [weak self] to in self?.seek(to: to) },
            skip: { [weak self] by in self?.skip(by) },
            setRate: { [weak self] rate in self?.setRate(rate) },
            setVolume: { [weak self] percent in self?.setVolume(percent) },
            selectTrack: { [weak self] index in self?.selectSubtitle(index) },
            togglePiP: {},
            setObjectFit: { [weak self] mode in self?.setObjectFit(mode) },
            selectSource: { _ in },
            loadEpisodes: {},
            showAirPlay: {},
            goToEpisode: { _ in },
            cancelResume: {},
            setOverlayBlocking: { _ in },
            openBlockedRequest: { _ in },
            retryFailedNavigation: {}
        )
        player.delegate = self
        interruptions.start { [weak self] event in
            MainActor.assumeIsolated { self?.handle(interruption: event) }
        }
    }

    // MARK: Lifecycle

    func start() {
        let media = VLCMedia(url: stream)
        for option in subtitleStyle.mediaOptions { media.addOption(option) }
        // Many hosts serve segments only to the page that asked for them. VLC
        // fetches on its own, so it has to introduce itself the same way the
        // web view did, or the first segment comes back 403.
        media.addOption(":http-referrer=\(pageURL.absoluteString)")
        media.addOption(":http-user-agent=\(Self.webViewUserAgent)")
        player.media = media
        player.play()
        player.rate = desiredRate
        Self.log.notice("Handoff started for \(self.stream.absoluteString, privacy: .private)")
    }

    func close() {
        let reached = page.currentTime
        player.stop()
        MediaSession.deactivate()
        onClose(reached)
    }

    /// Matches what the page itself sent, so a host that varies its answer by
    /// client does not hand VLC something different from what it approved.
    private static let webViewUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private func handle(interruption event: AudioInterruptions.Event) {
        switch event {
        case .began:
            wasPlayingBeforeInterruption = player.isPlaying
            if player.isPlaying { player.pause() }
        case .ended(let shouldResume):
            guard shouldResume, wasPlayingBeforeInterruption, !player.isPlaying else { break }
            wasPlayingBeforeInterruption = false
            player.play()
        case .outputDeviceLost:
            wasPlayingBeforeInterruption = false
            if player.isPlaying { player.pause() }
        }
        page.isPlaying = player.isPlaying
    }

    // MARK: Transport

    private var lengthMs: Int { Int(player.media?.length.intValue ?? 0) }

    private func togglePlay() {
        if player.isPlaying { player.pause() } else { player.play() }
    }

    private func seek(to seconds: Double) {
        guard lengthMs > 0 else { return }
        let target = min(max(seconds * 1000, 0), Double(lengthMs))
        player.time = VLCTime(int: Int32(target))
        page.currentTime = target / 1000
        page.playbackEnded = false
    }

    private func skip(_ seconds: Double) { seek(to: page.currentTime + seconds) }

    private func setRate(_ rate: Double) {
        desiredRate = Float(rate)
        player.rate = desiredRate
        page.playbackRate = rate
    }

    /// VLC's scale is 0…200 — the chrome's own scale, boost included.
    private func setVolume(_ percent: Int) {
        let safe = min(max(percent, 0), 200)
        player.audio?.volume = Int32(safe)
        page.volumePercent = safe
    }

    private func selectSubtitle(_ index: Int) {
        let ids = (player.videoSubTitlesIndexes as? [NSNumber]) ?? []
        guard ids.indices.contains(index) else { return }
        player.currentVideoSubTitleIndex = ids[index].int32Value
        readTracks(force: true)
    }

    private func setObjectFit(_ mode: String) {
        // VLC crops by scaling the picture past the surface; 0 is "fit".
        player.scaleFactor = mode == "cover" ? 1.25 : 0
        page.objectFit = mode
    }

    // MARK: VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ notification: Notification!) {
        page.isPlaying = player.isPlaying
        page.isBuffering = player.state == .buffering || player.state == .opening
        if player.state == .ended {
            page.playbackEnded = true
            page.isPlaying = false
        }
        if player.state == .error {
            page.mediaError = "This stream could not be played outside the page."
        }
    }

    func mediaPlayerTimeChanged(_ notification: Notification!) {
        page.isPlaying = player.isPlaying
        page.currentTime = Double(player.time.intValue) / 1000
        let length = lengthMs
        page.duration = Double(length) / 1000
        page.bufferedTo = page.currentTime      // VLC does not expose the buffer
        page.isBuffering = false
        guard length > 0 else { return }

        // Pick up where the page had got to, once seeking is actually possible.
        if !didSeekToStart, player.isSeekable {
            didSeekToStart = true
            if startAt > 1, startAt * 1000 < Double(length) - 5000 {
                player.position = Float(startAt * 1000) / Float(length)
            }
        }
        if !didReadTracks { readTracks(force: false) }
        if page.videoHeight == 0 { page.videoHeight = Int(player.videoSize.height) }
    }

    private func readTracks(force: Bool) {
        let names = (player.videoSubTitlesNames as? [String]) ?? []
        let ids = (player.videoSubTitlesIndexes as? [NSNumber]) ?? []
        guard !ids.isEmpty else { return }
        if !force { didReadTracks = true }
        let current = player.currentVideoSubTitleIndex
        page.textTracks = zip(ids, names).enumerated().map { offset, pair in
            PageState.TextTrack(id: offset, label: pair.1, active: pair.0.int32Value == current)
        }
    }
}

struct WebStreamPlayerView: View {
    @StateObject private var engine: WebStreamEngine
    @ObservedObject var rules: RuleListController
    @ObservedObject var gestureSettings: PlayerGestureSettings
    /// Carries back how far playback got, so the page can be put there when
    /// the user returns to it.
    let onClose: (Double) -> Void

    init(stream: URL, pageURL: URL, title: String, startAt: Double,
         rules: RuleListController, gestureSettings: PlayerGestureSettings,
         subtitleStyle: SubtitleStyle = SubtitleStyle(),
         onClose: @escaping (Double) -> Void) {
        _engine = StateObject(wrappedValue: WebStreamEngine(
            stream: stream, pageURL: pageURL, title: title,
            startAt: startAt, subtitleStyle: subtitleStyle))
        self.rules = rules
        self.gestureSettings = gestureSettings
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VLCVideoSurface(player: engine.player)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            PlayerOverlay(page: engine.page, rules: rules, gestureSettings: gestureSettings)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            MediaSession.activate()
            engine.onClose = onClose
            engine.start()
        }
        .onDisappear {
            engine.player.stop()
            MediaSession.deactivate()
        }
    }
}
