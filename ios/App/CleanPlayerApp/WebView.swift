import CleanPlayer
import os
import SwiftUI
import UIKit
import WebKit

/// Navigation and player state the SwiftUI chrome needs.
@MainActor
final class PageState: ObservableObject {
    @Published var host = ""
    @Published var isSecure = true
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    /// A failed load must say why. Otherwise every failure looks identical:
    /// a blank screen.
    @Published var loadError: String?
    /// The staged video will not play — DRM, an unopenable format, a stalled
    /// download. Distinct from `loadError`, which is about the page.
    @Published var mediaError: String?

    @Published var isTheater = false
    /// An episode change is in flight and theater is expected to come back.
    /// The player chrome stays up as a curtain over it: without this the raw
    /// page — header, ads, the lot — flashes into view between episodes, which
    /// is the whole thing theater exists to avoid.
    @Published var isResumingEpisode = false
    /// Drives the transition curtain copy. Kept separate from the destination
    /// URL so Previous never announces itself as Next.
    @Published var episodeTransitionDirection: EpisodeDirection?
    /// The last frame of the outgoing video, shown under the curtain so an
    /// episode change reads as a pause on the picture rather than a cut to
    /// black. Nil until the snapshot lands, and again once the curtain lifts.
    @Published var transitionFrame: UIImage?

    var episodeTransitionMessage: String {
        switch episodeTransitionDirection {
        case .next: "Loading next episode"
        case .previous: "Loading previous episode"
        case nil: "Loading episode"
        }
    }
    /// Playback reached the end. Only this offers the next episode; an ordinary
    /// pause must not.
    @Published var playbackEnded = false
    @Published var isPlaying = false
    /// Not paused, but no frame to show yet. Distinct from `isPlaying` so the
    /// centre button can say "loading" and the chrome does not auto-hide over
    /// a black screen.
    @Published var isBuffering = false
    @Published var currentTime: Double = 0
    /// 0 both for a live stream and before metadata arrives. `isLive`
    /// separates them: only one of those deserves a LIVE badge.
    @Published var duration: Double = 0
    @Published var isLive = false
    @Published var bufferedTo: Double = 0
    @Published var playbackRate: Double = 1
    /// Per-video level. 100 is normal; 101...200 is software amplification.
    @Published var volumePercent = 100
    @Published var mediaVolumeAvailable = false
    @Published var textTracks: [TextTrack] = []
    @Published var pipAvailable = false
    /// Decoded frame height — the only quality figure available from outside
    /// the site's own player. 0 until metadata lands.
    @Published var videoHeight = 0
    @Published var sources: [VideoSource] = []
    @Published var objectFit = "contain"
    @Published var episodes: [Episode] = []
    /// The page's own title, shown in the player's top bar.
    @Published var title = ""
    @Published var airplayAvailable = false
    /// Whether a route could carry the PICTURE, not just whether one exists.
    ///
    /// False for a MediaSource stream, which is most sites with their own
    /// player: the receiver is handed a `blob:` URL that means nothing outside
    /// this process, so WebKit sends the audio and keeps the video here. That
    /// is the "music note on the television" symptom, and the app used to
    /// offer a button that walked straight into it.
    @Published var airplayCanSendVideo = true
    /// Whether the staged element exposes a route picker at all, as
    /// opposed to whether a route is currently on the network. The two
    /// were conflated, and only the first is a capability.
    @Published var airplayPickerSupported = false
    @Published var nextEpisode: URL?
    @Published var previousEpisode: URL?
    /// Whether `nextEpisode` came from a real episode signal — `rel="next"` or
    /// a list of numbered episodes — rather than an anchor whose text happens
    /// to say "next".
    ///
    /// The button is offered either way; only this decides whether the player
    /// will navigate ON ITS OWN when the video ends. "Next »" in a forum
    /// footer or a docs page matches the text rule, and auto-advancing on it
    /// carries the user off the page they were watching.
    @Published var nextEpisodeIsEpisodic = false
    /// Why there is no next or previous, when there is none.
    ///
    /// A disabled button says "not here" and nothing else, which is the same
    /// thing whether the server refused the request, the show has one episode,
    /// or this is a page the app could find no episode links on. Those want
    /// different actions from the user, so the player says which it is.
    @Published var episodeUnavailableReason: String?
    @Published var overlayBlocking = true
    @Published var blockedCount = 0
    /// Popups stopped in the native navigation layer: a cross-site window, a
    /// cancelled redirect. Native witnessed each of these itself, so the
    /// number is trustworthy.
    @Published var popupsBlocked = 0
    /// Popups the page-world guard says it stopped.
    ///
    /// Advisory, and it cannot be made otherwise: `popupguard.js` has to run in
    /// the page's own world to replace `window.open`, so any channel it uses to
    /// report is a channel the page can use too. Native validates the message
    /// and counts increments rather than accepting a total — a page can no
    /// longer set the badge to -40 or 9,999,999 — but it can still claim
    /// blocks that did not happen, so the claim is capped per document and
    /// kept apart from the number native is sure of.
    @Published var pageReportedPopups = 0
    /// Highest number of page-claimed blocks one document may contribute.
    static let pageReportedPopupCap = 100

    /// What the shield badge shows: elements hidden, plus popups from both
    /// sources. The page's share is bounded; see `pageReportedPopups`.
    var blockedTotal: Int { blockedCount + popupsBlocked + pageReportedPopups }
    /// A cross-origin window the page tried to open. Held rather than followed,
    /// so the user decides whether to leave the page they are watching.
    @Published var blockedExternal: URLRequest?

    weak var webView: WKWebView?

    /// Set by the coordinator. The player chrome is native, so every control
    /// routes back through here.
    var actions = Actions()

    struct TextTrack: Identifiable, Equatable {
        let id: Int
        let label: String
        let active: Bool
    }

    /// Shaped like `TextTrack`, and for the same reason: the id is the index
    /// of the page's own `<source>`, so selecting one never sends page text
    /// back across the bridge.
    struct VideoSource: Identifiable, Equatable {
        let id: Int
        let label: String
        let active: Bool
    }

    struct Episode: Identifiable, Equatable {
        let id: String
        let label: String
        let current: Bool
        var url: URL? { URL(string: id) }
    }

    /// Resolution as a person reads it. 0 while metadata is still loading.
    var qualityLabel: String { videoHeight > 0 ? "\(videoHeight)p" : "--" }

