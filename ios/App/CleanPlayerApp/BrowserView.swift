import CleanPlayer
import SwiftUI

struct BrowserView: View {
    let url: URL
    @ObservedObject var model: BrowserModel
    @ObservedObject var rules: RuleListController
    @ObservedObject var settings: ProtectionSettings
    @ObservedObject var gestureSettings: PlayerGestureSettings
    @ObservedObject var playback: PlaybackPreferences
    @StateObject private var page = PageState()
    @State private var showingSettings = false
    @State private var loadedDuringRulePreparation = false

    var body: some View {
        VStack(spacing: 0) {
            if !immersive {
                addressBar
                if rules.status.isPreparing { preparingBanner }
                Divider()
            }

            ZStack(alignment: .bottom) {
                // Nothing loads until a rule list is attached. This window is a
                // few milliseconds, but starting a navigation inside it means
                // that page is fetched with no filtering at all.
                if rules.isArmed {
                    WebView(url: url, model: model, page: page,
                            rules: rules, settings: settings)
                        // A data store cannot be swapped on a live web view, so
                        // the toggle only means anything if the view is rebuilt.
                        .id(settings.privateBrowsing)
                } else {
                    startingProtection
                }

                // Native chrome, not injected DOM: nothing the page draws
                // appears above a staged video on iOS WebKit.
                if page.isTheater {
                    PlayerOverlay(page: page, rules: rules,
                                  gestureSettings: gestureSettings)
                }

                // Over everything, including the error panel: while this is up
                // the page underneath is mid-load and whatever it is showing is
                // not something the user asked to see.
                if page.isResumingEpisode { resumingCurtain }

                if let message = page.loadError { errorPanel(message) }
                else if let external = page.blockedExternal { popupBar(external) }
            }

            if !immersive {
                Divider()
                toolbar
            }
        }
        .background(Color(.systemBackground))
        .animation(.easeInOut(duration: 0.2), value: immersive)
        .onAppear {
            loadedDuringRulePreparation = rules.status.isPreparing
        }
        .onChange(of: rules.completedActivationCount) { _, _ in
            guard loadedDuringRulePreparation, !rules.isSuspended else { return }
            loadedDuringRulePreparation = false
            page.reload()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(model: model, rules: rules, settings: settings,
                         gestureSettings: gestureSettings, playback: playback,
                         currentHost: page.host.isEmpty ? url.host() : page.host,
                         // Rules apply at navigation time, so a level change
                         // leaves the page in front of the user exactly as it
                         // was. Without this the setting looks broken.
                         onProtectionChanged: { page.reload() })
        }
    }

    /// Theater, and the gap between two episodes of it. Browser chrome stays
    /// down for both — bringing the address bar and toolbar back for the two
    /// seconds of a page load is what made an episode change feel like leaving
    /// the player.
    private var immersive: Bool { page.isTheater || page.isResumingEpisode }

