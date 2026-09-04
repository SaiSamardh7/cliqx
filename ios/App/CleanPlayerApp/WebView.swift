import CleanPlayer
import SwiftUI
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

    @Published var isTheater = false
    /// An episode change is in flight and theater is expected to come back.
    /// The player chrome stays up as a curtain over it: without this the raw
    /// page — header, ads, the lot — flashes into view between episodes, which
    /// is the whole thing theater exists to avoid.
    @Published var isResumingEpisode = false
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
    @Published var blockedExternal: URL?

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
        var selectTrack: (Int) -> Void = { _ in }
        var togglePiP: () -> Void = {}
        var setObjectFit: (String) -> Void = { _ in }
        var selectSource: (Int) -> Void = { _ in }
        var loadEpisodes: () -> Void = {}
        var showAirPlay: () -> Void = {}
        var goToEpisode: (URL) -> Void = { _ in }
        var cancelResume: () -> Void = {}
        var setOverlayBlocking: (Bool) -> Void = { _ in }
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
                             WKScriptMessageHandler {
        let model: BrowserModel
        let page: PageState
        let rules: RuleListController
        let settings: ProtectionSettings
        var loaded: URL?

        /// A renderer crash is reloaded once. A second crash on the same URL is
        /// a page the device cannot render, and retrying forever would just
        /// loop — so the second one is reported instead.
        private var recoveredFrom: URL?

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
        /// Drops the curtain if resume never reports either way — a page that
        /// never loads, or one whose frames never announce. Without it a failed
        /// episode change leaves the user on a black screen with no controls
        /// and no page.
        private var resumeWatchdog: Task<Void, Never>?
        private static let resumeTimeout: Duration = .seconds(12)
        private var observations: [NSKeyValueObservation] = []

        /// Frames that reported blocking something. Toggling has to reach each
        /// of them: `evaluateJavaScript(in: nil)` only ever hits the main frame,
        /// and interstitials are frequently inside an ad iframe.
        private var blockingFrames: [WKFrameInfo] = []

        init(model: BrowserModel, page: PageState,
             rules: RuleListController, settings: ProtectionSettings) {
            self.model = model
            self.page = page
            self.rules = rules
            self.settings = settings
        }

        func observe(_ webView: WKWebView) {
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
            ]
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

        /// Episode links live in the top-level page, so navigation is done
        /// natively rather than by scripting a frame. Re-validated here: the
        /// URL came from page content and is only trusted as far as its host.
        func goToEpisode(_ destination: URL) {
            guard let webView = page.webView,
                  let currentHost = webView.url?.host(),
                  destination.host() == currentHost,
                  destination.scheme?.lowercased() == webView.url?.scheme?.lowercased()
            else { return }

            let wasWatching = page.isTheater
            resumeTheaterFor = wasWatching ? destination : nil
            page.isTheater = false
            if wasWatching { beginResume() }
            loaded = destination
            model.open(destination)
            webView.load(URLRequest(url: destination))
        }

        /// The curtain, and the deadline that guarantees it lifts.
        private func beginResume() {
            page.isResumingEpisode = true
            resumeWatchdog?.cancel()
            resumeWatchdog = Task { [weak self] in
                try? await Task.sleep(for: Self.resumeTimeout)
                guard !Task.isCancelled else { return }
                self?.endResume()
            }
        }

        /// Lifts the curtain, whatever the outcome. Safe to call more than once:
        /// theater arriving, the agent reporting failure, the watchdog firing
        /// and the user cancelling all land here.
        func endResume() {
            resumeWatchdog?.cancel()
            resumeWatchdog = nil
            resumeTheaterFor = nil
            page.isResumingEpisode = false
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
                page.blockedExternal = url
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
                    page.blockedExternal = url
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

        // MARK: Authentication and TLS

        /// Server trust is left to the system: the default handling rejects an
        /// invalid or untrusted certificate, and there is deliberately no path
        /// here that overrides it.
        ///
        /// Password challenges are declined rather than prompted for. This app
        /// has no credential UI and no keychain story, and inventing a password
        /// field inside a browser that exists to strip hostile pages would be
        /// the wrong place to start.
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
                // The message belongs in report(): cancelling fails the
                // navigation, and setting page.loadError here would be
                // overwritten by the failure that follows.
                completionHandler(.cancelAuthenticationChallenge, nil)
            case NSURLAuthenticationMethodClientCertificate:
                completionHandler(.cancelAuthenticationChallenge, nil)
            default:
                completionHandler(.performDefaultHandling, nil)
            }
        }

        // MARK: Renderer recovery

        /// Without this the web content process dying leaves a white screen and
        /// no explanation — the view stays up, but nothing is in it.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            theaterFrame = nil
            blockingFrames.removeAll()
            page.isTheater = false
            endResume()

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
            page.textTracks = []
            page.pipAvailable = false
            page.videoHeight = 0
            page.sources = []
            page.objectFit = "contain"
            page.episodes = []
            page.airplayAvailable = false
            page.nextEpisode = nil
            page.previousEpisode = nil
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                     withError error: Error) {
            report(error)
        }

        private func report(_ error: Error) {
            let ns = error as NSError
            // -999 is "a newer navigation replaced this one" — not a failure.
            guard ns.code != NSURLErrorCancelled else { return }
            // An episode that will not load has nothing to resume into.
            endResume()

            page.loadError = switch ns.code {
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
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let url = webView.url
            page.host = url?.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
            page.title = webView.title ?? ""
            page.isSecure = url?.scheme?.lowercased() == "https"
            if let url { model.record(url, title: webView.title) }

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
            // Page-supplied: only the message shape is trusted. No URL from here
            // is used without being re-validated against the current host.
            guard let body = message.body as? [String: Any],
                  let kind = body["type"] as? String else { return }

            switch kind {
            // Every frame announces itself once. Resuming theater after an
            // episode change has to happen in the frame holding the video, and
            // on these sites that is a cross-origin iframe — the main frame has
            // no <video> at all, so asking it was asking the wrong document.
            // `resumeTheater` is cleared by the theater message rather than
            // here, so a frame without a video simply finds nothing and the one
            // that has it still gets asked.
            case "ready":
                // Scoped to the destination, which is what the property was
                // always documented to be: checking only for non-nil meant a
                // resume armed for one episode could fire on whatever page
                // happened to load next.
                guard let armed = resumeTheaterFor,
                      let current = page.webView?.url,
                      armed.absoluteString == current.absoluteString
                else { break }
                page.webView?.evaluateJavaScript(
                    "window.__cp && window.__cp.autoTheater()",
                    in: message.frameInfo, in: BrowserSetup.world,
                    completionHandler: nil)

            case "theater":
                // Remember WHICH frame staged the video. Everything the native
                // chrome does afterwards is addressed to this frame.
                theaterFrame = message.frameInfo
                endResume()
                page.isTheater = true
                page.playbackEnded = false
                page.airplayAvailable = body["airplay"] as? Bool ?? false
                page.pipAvailable = body["pip"] as? Bool ?? false
                if let webView = page.webView { refreshEpisodes(webView) }

                // A player in a cross-origin frame stages the video against
                // that frame's document and can reach no further. The host
                // page's own header, server list and comments would stay on
                // screen under the native controls — which is what "Watch
                // clean did nothing but add a close button" looks like. Tell
                // the main frame to stage the player frame itself.
                if !message.frameInfo.isMainFrame {
                    page.webView?.evaluateJavaScript(
                        "window.__cp && window.__cp.hostTheater()",
                        in: nil, in: BrowserSetup.world, completionHandler: nil)
                }
            case "theaterEnded":
                theaterFrame = nil
                releaseHostPage()
                page.isTheater = false
            // The agent gave up finding a video to resume into. Only the frame
            // that was actually asked reports this, so the curtain comes down
            // on a real answer rather than on the watchdog's deadline.
            case "theaterFailed":
                endResume()
            case "ended":
                page.playbackEnded = true
                page.isPlaying = false
            case "blocked":
                page.blockedCount = body["count"] as? Int ?? 0
                if page.blockedCount > 0,
                   !blockingFrames.contains(where: { $0 == message.frameInfo }) {
                    blockingFrames.append(message.frameInfo)
                }
            case "playback":
                let playing = body["playing"] as? Bool ?? false
                page.isPlaying = playing
                // Replaying, or seeking back out of the end, retracts the offer.
                if playing { page.playbackEnded = false }
            case "time":
                page.currentTime = body["at"] as? Double ?? 0
                page.duration = body["duration"] as? Double ?? 0
                page.isLive = body["live"] as? Bool ?? false
                page.bufferedTo = body["buffered"] as? Double ?? 0
                page.playbackRate = body["rate"] as? Double ?? 1
            case "video":
                let info = body["info"] as? [String: Any] ?? [:]
                page.videoHeight = info["height"] as? Int ?? 0
                page.objectFit = info["fit"] as? String ?? "contain"
                page.sources = (info["sources"] as? [[String: Any]] ?? [])
                    .compactMap { entry in
                        guard let index = entry["index"] as? Int,
                              let label = entry["label"] as? String else { return nil }
                        return PageState.VideoSource(
                            id: index, label: label,
                            active: entry["active"] as? Bool ?? false)
                    }
            case "tracks":
                let raw = body["tracks"] as? [[String: Any]] ?? []
                page.textTracks = raw.compactMap { entry in
                    guard let index = entry["index"] as? Int,
                          let label = entry["label"] as? String else { return nil }
                    return PageState.TextTrack(
                        id: index, label: label,
                        active: entry["active"] as? Bool ?? false)
                }
            case "airplay":
                page.airplayAvailable = body["available"] as? Bool ?? false
            default:
                break
            }
        }
    }
}
