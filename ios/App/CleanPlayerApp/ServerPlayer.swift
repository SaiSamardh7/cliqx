import CleanPlayer
import SwiftUI
import UIKit
import VLCKitSPM

/// A server stream behind the SAME chrome the browser uses.
///
/// `PlayerOverlay` reads a `PageState` and calls its `actions`; it does not
/// care what is underneath. This fills one from a VLC player instead of a web
/// page, so a film from the server gets the gestures, speed menu, subtitle
/// picker, up-next countdown and episode list — not the bare local player.
///
/// Episodes are addressed as `cliqx-jellyfin://item/<id>` because the chrome
/// speaks URLs; nothing here ever loads one, they are only keys.
@MainActor
final class ServerEngine: NSObject, ObservableObject, @preconcurrency VLCMediaPlayerDelegate {
    let page = PageState()
    let player = VLCMediaPlayer()

    private let server: JellyfinServer
    private let client: JellyfinClient
    private(set) var item: JellyfinItem
    private var siblings: [JellyfinItem] = []      // the season, for next/previous
    private var lastReport = Date.distantPast
    private var reportedStop = false
    private var pendingResumeMs = 0
    private var didResume = false
    private var didReadTracks = false
    private var desiredRate: Float = 1
    private let interruptions = AudioInterruptions()
    private var wasPlayingBeforeInterruption = false
    var onClose: () -> Void = {}

