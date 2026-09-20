import CleanPlayer
import MediaPlayer
import os
import SwiftUI
import UIKit
import WebKit

/// Bridges website playback to the iPhone's real output volume. WebKit on iOS
/// deliberately ignores JavaScript writes to HTMLMediaElement.volume.
@MainActor
private final class SystemVolumeController {
    static let shared = SystemVolumeController()
    private let volumeView = MPVolumeView(frame: .zero)

    func set(percent: Int) {
        let value = Float(min(max(percent, 0), 100)) / 100
        guard let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else {
            return
        }
        slider.setValue(value, animated: false)
        slider.sendActions(for: .valueChanged)
    }
}

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

    @Published var isTheater = false
    /// An episode change is in flight and theater is expected to come back.
    /// The player chrome stays up as a curtain over it: without this the raw
    /// page — header, ads, the lot — flashes into view between episodes, which
    /// is the whole thing theater exists to avoid.
    @Published var isResumingEpisode = false
    /// Drives the transition curtain copy. Kept separate from the destination
    /// URL so Previous never announces itself as Next.
    @Published var episodeTransitionDirection: EpisodeDirection?

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
    @Published var currentTime: Double = 0
    /// 0 both for a live stream and before metadata arrives. `isLive`
    /// separates them: only one of those deserves a LIVE badge.
    @Published var duration: Double = 0
    @Published var isLive = false
    @Published var bufferedTo: Double = 0
    @Published var playbackRate: Double = 1
    /// Per-video level. 100 is normal; 101...200 is software amplification.
    @Published var volumePercent = 100
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
    @Published var overlayBlocking = true
    @Published var blockedCount = 0
    /// Popups the page agent stopped, plus the ones native held. Two counters,
    /// because they measure different things and the page-world one is polled
    /// rather than pushed.
    @Published var popupsBlocked = 0
    /// Held by native: cross-site windows and cancelled redirects. Kept apart
    /// from the page's own tally, which arrives as an absolute value — adding
    /// it in would be overwritten on the next poll.
    var nativePopupsBlocked = 0
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

    func makeUIView(context: Context) -> WKWebView {
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
                SystemVolumeController.shared.set(percent: safe)
                coordinator?.page.volumePercent = safe
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
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Only reload when the model points somewhere new, or every state
        // change would restart the page.
        guard context.coordinator.loaded != url else { return }
        context.coordinator.loaded = url
        webView.load(URLRequest(url: url))
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

        /// Frames that reported blocking something. Toggling has to reach each
        /// of them: `evaluateJavaScript(in: nil)` only ever hits the main frame,
        /// and interstitials are frequently inside an ad iframe.
        private var blockingFrames: [WKFrameInfo] = []

        /// Resume + thumbnail bookkeeping for the video currently in theater.
        /// The URL is the watch page; last time/duration are saved when the
        /// user leaves so the card can resume and show progress.
        private var watchingURL: URL?
        private var lastTime: Double = 0
        private var lastDuration: Double = 0
        private var pendingResumeAt: Double = 0
        private var didApplyResume = false

        init(model: BrowserModel, page: PageState,
             rules: RuleListController, settings: ProtectionSettings) {
            self.model = model
            self.page = page
            self.rules = rules
            self.settings = settings
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
                self.page.title = webView.title ?? self.page.title
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
            for frame in [nil] + blockingFrames.map(Optional.init) {
                page.webView?.evaluateJavaScript(js, in: frame,
                                                 in: BrowserSetup.world,
                                                 completionHandler: nil)
            }
            if !on { page.blockedCount = 0 }
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
            if !keepingTheater {
                page.isTheater = false
                releaseHostPage()
            }
        }

        /// The full episode list, for the player's episode picker. Asked of the
        /// MAIN frame: the links live in the site's page, never in the player
        /// frame. Every entry is re-validated against the current host before
        /// it is offered, exactly like next/previous.
        func refreshEpisodeList() {
            guard let webView = page.webView else { return }
            let js = "JSON.stringify(window.__cp ? window.__cp.episodeList() : [])"
            webView.evaluateJavaScript(js, in: nil, in: BrowserSetup.world) { [weak self] result in
                guard let self,
                      case .success(let value) = result,
                      let json = value as? String,
                      let data = json.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: data)
                        as? [[String: Any]]
                else { return }

                let host = webView.url?.host()
                self.page.episodes = parsed.compactMap { entry in
                    guard let href = entry["href"] as? String,
                          let label = entry["label"] as? String,
                          let url = URL(string: href),
                          url.host() == host          // page-supplied, re-checked
                    else { return nil }
                    return PageState.Episode(
                        id: href, label: label,
                        current: entry["current"] as? Bool ?? false)
                }
            }
        }

        /// Episode discovery always asks the MAIN frame — that is where the
        /// site's next/previous links live, not inside the player iframe.
        private func refreshEpisodes(_ webView: WKWebView) {
            let js = "JSON.stringify(window.__cp ? window.__cp.findEpisodes() : {})"
            webView.evaluateJavaScript(js, in: nil, in: BrowserSetup.world) { [weak self] result in
                guard let self,
                      case .success(let value) = result,
                      let json = value as? String,
                      let data = json.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return }
                self.page.nextEpisode = (parsed["next"] as? String).flatMap(URL.init(string:))
                self.page.previousEpisode = (parsed["prev"] as? String).flatMap(URL.init(string:))
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
                page.nativePopupsBlocked += 1
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
                    page.loadError = "Blocked a link using the \(scheme): scheme. "
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
                    page.nativePopupsBlocked += 1
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
            webView.load(request)
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
        /// credential is kept (`.permanent`, keychain-backed) so it is not
        /// asked for again next launch — unless private browsing is on, where
        /// it lasts the session like everything else.
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
            let alert = UIAlertController(
                title: challenge.previousFailureCount > 0 ? "Wrong username or password" : "Sign in to \(where_)",
                message: space.realm.flatMap { $0.isEmpty ? nil : $0 },
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
            let persistence: URLCredential.Persistence = settings.privateBrowsing ? .forSession : .permanent
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
        /// NAS's web UI — asks for it again every launch. On the user's own
        /// servers, pinned sites and local addresses, the cookie is re-set
        /// with an expiry so the login survives. Nothing changes for any other
        /// site, and private browsing never registers this observer.
        ///
        /// ponytail: every cookie change re-reads the whole jar. Fine at this
        /// scale; index by domain if a site ever churns cookies fast enough to
        /// show up in a profile.
        nonisolated func cookiesDidChange(in store: WKHTTPCookieStore) {
            Task { @MainActor in
                let mine = Set(model.pinned.compactMap { $0.url.host() })
                let cookies = await store.allCookies()
                for cookie in cookies where cookie.isSessionOnly {
                    let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                    guard mine.contains(domain) || AddressResolver.isLocalHost(domain),
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
            blockingFrames.removeAll()
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
            if let url = pendingMainFrameRequest?.url ?? webView.url {
                primeLocalNetwork(for: url)
            }
            // Leaving the page (including an episode change) banks where the
            // last video stopped before the old document goes away.
            stopWatching()
            // The old frame handle dies with the old document.
            theaterFrame = nil
            blockingFrames.removeAll()
            page.blockedCount = 0
            page.popupsBlocked = 0
            page.nativePopupsBlocked = 0
            page.blockedExternal = nil
            page.isTheater = false
            // Not simply `false`: goToEpisode arms the resume and starts the
            // load, so this fires with the curtain already up. Deriving it from
            // the armed destination also drops the curtain when some *other*
            // navigation — a typed URL, a link — replaces the episode change.
            page.isResumingEpisode = resumeTheaterFor != nil
            page.playbackEnded = false
            page.isPlaying = false
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
            page.title = webView.title ?? ""
            page.isSecure = url?.scheme?.lowercased() == "https"
            // Recents are videos you watched, not pages you visited — the
            // entry is recorded when theater opens, not on navigation.

            recoveredFrom = nil
            refreshEpisodes(webView)
            // The guard lives in the page world, so it is read rather than
            // reporting through the bridge.
            webView.evaluateJavaScript("window.__cpPopupsBlocked || 0",
                                       in: nil, in: .page) { [weak self] result in
                if case .success(let value) = result {
                    // Assigning here erased every native block that landed
                    // during the load — a count that went down as you watched.
                    guard let self else { return }
                    self.page.popupsBlocked =
                        (value as? Int ?? 0) + self.page.nativePopupsBlocked
                }
            }

        }

        // MARK: Page agent

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            do {
                let bridgeMessage = try BridgeMessage.decode(body: message.body)
                handle(bridgeMessage, from: message.frameInfo)
            } catch {
                Self.bridgeLog.error(
                    "Rejected page bridge message: \(error.localizedDescription, privacy: .public)")
            }
        }

        private func handle(_ message: BridgeMessage, from frameInfo: WKFrameInfo) {
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

            case .theater(let airplay, let pip):
                // Remember WHICH frame staged the video. Everything the native
                // chrome does afterwards is addressed to this frame.
                theaterFrame = frameInfo
                endResume(keepingTheater: true)
                page.isTheater = true
                callPlayer("setVolume(\(page.volumePercent))")
                page.playbackEnded = false
                page.airplayAvailable = airplay
                page.pipAvailable = pip
                if let webView = page.webView { refreshEpisodes(webView) }

                // This is the moment a page becomes a watched video. Record it,
                // and arm resume + thumbnail for the session in this player.
                if let url = page.webView?.url, !settings.privateBrowsing {
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
                if resumeTheaterFor != nil {
                    Self.transitionLog.notice("Old player frame ended; preserving theater transition")
                    stopWatching()
                    break
                }
                releaseHostPage()
                page.isTheater = false
                stopWatching()
            // The agent gave up finding a video to resume into. Only the frame
            // that was actually asked reports this, so the curtain comes down
            // on a real answer rather than on the watchdog's deadline.
            case .theaterFailed:
                // Stay covered and armed. This is usually the main document,
                // while the real player iframe announces later. Revealing the
                // page here is what made Next look like a redirect.
                Self.transitionLog.debug("A frame has not found the replacement video yet")
                break
            case .ended:
                page.playbackEnded = true
                page.isPlaying = false
            case .blocked(let count):
                page.blockedCount = count
                if page.blockedCount > 0,
                   !blockingFrames.contains(where: { $0 == frameInfo }) {
                    blockingFrames.append(frameInfo)
                }
            case .playback(let playing, let armed):
                page.isPlaying = playing
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
            case .volume(let percent, _):
                page.volumePercent = percent
            case .time(let at, let duration, let live, let buffered, let rate):
                page.currentTime = at
                page.duration = duration
                page.isLive = live
                page.bufferedTo = buffered
                page.playbackRate = rate

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
                        id: source.index, label: source.label, active: source.active)
                }
            case .tracks(let tracks):
                page.textTracks = tracks.map { track in
                    PageState.TextTrack(
                        id: track.index, label: track.label, active: track.active)
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
            guard let presenter = Self.presenter(for: webView) else {
                completionHandler(); return
            }
            let alert = UIAlertController(title: Self.dialogTitle(for: frame),
                                          message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
            presenter.present(alert, animated: true)
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (Bool) -> Void) {
            guard let presenter = Self.presenter(for: webView) else {
                completionHandler(false); return
            }
            let alert = UIAlertController(title: Self.dialogTitle(for: frame),
                                          message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
            presenter.present(alert, animated: true)
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            guard let presenter = Self.presenter(for: webView) else {
                completionHandler(nil); return
            }
            let alert = UIAlertController(title: Self.dialogTitle(for: frame),
                                          message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
                completionHandler(alert?.textFields?.first?.text)
            })
            presenter.present(alert, animated: true)
        }

        private static func dialogTitle(for frame: WKFrameInfo) -> String {
            let host = frame.request.url?.host().flatMap(HostKey.canonical) ?? "this page"
            return "Message from \(host)"
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
}