    struct Actions {
        var exitTheater: () -> Void = {}
        var togglePlay: () -> Void = {}
        var beginScrub: () -> Void = {}
        var seek: (Double) -> Void = { _ in }
        var skip: (Double) -> Void = { _ in }
        var setRate: (Double) -> Void = { _ in }
        var setVolume: (Int) -> Void = { _ in }
        var selectTrack: (Int) -> Void = { _ in }
        var togglePiP: () -> Void = {}
        var setObjectFit: (String) -> Void = { _ in }
        var selectSource: (Int) -> Void = { _ in }
        var loadEpisodes: () -> Void = {}
        var showAirPlay: () -> Void = {}
        var goToEpisode: (URL) -> Void = { _ in }
        var cancelResume: () -> Void = {}
        var setOverlayBlocking: (Bool) -> Void = { _ in }
        var openBlockedRequest: (URLRequest) -> Void = { _ in }
        var retryFailedNavigation: () -> Void = {}
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
}

struct WebView: UIViewRepresentable {
    let url: URL
    @ObservedObject var model: BrowserModel
    @ObservedObject var page: PageState
    @ObservedObject var rules: RuleListController
    @ObservedObject var settings: ProtectionSettings

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, page: page, rules: rules, settings: settings)
    }

    func makeUIView(context: Context) -> UIView {
        let webView = WKWebView(
            frame: .zero,
            configuration: BrowserSetup.makeConfiguration(
                agentJS: Agent.source, popupGuardJS: Agent.popupGuard,
                privateBrowsing: settings.privateBrowsing)
        )
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        BrowserSetup.installBridge(context.coordinator, on: webView)

        page.webView = webView
        page.actions = PageState.Actions(
            exitTheater: { [weak coordinator = context.coordinator] in
                coordinator?.exitTheater()
            },
            togglePlay: { [weak coordinator = context.coordinator] in
                coordinator?.togglePlay()
            },
            beginScrub: { [weak coordinator = context.coordinator] in
                coordinator?.callPlayer("beginScrub()")
            },
            seek: { [weak coordinator = context.coordinator] to in
                coordinator?.callPlayer("seek(\(to))")
            },
            skip: { [weak coordinator = context.coordinator] by in
                coordinator?.callPlayer("skip(\(by))")
            },
            setRate: { [weak coordinator = context.coordinator] rate in
                coordinator?.callPlayer("setRate(\(rate))")
            },
            setVolume: { [weak coordinator = context.coordinator] percent in
                let safe = min(max(percent, 0), 200)
                coordinator?.callPlayer("setVolume(\(safe))")
            },
            selectTrack: { [weak coordinator = context.coordinator] index in
                coordinator?.callPlayer("selectTextTrack(\(index))")
            },
            togglePiP: { [weak coordinator = context.coordinator] in
                coordinator?.callPlayer("togglePiP()")
            },
            setObjectFit: { [weak coordinator = context.coordinator] mode in
                coordinator?.callPlayer("setObjectFit('\(mode == "cover" ? "cover" : "contain")')")
            },
            selectSource: { [weak coordinator = context.coordinator] index in
                coordinator?.callPlayer("selectSource(\(index))")
            },
            loadEpisodes: { [weak coordinator = context.coordinator] in
                coordinator?.refreshEpisodeList()
            },
            showAirPlay: { [weak coordinator = context.coordinator] in
                coordinator?.showAirPlay()
            },
            goToEpisode: { [weak coordinator = context.coordinator] destination in
                coordinator?.goToEpisode(destination)
            },
            cancelResume: { [weak coordinator = context.coordinator] in
                coordinator?.endResume()
            },
            setOverlayBlocking: { [weak coordinator = context.coordinator] on in
                coordinator?.setOverlayBlocking(on)
            },
            openBlockedRequest: { [weak coordinator = context.coordinator] request in
                coordinator?.openBlockedRequest(request)
            },
            retryFailedNavigation: { [weak coordinator = context.coordinator] in
                coordinator?.retryFailedNavigation()
            }
        )

        // Whatever is compiled right now goes on immediately; anything still
        // compiling is swapped in by the controller when it lands.
        rules.attach(to: webView)

        context.coordinator.observe(webView)
        context.coordinator.loaded = url
        webView.load(URLRequest(url: url))

        // A plain container rather than the web view itself, so the warm
        // standby for the next episode can load in a second web view behind
        // this one and be swapped to the front without SwiftUI noticing.
        let container = UIView()
        container.backgroundColor = .black
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
        context.coordinator.container = container
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        // Only reload when the model points somewhere new, or every state
        // change would restart the page. Read from the model, not the `url`
        // this view was built with: a `page` change can run this update one
        // pass before the parent rebuilds us, and that stale `url` navigated
        // a just-promoted standby straight back to the episode it replaced.
        guard let target = model.current, context.coordinator.loaded != target else { return }
        context.coordinator.loaded = target
        page.webView?.load(URLRequest(url: target))
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate,
                             WKScriptMessageHandler, WKHTTPCookieStoreObserver {
        let model: BrowserModel
        let page: PageState
        let rules: RuleListController
        let settings: ProtectionSettings
        var loaded: URL?

        /// A renderer crash is reloaded once. A second crash on the same URL is
        /// a page the device cannot render, and retrying forever would just
        /// loop — so the second one is reported instead.
        private var recoveredFrom: URL?
        private var pendingMainFrameRequest: URLRequest?
        private var failedMainFrameRequest: URLRequest?

        private lazy var localNetworkProbeSession = URLSession(
            configuration: BrowserSetup.makeLocalNetworkProbeConfiguration())

        /// THE frame-targeting fix. The video is often staged inside a
        /// cross-origin player iframe, so `evaluateJavaScript(in: nil)` — the
        /// main frame — reaches a different `window.__cp` than the one holding
        /// the staged video, and silently does nothing.
        private var theaterFrame: WKFrameInfo?
        private var knownFrames: [String: WKFrameInfo] = [:]
        private var frameCapabilities = FrameCapabilityModel()
        private var droppedSpectatorMessages = 0

        /// The episode navigation theater should carry across to, if any.
        ///
        /// Scoped to that one destination rather than a bare flag: an episode
        /// whose video never loads would otherwise leave the flag armed, and the
        /// next unrelated site the user opened would drop straight into a player
        /// they did not ask for.
        private var resumeTheaterFor: URL?
        private var resumeOutgoingFrame: WKFrameInfo?
        private var resumeOutgoingSourceChanged = false
        /// The resume attempt has to outlast the site: these players sit
        /// in a cross-origin iframe that has been measured arriving anywhere
        /// from 4 to 30 seconds after the episode page loads. The curtain stays
        /// up for that attempt so Next never exposes the site's raw page; the
        /// user can still choose "Show the page" immediately.
        private static let armTimeout: Duration = .seconds(45)
        private static let transitionLog = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.saisamardh.cleanplayer",
            category: "EpisodeTransition")
        private static let bridgeLog = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.saisamardh.cleanplayer",
            category: "PageBridge")
        private var resumeArmTask: Task<Void, Never>?
        private var observations: [NSKeyValueObservation] = []

        /// Calls, alarms, and headphones being pulled out.
        private let interruptions = AudioInterruptions()
        /// Playing when an interruption began, so resuming is only offered to
        /// a video that was actually running.
        private var wasPlayingBeforeInterruption = false

        /// Per-frame totals prevent a zero from one iframe erasing blocks
        /// reported by every other iframe. The keys also address each frame
        /// when overlay blocking is toggled.
        private var blockedByFrame = BlockedFrameRegistry()
        private var bridgeRateLimiter = BridgeRateLimiter()
        private var droppedRateLimitedMessages = 0

        /// Resume + thumbnail bookkeeping for the video currently in theater.
        /// The URL is the watch page; last time/duration are saved when the
        /// user leaves so the card can resume and show progress.
        private var watchingURL: URL?
        private var lastTime: Double = 0
        private var lastDuration: Double = 0
        private var pendingResumeAt: Double = 0
        private var didApplyResume = false

        /// The view both web views live in. Weak: SwiftUI owns it.
        weak var container: UIView?

        /// Warm standby: the next episode, loading in a second web view behind
        /// the one on screen. Armed in the last minute of an episode, promoted
        /// the moment its video proves it can play, so Next is a cut rather
        /// than a load. Fails soft — anything going wrong just leaves the
        /// ordinary in-place navigation, which is what ran before this existed.
        ///
        /// ponytail: one extra WebKit process for about a minute per episode.
        /// The ceiling is memory on older phones, where jetsam kills rather
        /// than warns; lower `standbyLeadSeconds` if that shows up in reports.
        private var standby: WKWebView?
        private var standbyURL: URL?
        private var standbyFrame: WKFrameInfo?
        /// The standby's own bridge identity for the frame holding its video,
        /// so the capability model can adopt it on promotion.
        private var standbyFrameID: String?
        private var standbyReady = false
        private var standbyNavigation: StandbyNavigation?
        /// The user asked for the episode the standby holds and it was not
        /// ready yet: the curtain is up for the standby, not for a navigation.
        private var waitingForStandby = false
        private static let standbyLeadSeconds: Double = 60

        init(model: BrowserModel, page: PageState,
             rules: RuleListController, settings: ProtectionSettings) {
            self.model = model
            self.page = page
            self.rules = rules
            self.settings = settings
            super.init()
            interruptions.start { [weak self] event in
                MainActor.assumeIsolated { self?.handle(interruption: event) }
            }
            // A second web view is the first thing to give up under pressure.
            // Only when nobody is waiting on it: then it is the transition.
            memoryWarning = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.waitingForStandby else { return }
                    self.discardStandby()
                }
            }
        }

        private var memoryWarning: NSObjectProtocol?
        deinit {
            if let memoryWarning { NotificationCenter.default.removeObserver(memoryWarning) }
        }

        /// iOS pauses the audio for an interruption and tells nobody, so a
        /// player that does not listen comes back claiming to play over
        /// silence. Headphones leaving is the one route change with a rule:
        /// always pause, because the alternative is the video suddenly playing
        /// out loud in a quiet room.
        private func handle(interruption event: AudioInterruptions.Event) {
            guard page.isTheater else { return }
            switch event {
            case .began:
                wasPlayingBeforeInterruption = page.isPlaying
                if page.isPlaying { togglePlay() }
            case .ended(let shouldResume):
                guard shouldResume, wasPlayingBeforeInterruption, !page.isPlaying else { break }
                wasPlayingBeforeInterruption = false
                togglePlay()
            case .outputDeviceLost:
                wasPlayingBeforeInterruption = false
                if page.isPlaying { togglePlay() }
            }
        }

        func observe(_ webView: WKWebView) {
            if !settings.privateBrowsing {
                webView.configuration.websiteDataStore.httpCookieStore.add(self)
            }
            observations = [
                webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] wv, _ in
                    MainActor.assumeIsolated { self?.page.isLoading = wv.isLoading }
                },
                webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] wv, _ in
                    MainActor.assumeIsolated { self?.page.canGoBack = wv.canGoBack }
                },
                webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] wv, _ in
                    MainActor.assumeIsolated { self?.page.canGoForward = wv.canGoForward }
                },
                // A hash route change is a navigation with no delegate
                // callbacks at all. The address and the next/previous links
                // both belong to the new route, and `didFinish` — where they
                // are normally refreshed — never runs for it.
                webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                    MainActor.assumeIsolated { self?.urlDidChange(wv) }
                },
            ]
        }

        private var routeRefresh: Task<Void, Never>?

        private func urlDidChange(_ webView: WKWebView) {
            guard !webView.isLoading, let url = webView.url else { return }
            loaded = url
            model.synchronizeCurrent(url)
            page.host = Self.displayHost(url)
            page.isSecure = url.scheme?.lowercased() == "https"
            // The app renders the new route after the URL changes, not before.
            routeRefresh?.cancel()
            routeRefresh = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, let webView = self.page.webView else { return }
                self.page.title = webView.title.map { Self.sanitizedForUI($0) } ?? self.page.title
                self.refreshEpisodes(webView)
            }
        }

        // MARK: Player controls (native chrome calls these)

        /// Runs in the frame that actually staged the video, not the main frame.
        private func callTheaterFrame(_ javaScript: String) {
            page.webView?.evaluateJavaScript(javaScript,
                                             in: theaterFrame,
                                             in: BrowserSetup.world,
                                             completionHandler: nil)
        }

        func exitTheater() {
            callTheaterFrame("window.__cp && window.__cp.exitTheater()")
            releaseHostPage()
            page.isTheater = false
            page.mediaVolumeAvailable = false
            // Nothing is playing now, so give the session back: .playback
            // interrupted whatever else was making sound, and only this ends
            // the interruption.
            MediaSession.deactivate()
        }

        /// Undoes `hostTheater()` in the main frame. Separate from
        /// `exitTheater()` because that one is addressed to the frame holding
        /// the video, which is usually not the main frame at all.
        private func releaseHostPage() {
            page.webView?.evaluateJavaScript(
                "window.__cp && window.__cp.unhostTheater()",
                in: nil, in: BrowserSetup.world, completionHandler: nil)
        }

        /// Addressed to the frame holding the video, like every other player
        /// control — the main frame's `window.__cp` is a different instance
        /// with no `staged` video.
        func togglePlay() {
            callPlayer("togglePlay()")
        }

        /// Every transport control goes to the frame holding the video. Values
        /// interpolated here are numbers this app computed, never page text.
        func callPlayer(_ call: String) {
            callTheaterFrame("window.__cp && window.__cp.\(call)")
        }

        func setOverlayBlocking(_ on: Bool) {
            page.overlayBlocking = on
            let js = "window.__cp && window.__cp.setOverlayBlocking(\(on))"
            let reportingFrames = blockedByFrame.frameIDs.compactMap { knownFrames[$0] }
            for frame in [nil] + reportingFrames.map(Optional.init) {
                page.webView?.evaluateJavaScript(js, in: frame,
                                                 in: BrowserSetup.world,
                                                 completionHandler: nil)
            }
            if !on {
                blockedByFrame.zeroAll()
                page.blockedCount = 0
            }
        }

        func showAirPlay() {
            callTheaterFrame("window.__cp && window.__cp.showAirPlay()")
        }

        /// Bank the resume position for whatever was playing, then forget it.
        /// Called when theater ends or the page changes underneath it.
        private func stopWatching() {
            if let url = watchingURL, lastDuration > 0 {
                model.saveResume(url, at: lastTime, duration: lastDuration)
            }
            watchingURL = nil
        }

        /// Snapshot the web view — the staged video fills it — into a poster.
        /// ponytail: DRM/protected frames come back black; the card falls back
        /// to the monogram, so a black poster is the worst case, not a crash.
        private func captureThumbnail(for url: URL) {
            guard let webView = page.webView else { return }
            let config = WKSnapshotConfiguration()
            config.snapshotWidth = 480          // points; a poster, not a frame grab
            webView.takeSnapshot(with: config) { image, _ in
                guard let data = image?.jpegData(compressionQuality: 0.7) else { return }
                Thumbnails.save(data, for: url)
            }
        }

        /// Episode links live in the top-level page, so navigation is done
        /// natively rather than by scripting a frame. Re-validated here: the
        /// URL came from page content and is only trusted as far as its host.
        func goToEpisode(_ destination: URL) {
            guard let webView = page.webView,
                  let current = webView.url,
                  EpisodeTransition.mayResume(expected: destination, current: current)
            else { return }

            // The site's controls are not ordinary links: their page-world
            // handlers replace the player iframe and update history via AJAX.
            // Calling this in our isolated content world can see the DOM but
            // does not execute in the JavaScript environment that owns that
            // lifecycle. Use the real control in the page world first.
            let direction: EpisodeDirection? = if destination == page.nextEpisode {
                .next
            } else if destination == page.previousEpisode {
                .previous
            } else {
                nil
            }
            let wasWatching = page.isTheater
            resumeTheaterFor = wasWatching ? destination : nil

            // The standby already holds this episode. Promote it now if it has
            // proven playback; otherwise hold the curtain for it — the video
            // on screen keeps playing underneath, nothing navigates.
            if wasWatching, standby != nil, standbyURL == destination {
                if standbyReady {
                    Self.transitionLog.notice("Standby ready; cutting to it")
                    promoteStandby()
                } else {
                    Self.transitionLog.notice("Standby not ready; waiting under the curtain")
                    waitingForStandby = true
                    beginResume(direction: direction)
                }
                return
            }
            // Anything else the user picked makes the standby stale.
            discardStandby()

            if wasWatching {
                resumeOutgoingFrame = theaterFrame
                resumeOutgoingSourceChanged = false
                beginResume(direction: direction)
                Self.transitionLog.notice("Episode transition armed on same-site destination")
            }
            if wasWatching {
                armOutgoingPlayer(in: webView) { [weak self] in
                    guard let self else { return }
                    if let direction {
                        self.activateSiteEpisodeControl(direction, destination: destination,
                                                        in: webView)
                    } else {
                        self.activateEpisodeLink(destination, in: webView)
                    }
                }
                return
            }

            // Ask the page to activate the link it supplied. Modern video
            // sites often attach an in-place episode switch to that click;
            // loading the href ourselves bypasses the router and visibly
            // leaves the player. If there is no matching anchor (for example,
            // discovery came from <link rel="next">), use the normal load.
            loadEpisodePage(destination, in: webView)
        }

        private func armOutgoingPlayer(in webView: WKWebView,
                                       completion: @escaping () -> Void) {
            guard let frame = resumeOutgoingFrame else {
                completion()
                return
            }
            webView.evaluateJavaScript(
                "window.__cp && window.__cp.armEpisodeTransition()",
                in: frame, in: BrowserSetup.world
            ) { _ in completion() }
        }

        private func activateSiteEpisodeControl(_ direction: EpisodeDirection,
                                                destination: URL,
                                                in webView: WKWebView) {
            webView.evaluateJavaScript(
                EpisodeTransition.siteControlScript(for: direction),
                in: nil, in: .page
            ) { [weak self] result in
                guard let self else { return }
                if case .success(let handled as Bool) = result, handled {
                    Self.transitionLog.notice("Site episode control handled transition")
                    return
                }
                Self.transitionLog.notice("Site control unavailable; trying episode link")
                self.activateEpisodeLink(destination, in: webView)
            }
        }

        private func activateEpisodeLink(_ destination: URL, in webView: WKWebView) {
            guard let encoded = try? JSONEncoder().encode(destination.absoluteString),
                  let json = String(data: encoded, encoding: .utf8) else {
                loadEpisodePage(destination, in: webView)
                return
            }
            webView.evaluateJavaScript(
                "window.__cp && window.__cp.navigateEpisode(\(json))",
                in: nil, in: BrowserSetup.world
            ) { [weak self] result in
                guard let self else { return }
                if case .success(let handled as Bool) = result, handled {
                    Self.transitionLog.notice("Episode link handled transition")
                    return
                }
                Self.transitionLog.notice("Falling back to validated episode URL load")
                self.loadEpisodePage(destination, in: webView)
            }
        }

        private func loadEpisodePage(_ destination: URL, in webView: WKWebView) {
            loaded = destination
            model.open(destination)
            webView.load(URLRequest(url: destination))
        }

        /// The curtain, and the deadline that guarantees it lifts.
        private func beginResume(direction: EpisodeDirection?) {
            page.episodeTransitionDirection = direction
            page.isResumingEpisode = true
            // Grab the picture before the page underneath changes. The
            // navigation waits on a JavaScript round trip, so this normally
            // lands while the old video is still on screen; if it does not,
            // the curtain is plain black, which is what it always was.
            page.transitionFrame = nil
            page.webView?.takeSnapshot(with: nil) { [weak self] image, _ in
                guard let self, self.page.isResumingEpisode else { return }
                self.page.transitionFrame = image
            }
            resumeArmTask?.cancel()
            // Keep the page covered until playback resumes or the user chooses
            // to reveal it. Giving up early is the bug: slow player iframes
            // made Next appear to redirect to a new webpage.
            resumeArmTask = Task { [weak self] in
                try? await Task.sleep(for: Self.armTimeout)
                guard !Task.isCancelled else { return }
                self?.endResume()
            }
        }

        /// Lifts the curtain, whatever the outcome. Safe to call more than once:
        /// theater arriving, the agent reporting failure, the watchdog firing
        /// and the user cancelling all land here.
        func endResume(keepingTheater: Bool = false) {
            resumeArmTask?.cancel()
            resumeArmTask = nil
            resumeTheaterFor = nil
            resumeOutgoingFrame = nil
            resumeOutgoingSourceChanged = false
            page.isResumingEpisode = false
            page.episodeTransitionDirection = nil
            page.transitionFrame = nil
            if waitingForStandby {
                // Timed out or "Show the page": the episode on screen was
                // never left, so it stays exactly as it was.
                waitingForStandby = false
                discardStandby()
                return
            }
            if !keepingTheater {
                page.isTheater = false
                releaseHostPage()
            }
        }

        // MARK: Warm standby

        private func armStandbyIfNear(currentTime: Double, duration: Double) {
            // The next link changed under an armed standby: it holds the wrong
            // episode now.
            if let standbyURL, standbyURL != page.nextEpisode { discardStandby() }
            guard standby == nil, duration > 0,
                  duration - currentTime < Self.standbyLeadSeconds,
                  let next = page.nextEpisode,
                  let primary = page.webView, let current = primary.url,
                  EpisodeTransition.mayResume(expected: next, current: current),
                  let container
            else { return }

            // The primary's configuration, so rule lists, user scripts, the
            // bridge and the data store are all shared: the standby is filtered
            // and reports to this same handler, distinguished by `message.webView`.
            // Media is gated behind a gesture there, though — see
            // makeStandbyConfiguration. It is off screen, and nothing off
            // screen should be making noise.
            let view = WKWebView(
                frame: container.bounds,
                configuration: BrowserSetup.makeStandbyConfiguration(from: primary.configuration))
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            let navigation = StandbyNavigation(site: next) { [weak self] in
                Self.transitionLog.notice("Standby failed to load; dropping it")
                self?.discardStandby()
            }
            view.navigationDelegate = navigation
            standbyNavigation = navigation
            // Behind the opaque primary: on screen as far as WebKit is
            // concerned, so its media is not suspended, and invisible to the user.
            container.insertSubview(view, at: 0)
            standby = view
            standbyURL = next
            standbyFrame = nil
            standbyReady = false
            view.load(URLRequest(url: next))
            Self.transitionLog.notice("Standby armed for the next episode")
        }

        private func discardStandby() {
            guard let view = standby else { return }
            view.navigationDelegate = nil
            view.stopLoading()
            view.removeFromSuperview()
            standby = nil
            standbyURL = nil
            standbyFrame = nil
            standbyFrameID = nil
            standbyReady = false
            standbyNavigation = nil
        }

        /// Messages from the standby never touch page state: it is not what
        /// the user is looking at. It gets exactly the resume treatment the
        /// primary would — every frame that announces is asked to stage — plus
        /// silence, and a pause once it has proven it can play.
        private func handleStandby(_ incoming: BridgeMessage, _ message: WKScriptMessage,
                                   frameID: String) {
            guard let view = standby else { return }
            switch incoming {
            case .ready:
                view.evaluateJavaScript(
                    "window.__cp && (window.__cp.setMuted(true), window.__cp.autoTheater())",
                    in: message.frameInfo, in: BrowserSetup.world, completionHandler: nil)
            case .theater:
                standbyFrame = message.frameInfo
                standbyFrameID = frameID
                if !message.frameInfo.isMainFrame {
                    view.evaluateJavaScript("window.__cp && window.__cp.hostTheater()",
                                            in: nil, in: BrowserSetup.world,
                                            completionHandler: nil)
                }
            case .theaterEnded:
                standbyFrame = nil
                standbyFrameID = nil
                standbyReady = false
            case .playback(let playing, _, _):
                guard playing, !standbyReady,
                      let frame = standbyFrame else { break }
                standbyReady = true
                // Proven. Park it at the start until it is wanted.
                view.evaluateJavaScript(
                    "window.__cp && (window.__cp.togglePlay(), window.__cp.seek(0))",
                    in: frame, in: BrowserSetup.world, completionHandler: nil)
                Self.transitionLog.notice("Standby proved playback")
                if waitingForStandby { promoteStandby() }
            default:
                break
            }
        }

        /// The cut. The standby becomes the page; the old web view leaves the
        /// hierarchy and is released, which is what stops its media.
        private func promoteStandby() {
            guard let new = standby, let url = standbyURL, let frame = standbyFrame,
                  let container else { return }
            let old = page.webView
            stopWatching()

            container.bringSubviewToFront(new)
            old?.navigationDelegate = nil
            old?.uiDelegate = nil
            old?.removeFromSuperview()

            let promotedFrameID = standbyFrameID
            standby = nil
            standbyURL = nil
            standbyFrame = nil
            standbyFrameID = nil
            standbyReady = false
            standbyNavigation = nil
            waitingForStandby = false

            new.navigationDelegate = self
            new.uiDelegate = self
            new.allowsBackForwardNavigationGestures = true
            // On screen now, and the user asked for this episode: the gesture
            // requirement the standby carried would otherwise block the play
            // that makes the cut look instant.
            new.configuration.mediaTypesRequiringUserActionForPlayback = []
            page.webView = new
            observe(new)
            theaterFrame = frame
            // The standby's frames are unknown to the capability model — it
            // ran its own bridge off screen. It is the page now, so its
            // player frame is adopted rather than made to claim theater again.
            clearFrameCapabilities()
            if let promotedFrameID,
               let origin = frame.request.url.flatMap(BridgeOrigin.init(url:))
                ?? new.url.flatMap(BridgeOrigin.init(url:)) {
                knownFrames[promotedFrameID] = frame
                frameCapabilities.adoptPlayer(BridgeFrame(
                    id: promotedFrameID, origin: origin,
                    width: 0, height: 0, isVisible: true,
                    isMainFrame: frame.isMainFrame))
            }
            let current = new.url ?? url
            loaded = current
            model.synchronizeCurrent(current)
            page.host = Self.displayHost(current)
            page.isSecure = current.scheme?.lowercased() == "https"
            page.title = new.title ?? ""
            page.loadError = nil
            page.blockedExternal = nil
            endResume(keepingTheater: true)
            page.isTheater = true
            page.playbackEnded = false
            callPlayer("setMuted(false)")
            callPlayer("setVolume(\(page.volumePercent))")
            callPlayer("togglePlay()")
            refreshEpisodes(new)
            beginWatching(current)
            Self.transitionLog.notice("Standby promoted; episode cut over")
        }

        /// The moment a page becomes a watched video: record it, and arm
        /// resume + thumbnail for the session in this player.
        private func beginWatching(_ url: URL) {
            // Now, not at launch: taking `.playback` on open ducked whatever
            // the user was listening to before they had chosen a video.
            MediaSession.activate()
            Diagnostics.count(.watchCleanSucceeded)
            guard !settings.privateBrowsing else { return }
            watchingURL = url
            model.recordWatched(url, title: page.webView?.title)
            pendingResumeAt = model.resume(for: url)
            didApplyResume = false
            lastTime = 0
            lastDuration = 0
            // Capture the poster on a short delay rather than on a time
            // update: a paused or already-finished video sends no
            // timeupdate, and would otherwise never get a thumbnail.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, self.page.isTheater, self.watchingURL == url else { return }
                self.captureThumbnail(for: url)
            }
        }

        /// The full episode list, for the player's episode picker. Asked of the
        /// MAIN frame: the links live in the site's page, never in the player
        /// frame. Every entry is re-validated against the current host before
        /// it is offered, exactly like next/previous.
        func refreshEpisodeList() {
            guard let webView = page.webView else { return }
            let js = siteScript(for: webView)
                + "JSON.stringify(window.__cp ? window.__cp.episodeList() : [])"
            webView.evaluateJavaScript(js, in: nil, in: BrowserSetup.world) { [weak self] result in
                guard let self,
                      case .success(let value) = result,
                      let json = value as? String,
                      let data = json.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: data)
                        as? [[String: Any]]
                else { return }

                let here = webView.url
                self.page.episodes = parsed.compactMap { entry in
                    guard let href = entry["href"] as? String,
                          let label = entry["label"] as? String,
                          let url = URL(string: href),
                          // Page-supplied, re-checked — and checked the SAME
                          // way everything else is. An exact host comparison
                          // here meant a site serving its player from
                          // player.example.com and its episodes from
                          // www.example.com got an empty list, while the very
                          // same URLs passed the check in goToEpisode.
                          HostKey.isSameSite(url, as: here)
                    else { return nil }
                    return PageState.Episode(
                        id: href, label: Self.sanitizedForUI(label, limit: 60),
                        current: entry["current"] as? Bool ?? false)
                }
            }
        }

        /// The registrable domain, handed to the agent so it and native agree
        /// on what "same site" means. The agent cannot work it out — that
        /// needs the Public Suffix List — so it stays at hostname equality
        /// until this arrives.
        private func siteScript(for webView: WKWebView) -> String {
            guard let host = webView.url?.host(),
                  let domain = HostKey.registrableDomain(host),
                  let encoded = try? JSONEncoder().encode(domain),
                  let json = String(data: encoded, encoding: .utf8)
            else { return "" }
            return "window.__cp && window.__cp.setSite(\(json)); "
        }

        /// Episode discovery always asks the MAIN frame — that is where the
        /// site's next/previous links live, not inside the player iframe.
        private func refreshEpisodes(_ webView: WKWebView) {
            let js = siteScript(for: webView)
                + "JSON.stringify(window.__cp ? window.__cp.findEpisodes() : {})"
            webView.evaluateJavaScript(js, in: nil, in: BrowserSetup.world) { [weak self] result in
                guard let self,
                      case .success(let value) = result,
                      let json = value as? String,
                      let data = json.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return }
                // Validated here, not merely where a navigation happens. These
                // URLs are page-supplied and go straight into the chrome; the
                // standby also loads whatever `nextEpisode` holds.
                let here = webView.url
                let sameSite = { (raw: String?) -> URL? in
                    guard let url = raw.flatMap(URL.init(string:)),
                          HostKey.isSameSite(url, as: here) else { return nil }
                    return url
                }
                self.page.nextEpisode = sameSite(parsed["next"] as? String)
                self.page.previousEpisode = sameSite(parsed["prev"] as? String)
                // Say which of the two silences this is. A site whose player
                // draws Next with JavaScript and no link — Jellyfin's own web
                // client among them — looks exactly like a page with one
                // episode, and the user can act on the difference.
                if self.page.nextEpisode == nil && self.page.previousEpisode == nil {
                    let offered = (parsed["next"] as? String) ?? (parsed["prev"] as? String)
                    self.page.episodeUnavailableReason = offered == nil
                        ? "No episode links on this page. Some sites draw Next "
                          + "and Previous with scripts rather than links, and "
                          + "those can't be found from here."
                        : "The episode links on this page point to another site."
                } else {
                    self.page.episodeUnavailableReason = nil
                }
                self.page.nextEpisodeIsEpisodic = self.page.nextEpisode != nil
                    && ["rel", "list"].contains(parsed["nextSource"] as? String ?? "")
            }
        }

        // MARK: Popup and redirect control

        /// Returning nil blocks the popunder. A same-site link tap is still
        /// honoured, in the current view rather than a new window.
        ///
        /// A user gesture is NOT enough on its own. The standard trick is an
        /// invisible full-size anchor over the video: the tap that looks like
        /// Play is a real gesture, and treating it as consent let the ad
        /// destination replace the page. Cross-site destinations are held and
        /// offered instead, so leaving the video is always a deliberate act.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            // Form submissions count too. Returning nil for them dropped a
            // legitimate `target="_blank"` form silently: no navigation, no
            // count, no offer — a button that did nothing and said nothing.
            guard navigationAction.navigationType == .linkActivated
                    || navigationAction.navigationType == .formSubmitted,
                  let url = navigationAction.request.url,
                  url.scheme?.hasPrefix("http") == true
            else { return nil }

            if HostKey.isSameSite(url, as: webView.url) {
                // The whole request, not a fresh one built from the URL: a
                // form's method and body live here, and rebuilding turns a
                // POST into a GET.
                webView.load(navigationAction.request)
            } else {
                page.blockedExternal = navigationAction.request
                page.popupsBlocked += 1
            }
            return nil
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url,
                  let scheme = url.scheme?.lowercased() else {
                decisionHandler(.cancel); return
            }
            // Never hand an unexpected scheme to another app.
            guard scheme == "https" || scheme == "http" || scheme == "about" else {
                if navigationAction.targetFrame?.isMainFrame == true {
                    page.loadError = "Blocked a link using the "
                        + "\(Self.sanitizedForUI(scheme, limit: 24)): scheme. "
                        + "Only web pages are opened."
                }
                decisionHandler(.cancel)
                return
            }
            if navigationAction.targetFrame?.isMainFrame == true {
                pendingMainFrameRequest = navigationAction.request
                // A provisional load must never retain the previous page's
                // padlock. Show the requested origin immediately, but only
                // restore the secure indicator after WebKit commits it.
                page.host = Self.displayHost(url)
                page.isSecure = false
                // The redirect popupguard cannot reach. It replaces window.open
                // and synthetic anchor clicks, but a plain `location.href = …`
                // on a timer goes through neither. While the user is watching,
                // a cross-site navigation the page started by itself is an ad
                // redirect, not something the user asked for — so it is offered
                // rather than followed, like a blocked popup.
                //
                // Scoped to theater on purpose. Outside it, cross-site `.other`
                // navigations are ordinary: SSO hops, link shorteners and
                // server redirects all look exactly the same from here.
                if page.isTheater, navigationAction.navigationType == .other,
                   !HostKey.isSameSite(url, as: webView.url) {
                    page.blockedExternal = navigationAction.request
                    page.popupsBlocked += 1
                    decisionHandler(.cancel)
                    return
                }

                // Per-site exceptions are applied here, before the load starts,
                // so this navigation already sees the right set of rules.
                rules.setSuspended(settings.isExempt(url.host() ?? ""))
            }
            decisionHandler(.allow)
        }

        func openBlockedRequest(_ request: URLRequest) {
            guard let webView = page.webView, let url = request.url else { return }
            page.blockedExternal = nil
            loaded = url
            model.synchronizeCurrent(url)
            // The URL only. The request the page built carried its method,
            // headers and body; "Open" means "show me where this goes", not
            // "replay the POST this page wrote".
            webView.load(URLRequest(url: url))
        }

        func retryFailedNavigation() {
            page.loadError = nil
            guard let webView = page.webView else { return }
            if let request = failedMainFrameRequest {
                pendingMainFrameRequest = request
                webView.load(request)
            } else {
                webView.reload()
            }
        }

        // MARK: Authentication and TLS

        /// Server trust is left to the system: the default handling rejects an
        /// invalid or untrusted certificate, and there is deliberately no path
        /// here that overrides it.
        ///
        /// Password challenges get a native prompt. This is how a home server
        /// behind nginx, Caddy or a NAS's own auth asks for a login, and the
        /// credential is kept (`.permanent`, keychain-backed) only for secure
        /// connections outside private browsing. Cleartext HTTP credentials
        /// always expire with the session and carry an explicit warning.
        func webView(_ webView: WKWebView,
                     didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                                   URLCredential?) -> Void) {
            switch challenge.protectionSpace.authenticationMethod {
            case NSURLAuthenticationMethodServerTrust:
                completionHandler(.performDefaultHandling, nil)
            case NSURLAuthenticationMethodHTTPBasic,
                 NSURLAuthenticationMethodHTTPDigest,
                 NSURLAuthenticationMethodNTLM:
                promptForLogin(challenge, in: webView, completionHandler: completionHandler)
            case NSURLAuthenticationMethodClientCertificate:
                completionHandler(.cancelAuthenticationChallenge, nil)
            default:
                completionHandler(.performDefaultHandling, nil)
            }
        }

        private func promptForLogin(_ challenge: URLAuthenticationChallenge, in webView: WKWebView,
                                    completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                                                  URLCredential?) -> Void) {
            guard let presenter = Self.presenter(for: webView) else {
                completionHandler(.cancelAuthenticationChallenge, nil); return
            }
            let space = challenge.protectionSpace
            let where_ = space.port == 80 || space.port == 443
                ? space.host : "\(space.host):\(space.port)"
            let message = [
                space.realm.flatMap { $0.isEmpty ? nil : Self.sanitizedForUI($0) },
                CredentialPolicy.warning(for: space),
            ].compactMap { $0 }.joined(separator: "\n\n")
            let alert = UIAlertController(
                title: challenge.previousFailureCount > 0 ? "Wrong username or password" : "Sign in to \(where_)",
                message: message.isEmpty ? nil : message,
                preferredStyle: .alert)
            alert.addTextField {
                $0.placeholder = "Username"
                $0.textContentType = .username
                $0.autocapitalizationType = .none
                $0.autocorrectionType = .no
                $0.text = challenge.proposedCredential?.user
            }
            alert.addTextField {
                $0.placeholder = "Password"
                $0.textContentType = .password
                $0.isSecureTextEntry = true
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                completionHandler(.cancelAuthenticationChallenge, nil)
            })
            // Pinned, secure and not private — see CredentialPolicy. A host
            // being on the local network is NOT enough: an address is not an
            // identity, and a page can put "Jellyfin — session expired" in a
            // realm string.
            let persistence = CredentialPolicy.persistence(
                for: space,
                isPinnedHost: model.isPinnedHost(space.host),
                privateBrowsing: settings.privateBrowsing)
            alert.addAction(UIAlertAction(title: "Sign In", style: .default) { [weak alert] _ in
                let fields = alert?.textFields ?? []
                let credential = URLCredential(user: fields.first?.text ?? "",
                                               password: fields.dropFirst().first?.text ?? "",
                                               persistence: persistence)
                completionHandler(.useCredential, credential)
            })
            presenter.present(alert, animated: true)
        }

        // MARK: Staying signed in

        /// WKWebView drops session cookies (no expiry) when the app quits, so a
        /// media server that keeps its login in one — Synology, Nextcloud, a
        /// NAS's web UI — asks for it again every launch.
        ///
        /// Cliqx will override that, but only where the user asked: a pinned
        /// site with "Stay signed in" switched on. Pinning alone was not
        /// enough. A session cookie is short-lived because the SERVER said so,
        /// and quietly giving a month's expiry to every auth and CSRF cookie
        /// on a pinned host means a stolen unlocked phone holds logins the
        /// server believed had ended. Nothing changes for any other site, and
        /// private browsing never registers this observer.
        ///
        /// ponytail: every cookie change re-reads the whole jar. Fine at this
        /// scale; index by domain if a site ever churns cookies fast enough to
        /// show up in a profile.
        nonisolated func cookiesDidChange(in store: WKHTTPCookieStore) {
            Task { @MainActor in
                let cookies = await store.allCookies()
                for cookie in cookies where cookie.isSessionOnly {
                    let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                    guard model.keepsSignIn(domain),
                          var properties = cookie.properties else { continue }
                    properties[.expires] = Date(timeIntervalSinceNow: 30 * 24 * 3600)
                    properties.removeValue(forKey: .discard)
                    properties.removeValue(forKey: .maximumAge)
                    if let kept = HTTPCookie(properties: properties) { await store.setCookie(kept) }
                }
            }
        }

        // MARK: Renderer recovery

        /// Without this the web content process dying leaves a white screen and
        /// no explanation — the view stays up, but nothing is in it.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            theaterFrame = nil
            clearFrameCapabilities()
            waitingForStandby = false
            discardStandby()   // shares the process; it died too
            endResume()   // also drops theater and the curtain

            guard let url = webView.url ?? loaded else {
                page.loadError = "This page stopped unexpectedly."
                return
            }
            guard recoveredFrom != url else {
                page.loadError = "This page keeps running out of memory. "
                    + "It may be too heavy for this device."
                return
            }
            recoveredFrom = url
            webView.reload()
        }

        // MARK: Navigation lifecycle

        func webView(_ webView: WKWebView,
                     didStartProvisionalNavigation navigation: WKNavigation!) {
            page.loadError = nil
            // The document that asked is going away; answer anything still
            // queued so no WebKit completion handler is left uncalled.
            drainDialogs()
            if let url = pendingMainFrameRequest?.url ?? webView.url {
                primeLocalNetwork(for: url)
            }
            // Leaving the page (including an episode change) banks where the
            // last video stopped before the old document goes away.
            stopWatching()
            if !waitingForStandby { discardStandby() }
            // The old frame handle dies with the old document.
            theaterFrame = nil
            clearFrameCapabilities()
            page.blockedCount = 0
            page.popupsBlocked = 0
            page.pageReportedPopups = 0
            page.blockedExternal = nil
            page.isTheater = false
            page.mediaVolumeAvailable = false
            page.mediaError = nil
            // Not simply `false`: goToEpisode arms the resume and starts the
            // load, so this fires with the curtain already up. Deriving it from
            // the armed destination also drops the curtain when some *other*
            // navigation — a typed URL, a link — replaces the episode change.
            page.isResumingEpisode = resumeTheaterFor != nil
            page.playbackEnded = false
            page.isPlaying = false
            page.isBuffering = false
            page.currentTime = 0
            page.duration = 0
            page.isLive = false
            page.bufferedTo = 0
            page.playbackRate = 1
            if resumeTheaterFor == nil { page.volumePercent = 100 }
            page.textTracks = []
            page.pipAvailable = false
            page.videoHeight = 0
            page.sources = []
            page.objectFit = "contain"
            page.episodes = []
            page.airplayAvailable = false
            page.airplayPickerSupported = false
            page.airplayCanSendVideo = true
            page.nextEpisode = nil
            page.previousEpisode = nil
            page.nextEpisodeIsEpisodic = false
            page.episodeUnavailableReason = nil
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            failedMainFrameRequest = pendingMainFrameRequest
            report(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                     withError error: Error) {
            failedMainFrameRequest = pendingMainFrameRequest
            report(error)
        }

        private func report(_ error: Error) {
            let ns = error as NSError
            // -999 is "a newer navigation replaced this one" — not a failure.
            guard ns.code != NSURLErrorCancelled else { return }
            // An episode that will not load has nothing to resume into.
            endResume()

            var message = switch ns.code {
            case NSURLErrorNotConnectedToInternet:
                "No internet connection."
            case NSURLErrorCannotFindHost:
                "Server not found. The domain may no longer exist — sites that "
                + "move between domains often leave dead links behind."
            case NSURLErrorCannotConnectToHost:
                "Couldn't connect to the server. It may be down or blocked on "
                + "this network."
            case NSURLErrorTimedOut:
                "The server took too long to respond."
            case NSURLErrorSecureConnectionFailed,
                 NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateHasUnknownRoot:
                "Secure connection failed. The site's HTTPS certificate is not "
                + "valid, so the app refused to continue."
            case NSURLErrorAppTransportSecurityRequiresSecureConnection:
                "This site is HTTP-only. The app requires HTTPS."
            case NSURLErrorUserCancelledAuthentication:
                "This site asks for a username and password. "
                + "Cliqx does not sign in to sites."
            default:
                ns.localizedDescription
            }

            // A home server fails differently from a website, and the generic
            // "couldn't connect" hides the usual cause: iOS gates every
            // local-network connection behind a permission the Simulator does
            // not enforce, so this works in testing and dies on the device with
            // nothing to say why. Name the two things worth checking.
            let failingHost = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.host()
                ?? page.webView?.url?.host() ?? ""
            let reachability = [NSURLErrorCannotConnectToHost, NSURLErrorTimedOut,
                                NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost]
            if AddressResolver.isLocalHost(failingHost), reachability.contains(ns.code) {
                message = "Couldn't reach \(failingHost) on your local network.\n\n"
                    + "Check that Local Network is turned on for Cliqx in "
                    + "Settings, and that this device is on the same Wi\u{2011}Fi "
                    + "as the server."
            }
            page.loadError = message
        }

        /// Hosts already probed, so one request is made per host, not per load.
        private var primedLocalHosts: Set<String> = []

        /// Ask iOS for local-network access at the moment it is needed.
        ///
        /// A `WKWebView` load runs in WebKit's networking process, which does
        /// not reliably raise the Local Network prompt — so the app can be
        /// refused without the user ever being asked, and may not even appear
        /// under Settings > Local Network to be switched on. A single request
        /// from the *app's own* process is what registers it and triggers the
        /// prompt. The result is deliberately ignored; causing the prompt is
        /// the entire point.
        private func primeLocalNetwork(for url: URL) {
            guard let host = url.host(), AddressResolver.isLocalHost(host),
                  !primedLocalHosts.contains(host) else { return }
            primedLocalHosts.insert(host)
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 4
            localNetworkProbeSession.dataTask(with: request).resume()
        }

        /// The origin indicator has to change with the document, not two
        /// seconds later when it finishes loading. Setting it in `didFinish`
        /// alone left the previous page's host and its padlock on screen for
        /// the whole of the next load — and left them there permanently when
        /// the load failed, which is exactly when they must not be trusted.
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            if let url = webView.url {
                loaded = url
                model.synchronizeCurrent(url)
            }
            failedMainFrameRequest = nil
            page.host = Self.displayHost(webView.url)
            page.isSecure = webView.url?.scheme?.lowercased() == "https"
        }

        /// `HostKey.canonical` rather than stripping "www." anywhere it appears:
        /// that also ate the one in `wwww.example.com` and in any host with the
        /// sequence in the middle.
        private static func displayHost(_ url: URL?) -> String {
            guard let host = url?.host() else { return "" }
            return HostKey.canonical(host) ?? host
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let url = webView.url
            if let url {
                loaded = url
                model.synchronizeCurrent(url)
            }
            pendingMainFrameRequest = nil
            page.host = Self.displayHost(url)
            page.title = Self.sanitizedForUI(webView.title ?? "")
            page.isSecure = url?.scheme?.lowercased() == "https"
            // Recents are videos you watched, not pages you visited — the
            // entry is recorded when theater opens, not on navigation.

            recoveredFrom = nil
            refreshEpisodes(webView)
        }

        // MARK: Page agent

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            do {
                let envelope = try BridgeEnvelope.decode(body: message.body)
                // The standby shares this bridge and is not what the user is
                // looking at: it keeps its own small state machine and never
                // touches page state or the capability model.
                if let standby, message.webView === standby {
                    handleStandby(envelope.message, message, frameID: envelope.frameID)
                    return
                }
                // A web view that was swapped out is still tearing down and
                // still talks through the shared bridge. Nothing it says is
                // about what is on screen any more.
                guard message.webView === page.webView else { return }
                if envelope.message.kind == .frameGone {
                    removeFrame(id: envelope.frameID)
                    return
                }
                guard bridgeRateLimiter.allow(
                    envelope.message.kind,
                    from: envelope.frameID,
                    at: ProcessInfo.processInfo.systemUptime)
                else {
                    droppedRateLimitedMessages += 1
                    // Avoid turning a hostile flood into an equally expensive
                    // unified-log flood. The counter retains the exact total.
                    if droppedRateLimitedMessages == 1
                        || droppedRateLimitedMessages.isMultiple(of: 1_000) {
                        let total = droppedRateLimitedMessages
                        Self.bridgeLog.notice(
                            "Rate-limited page bridge messages; total: \(total)")
                    }
                    return
                }
                if envelope.message.kind == .ready {
                    guard let metrics = envelope.metrics else {
                        throw BridgeMessage.ValidationError.malformedPayload
                    }
                    registerFrame(
                        id: envelope.frameID,
                        frameInfo: message.frameInfo,
                        metrics: metrics)
                } else if let metrics = envelope.metrics,
                          knownFrames[envelope.frameID] != nil {
                    registerFrame(
                        id: envelope.frameID,
                        frameInfo: message.frameInfo,
                        metrics: metrics)
                }

                guard frameCapabilities.authorize(
                    envelope.message.kind,
                    from: envelope.frameID,
                    mainOrigin: page.webView?.url.flatMap(BridgeOrigin.init(url:)))
                else {
                    droppedSpectatorMessages += 1
                    Self.bridgeLog.notice(
                        "Dropped spectator bridge message; total: \(self.droppedSpectatorMessages)")
                    return
                }

                handle(
                    envelope.message,
                    from: message.frameInfo,
                    frameID: envelope.frameID)
                if envelope.message.kind == .theaterEnded {
                    frameCapabilities.releasePlayer(frameID: envelope.frameID)
                }
            } catch {
                Self.bridgeLog.error(
                    "Rejected page bridge message: \(error.localizedDescription, privacy: .public)")
            }
        }

        private func registerFrame(
            id: String,
            frameInfo: WKFrameInfo,
            metrics: BridgeEnvelope.FrameMetrics
        ) {
            knownFrames[id] = frameInfo
            let securityOrigin = frameInfo.securityOrigin
            frameCapabilities.register(BridgeFrame(
                id: id,
                origin: BridgeOrigin(
                    scheme: securityOrigin.protocol,
                    host: securityOrigin.host,
                    port: securityOrigin.port == 0 ? nil : securityOrigin.port),
                width: metrics.width,
                height: metrics.height,
                isVisible: metrics.isVisible,
                isMainFrame: frameInfo.isMainFrame))
        }

        private func clearFrameCapabilities() {
            knownFrames.removeAll()
            frameCapabilities.reset()
            blockedByFrame.reset()
            bridgeRateLimiter.reset()
            page.blockedCount = 0
        }

        private func removeFrame(id: String) {
            knownFrames.removeValue(forKey: id)
            if frameCapabilities.remove(frameID: id) {
                theaterFrame = nil
            }
            blockedByFrame.remove(frameID: id)
            bridgeRateLimiter.remove(frameID: id)
            page.blockedCount = blockedByFrame.total
        }

        private func handle(
            _ message: BridgeMessage,
            from frameInfo: WKFrameInfo,
            frameID: String
        ) {
            switch message {
            // Every frame announces itself once. Resuming theater after an
            // episode change has to happen in the frame holding the video, and
            // on these sites that is a cross-origin iframe — the main frame has
            // no <video> at all, so asking it was asking the wrong document.
            // `resumeTheater` is cleared by the theater message rather than
            // here, so a frame without a video simply finds nothing and the one
            // that has it still gets asked.
            case .ready:
                // Scoped to the destination, which is what the property was
                // always documented to be: checking only for non-nil meant a
                // resume armed for one episode could fire on whatever page
                // happened to load next.
                guard let armed = resumeTheaterFor,
                      let current = page.webView?.url,
                      EpisodeTransition.mayResume(expected: armed, current: current)
                else { break }
                Self.transitionLog.notice("Player frame ready during episode transition")
                page.webView?.evaluateJavaScript(
                    "window.__cp && window.__cp.autoTheater()",
                    in: frameInfo, in: BrowserSetup.world,
                    completionHandler: nil)

            case .frameGone:
                // Lifecycle messages are consumed before dispatch.
                break

            // One frame holds theater at a time. A second frame announcing —
            // an ad iframe whose <video> the resume poll happened to like —
            // does not take the controls away from the one that has them;
            // `FrameCapabilityModel` refuses the claim before this runs.
            case .theater(let airplay, let pip):
                // Remember WHICH frame staged the video. Everything the native
                // chrome does afterwards is addressed to this frame.
                theaterFrame = frameInfo
                endResume(keepingTheater: true)
                page.isTheater = true
                page.mediaVolumeAvailable = false
                page.mediaError = nil
                callPlayer("setVolume(\(page.volumePercent))")
                page.playbackEnded = false
                page.airplayAvailable = airplay
                page.pipAvailable = pip
                if let webView = page.webView { refreshEpisodes(webView) }

                if let url = page.webView?.url { beginWatching(url) }

                // A player in a cross-origin frame stages the video against
                // that frame's document and can reach no further. The host
                // page's own header, server list and comments would stay on
                // screen under the native controls — which is what "Watch
                // clean did nothing but add a close button" looks like. Tell
                // the main frame to stage the player frame itself.
                if !frameInfo.isMainFrame {
                    page.webView?.evaluateJavaScript(
                        "window.__cp && window.__cp.hostTheater()",
                        in: nil, in: BrowserSetup.world, completionHandler: nil)
                }
            case .theaterEnded:
                theaterFrame = nil
                // Not during an episode handoff: the next player is moments
                // away and bouncing the session would duck the audio twice.
                if resumeTheaterFor == nil { MediaSession.deactivate() }
                if resumeTheaterFor != nil {
                    Self.transitionLog.notice("Old player frame ended; preserving theater transition")
                    stopWatching()
                    break
                }
                releaseHostPage()
                page.isTheater = false
                page.mediaVolumeAvailable = false
                stopWatching()
            // The agent gave up finding a video to resume into. Only the frame
            // that was actually asked reports this, so the curtain comes down
            // on a real answer rather than on the watchdog's deadline.
            case .mediaError(let reason):
                // The curtain came up on a black rectangle with working-looking
                // controls. Say what happened instead.
                page.mediaError = reason.message
                endResume()
            case .theaterFailed:
                // Stay covered and armed. This is usually the main document,
                // while the real player iframe announces later. Revealing the
                // page here is what made Next look like a redirect.
                Self.transitionLog.debug("A frame has not found the replacement video yet")
                break
            case .watchCleanTapped:
                Diagnostics.count(.watchCleanAttempted)
            case .ended:
                page.playbackEnded = true
                page.isPlaying = false
                page.isBuffering = false
            case .blocked(let count):
                blockedByFrame.update(frameID: frameID, count: count)
                page.blockedCount = blockedByFrame.total
            case .popupBlocked:
                page.pageReportedPopups = min(page.pageReportedPopups + 1,
                                              PageState.pageReportedPopupCap)
            case .playback(let playing, let buffering, let armed):
                page.isPlaying = playing
                page.isBuffering = buffering
                // An SPA may keep the same staged <video> and only replace its
                // source. There is no new theater message in that case; fresh
                // playback is the successful handoff signal.
                if playing, resumeTheaterFor != nil {
                    if EpisodeTransition.playbackCompletesResume(
                        isFromOutgoingFrame: armed,
                        outgoingSourceChanged: resumeOutgoingSourceChanged) {
                        Self.transitionLog.notice("Episode transition resumed playback")
                        endResume(keepingTheater: true)
                    } else {
                        Self.transitionLog.debug("Ignored stale playback from outgoing frame")
                    }
                }
                // Replaying, or seeking back out of the end, retracts the offer.
                if playing { page.playbackEnded = false }
            case .episodeSourceChanged(let playing):
                // Only the armed frame posts this, so no frame check is needed —
                // nor possible: WKFrameInfo has no value equality.
                guard resumeTheaterFor != nil else { break }
                resumeOutgoingSourceChanged = true
                Self.transitionLog.notice("Outgoing frame confirmed a new episode source")
                if playing {
                    endResume(keepingTheater: true)
                }
            case .volume(let percent, _, let available):
                page.volumePercent = percent
                page.mediaVolumeAvailable = available
            case .time(let at, let duration, let live, let buffered, let rate):
                page.currentTime = at
                page.duration = duration
                page.isLive = live
                page.bufferedTo = buffered
                page.playbackRate = rate

                if page.isTheater {
                    armStandbyIfNear(currentTime: page.currentTime, duration: page.duration)
                }
                if page.isTheater, watchingURL != nil {
                    lastTime = page.currentTime
                    lastDuration = page.duration
                    // Resume once, only after the video is long enough to be
                    // seekable and not within the last few seconds.
                    if !didApplyResume, pendingResumeAt > 3,
                       page.duration > 0, pendingResumeAt < page.duration - 5 {
                        didApplyResume = true
                        callTheaterFrame("window.__cp && window.__cp.seek(\(pendingResumeAt))")
                    }
                }
            case .video(let info):
                page.videoHeight = info.height
                page.objectFit = info.fit
                page.sources = info.sources.map { source in
                    PageState.VideoSource(
                        id: source.index,
                        label: Self.sanitizedForUI(source.label, limit: 40),
                        active: source.active)
                }
            case .tracks(let tracks):
                page.textTracks = tracks.map { track in
                    PageState.TextTrack(
                        id: track.index,
                        label: Self.sanitizedForUI(track.label, limit: 40),
                        active: track.active)
                }
            case .airplay(let available, let source):
                page.airplayAvailable = available
                page.airplayCanSendVideo = source != "mse"
            // Sent once when a video is staged: the picker capability and the
            // stream kind, both known before any route appears.
            case .airplaySupport(let picker, let source):
                page.airplayPickerSupported = picker
                page.airplayCanSendVideo = source != "mse"
            }
        }

        // MARK: JavaScript dialogs

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping () -> Void) {
            var answered = false
            let answer = { if !answered { answered = true; completionHandler() } }
            let alert = UIAlertController(
                title: Self.dialogTitle(for: frame),
                message: Self.sanitizedForUI(message), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                answer()
                self?.dialogFinished()
            })
            presentDialog(alert, completing: answer)
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (Bool) -> Void) {
            var answered = false
            let answer = { (value: Bool) in
                if !answered { answered = true; completionHandler(value) }
            }
            let alert = UIAlertController(
                title: Self.dialogTitle(for: frame),
                message: Self.sanitizedForUI(message), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
                answer(false)
                self?.dialogFinished()
            })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                answer(true)
                self?.dialogFinished()
            })
            presentDialog(alert) { answer(false) }
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            var answered = false
            let answer = { (value: String?) in
                if !answered { answered = true; completionHandler(value) }
            }
            let alert = UIAlertController(
                title: Self.dialogTitle(for: frame),
                message: Self.sanitizedForUI(prompt), preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText.map { Self.sanitizedForUI($0) } }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
                answer(nil)
                self?.dialogFinished()
            })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self, weak alert] _ in
                answer(alert?.textFields?.first?.text)
                self?.dialogFinished()
            })
            presentDialog(alert) { answer(nil) }
        }

        /// Page-supplied text for native UI. See `PageText`.
        static func sanitizedForUI(_ value: String, limit: Int = 120) -> String {
            PageText.sanitized(value, limit: limit)
        }

        private static func dialogTitle(for frame: WKFrameInfo) -> String {
            let host = frame.request.url?.host().flatMap(HostKey.canonical) ?? "this page"
            return "Message from \(host)"
        }

        /// One dialog at a time, and every completion handler called exactly
        /// once.
        ///
        /// WebKit's `alert()` is synchronous: the frame's JavaScript is
        /// suspended until the handler runs. UIKit refuses to present over a
        /// controller that is already presenting, so a second dialog — another
        /// frame, a sheet mid-transition, an auth challenge arriving during an
        /// alert — logged "already presenting" and dropped the presentation,
        /// and with it the handler. That frame was then frozen for good.
        private var dialogQueue: [(UIViewController, () -> Void)] = []
        private var dialogShowing = false

        /// Presents now, or waits for the one on screen to finish. `fallback`
        /// runs if the dialog can never be shown, so the page is answered
        /// rather than left waiting.
        private func presentDialog(_ alert: UIAlertController,
                                   completing fallback: @escaping () -> Void) {
            dialogQueue.append((alert, fallback))
            presentNextDialog()
        }

        private func presentNextDialog() {
            guard !dialogShowing, !dialogQueue.isEmpty else { return }
            let (alert, fallback) = dialogQueue.removeFirst()
            guard let presenter = Self.presenter(for: page.webView),
                  presenter.presentedViewController == nil else {
                // Still busy: put it back and wait for the current one to go.
                // A presenter that never frees up is covered by the page's own
                // dismissal, since the queue is drained on navigation.
                if Self.presenter(for: page.webView) == nil {
                    fallback()
                    presentNextDialog()
                } else {
                    dialogQueue.insert((alert, fallback), at: 0)
                }
                return
            }
            dialogShowing = true
            presenter.present(alert, animated: true)
        }

        /// Called from every action, after the handler the action carries.
        private func dialogFinished() {
            dialogShowing = false
            presentNextDialog()
        }

        /// A navigation replaces the document that asked. Answer anything still
        /// queued so no handler is dropped.
        private func drainDialogs() {
            let pending = dialogQueue
            dialogQueue.removeAll()
            for (_, fallback) in pending { fallback() }
        }

        private static func presenter(for webView: WKWebView?) -> UIViewController? {
            guard let webView else { return nil }
            return presenter(for: webView)
        }

        private static func presenter(for webView: WKWebView) -> UIViewController? {
            var current = webView.window?.rootViewController
            while let presented = current?.presentedViewController { current = presented }
            if let navigation = current as? UINavigationController {
                return navigation.visibleViewController ?? navigation
            }
            if let tabs = current as? UITabBarController {
                return tabs.selectedViewController ?? tabs
            }
            return current
        }
    }

    /// The standby's navigation delegate. Lets the destination site load and
    /// nothing else, and never touches page state — the standby is not what
    /// the user is looking at. Auth falls to WebKit's default handling, which
    /// replays a credential the user already saved.
    @MainActor
    final class StandbyNavigation: NSObject, WKNavigationDelegate {
        private let site: URL
        private let failed: () -> Void

        init(site: URL, failed: @escaping () -> Void) {
            self.site = site
            self.failed = failed
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            else { decisionHandler(.cancel); return }
            // Subframes go anywhere the rule lists allow; the document itself
            // stays on the site it was armed for.
            if navigationAction.targetFrame?.isMainFrame == true,
               !HostKey.isSameSite(url, as: site) {
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) { failed() }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                     withError error: Error) { failed() }
    }
}