    init(item: JellyfinItem, server: JellyfinServer, servers: JellyfinServers) {
        self.item = item
        self.server = server
        self.client = servers.client(for: server)
        super.init()
        page.isTheater = true
        page.host = server.name
        page.overlayBlocking = false
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
            loadEpisodes: { [weak self] in self?.publishEpisodes() },
            showAirPlay: {},
            goToEpisode: { [weak self] url in self?.go(to: url) },
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

    /// See the same handler in WebView: iOS pauses for an interruption and
    /// says nothing, and headphones leaving must always pause.
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

    // MARK: Lifecycle

    func start() {
        load(item)
        Task { await loadSiblings() }
    }

    private func load(_ item: JellyfinItem) {
        guard let token = client.token,
              let url = JellyfinAPI.streamURL(server: server.url, itemID: item.id, token: token)
        else { return }
        self.item = item
        page.title = item.seriesName.map { "\($0) — \(item.name)" } ?? item.name
        page.playbackEnded = false
        page.currentTime = 0
        page.duration = 0
        page.textTracks = []
        page.videoHeight = 0
        pendingResumeMs = item.resumeMs
        didResume = item.resumeMs <= 0
        didReadTracks = false
        reportedStop = false
        player.media = VLCMedia(url: url)
        player.play()
        player.rate = desiredRate
        client.reportStart(itemID: item.id, positionMs: item.resumeMs)
        publishNeighbours()
    }

    func close() {
        if !reportedStop { report(final: true) }
        player.stop()
        MediaSession.deactivate()
        onClose()
    }

    /// The other episodes of this season, for Next / Previous and the list.
    /// A film has none, and the chrome hides the controls.
    private func loadSiblings() async {
        guard item.type == "Episode", let season = item.seasonId else { return }
        siblings = (try? await client.items(userID: server.userID, parentID: season)) ?? []
        publishNeighbours()
    }

    private static func key(_ item: JellyfinItem) -> URL { URL(string: "cliqx-jellyfin://item/\(item.id)")! }

    private func publishNeighbours() {
        guard let index = siblings.firstIndex(where: { $0.id == item.id }) else {
            page.nextEpisode = nil
            page.previousEpisode = nil
            return
        }
        page.previousEpisode = index > 0 ? Self.key(siblings[index - 1]) : nil
        page.nextEpisode = index + 1 < siblings.count ? Self.key(siblings[index + 1]) : nil
        if !page.episodes.isEmpty { publishEpisodes() }
    }

    private func publishEpisodes() {
        page.episodes = siblings.map {
            PageState.Episode(id: Self.key($0).absoluteString,
                              label: [$0.indexNumber.map { "Episode \($0)" }, $0.name]
                                  .compactMap { $0 }.joined(separator: " · "),
                              current: $0.id == item.id)
        }
    }

    private func go(to url: URL) {
        guard let next = siblings.first(where: { Self.key($0) == url }) else { return }
        if !reportedStop { report(final: true) }   // a natural end already said so
        load(next)
    }

    // MARK: Transport

    private func togglePlay() {
        if player.isPlaying { player.pause() } else { player.play() }
        report(final: false)
    }

    private var lengthMs: Int { Int(player.media?.length.intValue ?? 0) }

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

    /// VLC's volume is 0…200 already — the same scale the chrome uses, boost
    /// included, with no Web Audio and no CORS to fall foul of.
    private func setVolume(_ percent: Int) {
        let safe = min(max(percent, 0), 200)
        player.audio?.volume = Int32(safe)
        page.volumePercent = safe
    }

    private func selectSubtitle(_ index: Int) {
        let ids = (player.videoSubTitlesIndexes as? [NSNumber]) ?? []
        // -1 is VLC's "Disable" and comes first in its own list; the chrome's
        // index is into our published list, which mirrors VLC's order.
        guard ids.indices.contains(index) else { return }
        player.currentVideoSubTitleIndex = ids[index].int32Value
        readTracks()
    }

    /// contain = whole frame, cover = fill the screen and crop. VLC does this
    /// with a crop geometry in the screen's aspect ratio.
    private func setObjectFit(_ mode: String) {
        if mode == "cover" {
            let size = UIScreen.main.bounds.size
            let w = Int(max(size.width, size.height)), h = Int(min(size.width, size.height))
            // libvlc copies the string; ours is freed straight after.
            let geometry = strdup("\(w):\(h)")
            player.videoCropGeometry = geometry
            free(geometry)
        } else {
            player.videoCropGeometry = nil
        }
        page.objectFit = mode == "cover" ? "cover" : "contain"
    }

    // MARK: VLC → PageState

    func mediaPlayerStateChanged(_ notification: Notification!) {
        page.isPlaying = player.isPlaying
        page.isBuffering = player.state == .buffering || player.state == .opening
        if player.state == .ended {
            page.playbackEnded = true
            page.isPlaying = false
            report(final: true)
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

        if !didResume, player.isSeekable {
            didResume = true
            if pendingResumeMs > 0, pendingResumeMs < length - 5000 {
                player.position = Float(pendingResumeMs) / Float(length)
            }
        }
        if !didReadTracks { readTracks() }
        if page.videoHeight == 0 { page.videoHeight = Int(player.videoSize.height) }

        if Date().timeIntervalSince(lastReport) >= 5 { report(final: false) }
    }

    /// Subtitle tracks the file carries, in VLC's order so indices line up.
    private func readTracks() {
        let names = (player.videoSubTitlesNames as? [String]) ?? []
        let ids = (player.videoSubTitlesIndexes as? [NSNumber]) ?? []
        guard !ids.isEmpty else { return }
        didReadTracks = true
        let current = player.currentVideoSubTitleIndex
        page.textTracks = zip(ids, names).enumerated().map { offset, pair in
            PageState.TextTrack(id: offset, label: pair.1, active: pair.0.int32Value == current)
        }
    }

    /// Progress to the server: every 5 s while playing, on pause, and when
    /// leaving — so the TV and the browser pick up where the phone stopped.
    func report(final: Bool) {
        lastReport = Date()
        let position = Int(player.time.intValue)
        guard lengthMs > 0 else { return }
        if final {
            reportedStop = true
            client.reportStopped(itemID: item.id, positionMs: position)
        } else {
            client.reportProgress(itemID: item.id, positionMs: position, paused: !player.isPlaying)
        }
    }
}

/// VLC's picture, the Cliqx chrome, nothing else.
struct ServerPlayerView: View {
    @StateObject private var engine: ServerEngine
    @ObservedObject var rules: RuleListController
    @ObservedObject var gestureSettings: PlayerGestureSettings
    let onClose: () -> Void

    init(item: JellyfinItem, server: JellyfinServer, servers: JellyfinServers,
         rules: RuleListController, gestureSettings: PlayerGestureSettings,
         onClose: @escaping () -> Void) {
        _engine = StateObject(wrappedValue: ServerEngine(item: item, server: server, servers: servers))
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
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didEnterBackgroundNotification)) { _ in
            engine.report(final: false)   // backgrounding is a save point
        }
    }
}