    /// The last frame of the outgoing video, dimmed, with the spinner over it —
    /// or black when there is no frame yet. Either way the next episode's
    /// header, ads and cookie banner are never seen at all.
    private var resumingCurtain: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let frame = page.transitionFrame {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .overlay(Color.black.opacity(0.45).ignoresSafeArea())
                    .accessibilityHidden(true)
            }
            VStack(spacing: 16) {
                ProgressView().controlSize(.large).tint(.white)
                Text(page.episodeTransitionMessage)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                // An escape hatch, because a site that never resumes would
                // otherwise hold the screen until the watchdog's deadline.
                Button("Show the page") { page.actions.cancelResume() }
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.top, 4)
            }
        }
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(page.episodeTransitionMessage)
    }

    private var host: String { page.host.isEmpty ? (url.host() ?? "") : page.host }

    private var startingProtection: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Starting protection\u{2026}")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .accessibilityElement(children: .combine)
    }

    /// A cross-site window the page tried to open on its own. Offered rather
    /// than followed: on a video page this is nearly always an ad, but it is
    /// occasionally a real outbound link, and the user can tell them apart.
    private func popupBar(_ request: URLRequest) -> some View {
        let destination = request.url
        return HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Blocked a popup").font(.footnote.weight(.medium))
                Text(destination?.host() ?? destination?.absoluteString ?? "Unknown destination")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Open") {
                page.actions.openBlockedRequest(request)
            }
            .font(.footnote.weight(.semibold))
            Button {
                page.blockedExternal = nil
            } label: {
                Image(systemName: "xmark").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 16)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    /// Shown only while the big lists compile, which is the first launch after
    /// install or after a rule update. Saying so is better than a user
    /// wondering why an ad got through once.
    private var preparingBanner: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text("Preparing full protection\u{2026} basic blocking is already on.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }

    // MARK: Chrome

    private var addressBar: some View {
        HStack(spacing: 10) {
            // The origin must stay visible: it is the user's only defence
            // against a page pretending to be somewhere else.
            Image(systemName: page.isSecure ? "lock.fill" : "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(page.isSecure ? Color.secondary : Color.orange)
                .accessibilityLabel(page.isSecure ? "Secure connection" : "Not secure")

            Text(host)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .accessibilityLabel("Site, \(host)")

            if settings.isExempt(host) {
                Text("protection off")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.25), in: .capsule)
                    .foregroundStyle(Color(.label))
                    .accessibilityLabel("Protection is off for this site")
            }

            Spacer()

            if page.isLoading { ProgressView().controlSize(.small) }
            siteMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Per-site controls belong next to the site they act on, not buried in a
    /// settings screen the user has to go and find while a page is misbehaving.
    private var siteMenu: some View {
        Menu {
            if !host.isEmpty {
                Button {
                    let exempt = !settings.isExempt(host)
                    settings.setExempt(exempt, for: host)
                    rules.setSuspended(settings.isExempt(host))
                    page.reload()
                } label: {
                    Label(settings.isExempt(host)
                          ? "Turn protection on for \(host)"
                          : "Turn protection off for \(host)",
                          systemImage: settings.isExempt(host)
                          ? "shield.lefthalf.filled" : "shield.slash")
                }
            }
            // The only way onto the home screen for a site that never stages a
            // video the app can see — a home media server, most often.
            let site = page.webView?.url ?? url
            if AddressResolver.siteRoot(of: site) != nil {
                if model.isPinned(site) {
                    Button { model.unpinSite(site) } label: {
                        Label("Remove from Home", systemImage: "pin.slash")
                    }
                } else {
                    Button { model.pinSite(site, title: page.title) } label: {
                        Label("Add to Home", systemImage: "pin")
                    }
                }
            }
            Button { showingSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Site options")
    }

    private var toolbar: some View {
        HStack {
            Button { page.goBack() } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }
            .disabled(!page.canGoBack)
            .accessibilityLabel("Back")
            Spacer()
            Button { page.goForward() } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 44)
            }
            .disabled(!page.canGoForward)
            .accessibilityLabel("Forward")
            Spacer()
            Button { page.reload() } label: {
                Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Reload")
            Spacer()
            // Blocking by shape will sometimes catch a real dialog. This is the
            // way back, and it shows how many overlays were hidden.
            Button {
                page.actions.setOverlayBlocking(!page.overlayBlocking)
            } label: {
                Image(systemName: page.overlayBlocking
                      ? "shield.lefthalf.filled" : "shield.slash")
                    .frame(width: 44, height: 44)
                    .overlay(alignment: .topTrailing) {
                        if page.overlayBlocking && page.blockedTotal > 0 {
                            Text("\(page.blockedTotal)")
                                .accessibilityHidden(true)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(Color.accentColor, in: .circle)
                                .offset(x: 10, y: -6)
                        }
                    }
            }
            // Deliberately not called "ads blocked". WKContentRuleList reports
            // nothing when it blocks a request, so network blocks are
            // uncountable; this badge is only what the page agent hid.
            .accessibilityLabel(page.overlayBlocking
                                ? "Overlay blocking on, "
                                  + "\(page.blockedTotal) "
                                  + "overlays and popups hidden"
                                : "Overlay blocking off")
            Spacer()
            Button { model.goHome() } label: {
                Image(systemName: "house.fill").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Home")
        }
        .font(.title3)
        .padding(.horizontal, 32)
        .padding(.vertical, 12)
    }

    private func errorPanel(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Can't open this page")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Try again") { page.actions.retryFailedNavigation() }
                    .buttonStyle(.borderedProminent)
                Button("Home") { model.goHome() }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .accessibilityElement(children: .contain)
    }
}
