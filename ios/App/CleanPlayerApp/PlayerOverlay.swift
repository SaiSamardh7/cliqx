import CleanPlayer
import SwiftUI
import UIKit

/// The player chrome shown over a staged video.
///
/// Everything here is native. The page's own controls are hidden along with the
/// rest of the page, so if a control is not in this file the user does not have
/// it — which is why play/pause, seeking and subtitles all live here rather
/// than being left to the site.
struct PlayerOverlay: View {
    @ObservedObject var page: PageState
    @ObservedObject var rules: RuleListController
    @ObservedObject var gestureSettings: PlayerGestureSettings

    /// Visibility, lock, scrub target and the up-next countdown. Was a handful
    /// of `@State` variables and three loose `Task` handles, which no test
    /// could reach — the overlay only exists in theater, and theater needs a
    /// real video. `PlayerChromeModel` holds the same rules where they can be
    /// asserted.
    @StateObject private var chrome = PlayerChromeModel()

    /// Stays here: nothing but this view cares whether a sheet is up.
    @State private var showingEpisodes = false
    @State private var showingAirPlayHelp = false
    @State private var dragAction: PlayerDragAction?
    @State private var dragStartBrightness: CGFloat = 0
    @State private var dragStartVolume = 100
    @State private var gestureBrightnessPercent: Int?
    @State private var gestureVolumePercent: Int?
    @State private var heldPreviousRate: Double?

    var body: some View {
        ZStack {
            tapLayer

            if chrome.isLocked {
                lockedAffordance
            } else if chrome.areControlsVisible {
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    centreTransport
                    Spacer(minLength: 0)
                    bottomBar
                }
                .transition(.opacity)
            }

            if let flash = chrome.seekFlash { seekFlashLabel(flash) }

            if gestureBrightnessPercent != nil || gestureVolumePercent != nil {
                levelHUDs
            }

            if let remaining = chrome.countdown, let next = page.nextEpisode {
                upNextCard(remaining: remaining, next: next)
            }
        }
        // Must fill. The parent is a ZStack aligned to .bottom and Color.clear
        // has no intrinsic size, so without this the overlay collapses to a
        // sliver at the bottom and every tap lands on the page behind it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.18), value: chrome.areControlsVisible)
        .animation(.easeInOut(duration: 0.18), value: chrome.isLocked)
        .onAppear {
            // The three things the chrome initiates on its own. Everything
            // else is a button, and goes straight to `page.actions`.
            chrome.onAdvance = {
                if let next = page.nextEpisode { page.actions.goToEpisode(next) }
            }
            chrome.onSeek = { page.actions.seek($0) }
            chrome.onBeginScrub = { page.actions.beginScrub() }
            chrome.playbackChanged(isPlaying: page.isPlaying)
        }
        .onChange(of: page.isPlaying) { _, playing in
            chrome.playbackChanged(isPlaying: playing)
        }
        .onChange(of: page.playbackEnded) { _, ended in
            guard ended else { return }
            chrome.playbackEnded(hasNext: page.nextEpisode != nil)
        }
        // A new episode is a new video: whatever the user declined last time
        // has nothing to do with this one.
        .onChange(of: page.nextEpisode) { _, _ in chrome.itemChanged() }
        .onDisappear { chrome.cancelEverything() }
        .sheet(isPresented: $showingEpisodes) { episodeSheet }
        // Says what AirPlay will and will not do here, and names the thing
        // that does work. "AirPlay is broken" and "AirPlay cannot carry this
        // stream, mirroring can" are very different messages to receive.
        .alert("Video can't be sent to a TV from this site",
               isPresented: $showingAirPlayHelp) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("This site streams video in a form AirPlay cannot forward, so "
                 + "only the sound would reach the TV.\n\nUse Screen Mirroring "
                 + "from Control Centre instead — it sends the picture as well.")
        }
    }

    // MARK: Tap and double-tap

    /// Single tap toggles the chrome; double-taps seek on the sides and toggle
    /// playback in the centre.
    ///
    /// The double-tap gesture is declared first so SwiftUI gives it priority —
    /// otherwise the single tap fires immediately and the second tap only
    /// toggles the controls back.
    private var tapLayer: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                tapZone(action: { seekByDoubleTap(-10) })
                tapZone(action: {
                    guard gestureSettings.doubleTapPlayPause else { return }
                    page.actions.togglePlay()
                    chrome.interacted()
                })
                tapZone(action: { seekByDoubleTap(10) })
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .simultaneousGesture(playerDragGesture)
        .onLongPressGesture(minimumDuration: 0.45, pressing: { pressing in
            guard gestureSettings.temporaryFastForward else { return }
            if !pressing, let previous = heldPreviousRate {
                page.actions.setRate(previous)
                heldPreviousRate = nil
            }
        }, perform: {
            guard !chrome.isLocked, gestureSettings.temporaryFastForward,
                  heldPreviousRate == nil else { return }
            heldPreviousRate = page.playbackRate
            page.actions.setRate(2)
            chrome.interacted()
        })
    }

    private func tapZone(action: @escaping () -> Void) -> some View {
        Color.clear
            .contentShape(.rect)
            .onTapGesture(count: 2) {
                guard !chrome.isLocked else { return }
                action()
            }
            .onTapGesture { chrome.tapped() }
            .accessibilityHidden(true)   // the buttons carry these actions
    }

    private func seekByDoubleTap(_ seconds: Double) {
        page.actions.skip(seconds)
        chrome.flashSeek(seconds)
    }

    // MARK: Full-screen gestures

    private var playerDragGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                guard !chrome.isLocked else { return }
                let size = UIScreen.main.bounds.size
                let width = max(Double(size.width), 1)
                if dragAction == nil {
                    dragAction = PlayerGestureClassifier.classify(
                        dx: Double(value.translation.width),
                        dy: Double(value.translation.height),
                        startXFraction: Double(value.startLocation.x) / width)
                    dragStartBrightness = UIScreen.main.brightness
                    dragStartVolume = page.volumePercent
                }

                guard let dragAction else { return }
                switch dragAction {
                case .seek:
                    guard gestureSettings.swipeSeeking else { return }
                    let delta = PlayerGestureClassifier.seekDelta(
                        dx: Double(value.translation.width), width: width)
                    chrome.flashSeek(delta.rounded())
                case .brightness:
                    guard gestureSettings.brightnessAndVolume else { return }
                    let change = -value.translation.height / max(size.height, 1)
                    let brightness = min(max(dragStartBrightness + change, 0), 1)
                    UIScreen.main.brightness = brightness
                    gestureBrightnessPercent = Int((brightness * 100).rounded())
                    gestureVolumePercent = page.mediaVolumeAvailable
                        ? page.volumePercent : nil
                case .volume:
                    guard gestureSettings.brightnessAndVolume,
                          page.mediaVolumeAvailable else { return }
                    let change = Int((-value.translation.height
                                      / max(size.height, 1) * 200).rounded())
                    let volume = min(max(dragStartVolume + change, 0), 200)
                    page.actions.setVolume(volume)
                    gestureBrightnessPercent = Int((UIScreen.main.brightness * 100).rounded())
                    gestureVolumePercent = volume
                    chrome.interacted()
                case .dismiss:
                    // Commit only in onEnded after the distance/direction test.
                    break
                }
            }
            .onEnded { value in
                defer {
                    dragAction = nil
                    gestureBrightnessPercent = nil
                    gestureVolumePercent = nil
                }
                guard !chrome.isLocked else { return }
                let dx = Double(value.translation.width)
                let dy = Double(value.translation.height)
                if dragAction == .dismiss, gestureSettings.swipeToDismiss,
                   PlayerGestureClassifier.shouldDismiss(dx: dx, dy: dy) {
                    page.actions.exitTheater()
                    return
                }
                guard dragAction == .seek, gestureSettings.swipeSeeking else { return }
                let width = max(Double(UIScreen.main.bounds.width), 1)
                let delta = PlayerGestureClassifier.seekDelta(dx: dx, width: width).rounded()
                page.actions.skip(delta)
                chrome.flashSeek(delta)
                chrome.interacted()
            }
    }

    /// Mirrors the physical layout of the gesture: brightness on the left,
    /// volume on the right. Both values stay visible while either side is
    /// being adjusted so the gesture never feels ambiguous.
    private var levelHUDs: some View {
        HStack {
            if let brightness = gestureBrightnessPercent {
                PlayerLevelHUD(kind: .brightness, percent: brightness,
                               isActive: dragAction == .brightness)
            }
            Spacer(minLength: 44)
            if let volume = gestureVolumePercent {
                PlayerLevelHUD(kind: .volume, percent: volume,
                               isActive: dragAction == .volume)
            }
        }
        .padding(.horizontal, 28)
        .allowsHitTesting(false)
        .transition(.opacity)
        .accessibilityElement(children: .contain)
    }

    private func seekFlashLabel(_ seconds: Double) -> some View {
        HStack {
            if seconds > 0 { Spacer() }
            Label("\(Int(abs(seconds)))s",
                  systemImage: seconds < 0 ? "gobackward.10" : "goforward.10")
                .font(.headline)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: .capsule)
                .padding(.horizontal, 44)
            if seconds < 0 { Spacer() }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    // MARK: Up next

    private func upNextCard(remaining: Int, next: URL) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Up next")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(nextLabel)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)

                    HStack(spacing: 10) {
                        Button {
                            chrome.acceptNext()
                        } label: {
                            Label("Play now", systemImage: "play.fill")
                                .font(.footnote.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 34)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Cancel") { chrome.declineNext() }
                            .font(.footnote.weight(.medium))
                            .frame(minWidth: 66, minHeight: 34)
                            .buttonStyle(.bordered)
                    }
                }
                .padding(14)
                .frame(maxWidth: 280)
                .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
                // The ring is the countdown: a number alone reads as a label
                // rather than as something running out.
                .overlay(alignment: .topTrailing) {
                    countdownRing(remaining)
                        .padding(10)
                }
                .padding(.trailing, 18)
                .padding(.bottom, 96)      // clear of the timeline and bar
            }
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
        .animation(.easeOut(duration: 0.22), value: chrome.countdown != nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Up next: \(nextLabel), playing in \(remaining) seconds")
    }

    private func countdownRing(_ remaining: Int) -> some View {
        ZStack {
            Circle().stroke(.white.opacity(0.25), lineWidth: 2)
            Circle()
                .trim(from: 0, to: Double(remaining) / Double(chrome.countdownFrom))
                .stroke(Color.accentColor, style: .init(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(remaining)")
                .font(.caption2.weight(.bold).monospacedDigit())
        }
        .frame(width: 26, height: 26)
        .animation(.linear(duration: 0.9), value: remaining)
        .accessibilityHidden(true)      // the card carries the spoken version
    }

    /// The site's own label for the next episode where the picker found one,
    /// and a plain fallback where it did not — the neighbours are discovered
    /// separately from the list, so next can exist with no matching row.
    private var nextLabel: String {
        guard let next = page.nextEpisode else { return "Next episode" }
        let match = page.episodes.first { $0.url == next }
        return match.map { PlayerFormatting.episodeRowLabel($0.label) } ?? "Next episode"
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(alignment: .center, spacing: 8) {
            circleButton("xmark", label: "Close player") {
                page.actions.exitTheater()
            }

            Spacer(minLength: 8)

            VStack(spacing: 1) {
                if !page.title.isEmpty {
                    Text(PlayerFormatting.showTitle(page.title, host: page.host))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                if let episode = PlayerFormatting.episodeLabel(page.title) {
                    Text(episode).font(.caption2).foregroundStyle(.secondary)
                }
                cleanBadge
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            // Shown when the device HAS a picker, not only when a route is
            // already advertised: WebKit's availability event is the part we
            // cannot rely on, and the picker itself reports "no devices found"
            // perfectly well on its own.
            if page.airplayAvailable || page.airplayPickerSupported {
                // Two different controls behind one position, because the
                // honest answer depends on what the site is streaming. Where
                // the picture cannot travel, opening the picker would put the
                // sound on the television and leave the video here — so that
                // case explains itself instead of walking the user into it.
                if page.airplayCanSendVideo {
                    circleButton("airplayvideo", label: "AirPlay") {
                        page.actions.showAirPlay()
                    }
                } else {
                    circleButton("airplayvideo.badge.exclamationmark",
                                 label: "AirPlay, video not supported on this site") {
                        showingAirPlayHelp = true
                    }
                }
            }
            if page.pipAvailable {
                circleButton("pip.enter", label: "Picture in Picture") {
                    page.actions.togglePiP()
                }
            }
            circleButton("rectangle.portrait.rotate", label: rotationLabel) {
                rotatePlayer()
            }
            moreMenu
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    /// States what protection is actually doing on this page, rather than
    /// asserting "Clean" unconditionally — the user turns it off per site, and
    /// the badge has to tell the truth when they have.
    @ViewBuilder
    private var cleanBadge: some View {
        let off = rules.isSuspended || rules.status == .off
        HStack(spacing: 3) {
            Image(systemName: off ? "shield.slash" : "checkmark.shield.fill")
                .font(.system(size: 9))
            Text(off ? "Protection off" : "Clean")
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(off ? Color.orange : Color.accentColor)
        .accessibilityLabel(off ? "Protection is off for this site"
                                : "Protection active")
    }

    // MARK: Centre transport

    private var centreTransport: some View {
        HStack(spacing: 34) {
            circleButton("gobackward.10", label: "Back 10 seconds", size: 30) {
                page.actions.skip(-10)
                chrome.interacted()
            }
            Button {
                page.actions.togglePlay()
                chrome.interacted()
            } label: {
                Image(systemName: page.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 66, height: 66)
                    .background(.white, in: .circle)
            }
            .accessibilityLabel(page.isPlaying ? "Pause" : "Play")
            circleButton("goforward.10", label: "Forward 10 seconds", size: 30) {
                page.actions.skip(10)
                chrome.interacted()
            }
        }
    }

    // MARK: Bottom

    private var bottomBar: some View {
        VStack(spacing: 6) {
            timeline
            // Eight 44pt controls plus the word "Episodes" is about 400pt, and
            // a phone in portrait offers 374. The row does not truncate — it
            // makes the whole VStack wider than the screen, which then clips
            // the timeline's timecodes at both ends too. That is what turned
            // "0:12" into "12" and "23:40" into "23:".
            ViewThatFits(in: .horizontal) {
                controlRow(showsEpisodeLabel: true)
                controlRow(showsEpisodeLabel: false)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private var timeline: some View {
        HStack(spacing: 10) {
            Text(PlayerFormatting.timecode(chrome.scrubTarget ?? page.currentTime))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                // A GeometryReader takes every point it is offered, so without
                // priority the timecodes get no width at all and spill off the
                // edges: "0:29" rendered as "29", "23:40" as "23:".
                .fixedSize()
                .layoutPriority(1)

            GeometryReader { geo in
                let width = geo.size.width
                let played = fraction(chrome.scrubTarget ?? page.currentTime) * width
                let buffered = fraction(page.bufferedTo) * width

                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white.opacity(0.35)).frame(width: max(0, buffered))
                    Capsule().fill(Color.accentColor).frame(width: max(0, played))
                    Circle()
                        .fill(.white)
                        .frame(width: chrome.isScrubbing ? 17 : 12)
                        .offset(x: max(0, played - (chrome.isScrubbing ? 8.5 : 6)))
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(scrubGesture(width: width))
                .animation(.easeOut(duration: 0.12), value: chrome.isScrubbing)
            }
            .frame(height: 34)
            .disabled(page.duration <= 0)
            .opacity(page.duration > 0 ? 1 : 0.4)

            Text(page.isLive ? "LIVE" : PlayerFormatting.timecode(page.duration))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(page.isLive ? .red : .white.opacity(0.85))
                .fixedSize()
                .layoutPriority(1)
        }
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(PlayerFormatting.spoken(page.currentTime))
        .accessibilityAdjustableAction { direction in
            page.actions.skip(direction == .increment ? 10 : -10)
        }
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard page.duration > 0 else { return }
                chrome.scrubBegan()
                let ratio = min(max(value.location.x / width, 0), 1)
                chrome.scrubMoved(to: ratio * page.duration)
            }
            .onEnded { _ in chrome.scrubEnded() }
    }

    private func fraction(_ seconds: Double) -> Double {
        guard page.duration > 0 else { return 0 }
        return min(max(seconds / page.duration, 0), 1)
    }

    private func controlRow(showsEpisodeLabel: Bool) -> some View {
        HStack(spacing: 4) {
            episodeControls(showsLabel: showsEpisodeLabel)
            Spacer(minLength: 8)
            secondaryControls
        }
    }

    private func episodeControls(showsLabel: Bool) -> some View {
        HStack(spacing: 2) {
            barButton("backward.end.fill", label: "Previous episode",
                      enabled: page.previousEpisode != nil) {
                if let previous = page.previousEpisode {
                    page.actions.goToEpisode(previous)
                }
            }
            Button {
                page.actions.loadEpisodes()
                showingEpisodes = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "list.bullet")
                    if showsLabel { Text("Episodes") }
                }
                .font(.caption.weight(.medium))
                .fixedSize()
                .frame(minWidth: 44, minHeight: 44)
                .padding(.horizontal, showsLabel ? 8 : 0)
            }
            .accessibilityLabel("Episode list")
            barButton("forward.end.fill", label: "Next episode",
                      enabled: page.nextEpisode != nil) {
                if let next = page.nextEpisode {
                    page.actions.goToEpisode(next)
                }
            }
        }
    }

    private var secondaryControls: some View {
        HStack(spacing: 2) {
            subtitlesMenu
            speedMenu
            qualityMenu
            barButton(page.objectFit == "cover"
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right",
                      label: page.objectFit == "cover" ? "Fit video" : "Fill screen") {
                page.actions.setObjectFit(page.objectFit == "cover" ? "contain" : "cover")
            }
            barButton("lock.open", label: "Lock controls") {
                withAnimation { chrome.lock() }
            }
        }
    }

    // MARK: Menus

    private var subtitlesMenu: some View {
        Menu {
            if page.textTracks.isEmpty {
                Text("This site provides no subtitle tracks")
            } else {
                Picker("Subtitles", selection: Binding(
                    get: { page.textTracks.first(where: \.active)?.id ?? -1 },
                    set: { page.actions.selectTrack($0) }
                )) {
                    Text("Off").tag(-1)
                    ForEach(page.textTracks) { Text($0.label).tag($0.id) }
                }
            }
        } label: {
            barLabel("CC", active: page.textTracks.contains(where: \.active))
        }
        .accessibilityLabel("Subtitles")
    }

    private var speedMenu: some View {
        Menu {
            Picker("Speed", selection: Binding(
                get: { page.playbackRate },
                set: { page.actions.setRate($0) }
            )) {
                ForEach(PlayerFormatting.speeds, id: \.self) { rate in
                    Text(rate == 1 ? "Normal" : "\(PlayerFormatting.rateText(rate))\u{00D7}").tag(rate)
                }
            }
        } label: {
            barLabel("\(PlayerFormatting.rateText(page.playbackRate))\u{00D7}",
                     active: page.playbackRate != 1)
        }
        .accessibilityLabel("Playback speed")
    }

    /// Two different controls behind one label, because the page decides which
    /// is honest.
    ///
    /// Where the page exposes plain `<source>` elements they are selectable —
    /// switching one is just a src swap, and the agent restores position and
    /// play state. Where it does not — every MSE player, which is most of them
    /// — the variants live inside the site's own manifest and its selector is
    /// in the UI theater hid, so this reports the decoded frame height rather
    /// than rendering rows that look tappable and are not.
    private var qualityMenu: some View {
        Menu {
            if page.sources.isEmpty {
                Section("Quality") {
                    Text(page.videoHeight > 0
                         ? "Playing at \(page.qualityLabel)" : "Not known yet")
                    Text("Set by the site, before Watch clean")
                }
            } else {
                Picker("Quality", selection: Binding(
                    get: { page.sources.first(where: \.active)?.id ?? -1 },
                    set: { page.actions.selectSource($0) }
                )) {
                    ForEach(page.sources) { Text($0.label).tag($0.id) }
                }
            }
        } label: {
            barLabel(page.qualityLabel, active: false)
        }
        .accessibilityLabel("Video quality, \(page.qualityLabel)")
    }

    private var moreMenu: some View {
        Menu {
            Menu {
                Picker("Volume", selection: Binding(
                    get: { page.volumePercent },
                    set: { page.actions.setVolume($0) }
                )) {
                    ForEach([0, 25, 50, 75, 100, 125, 150, 175, 200], id: \.self) { level in
                        Text(level > 100 ? "\(level)% Boost" : "\(level)%").tag(level)
                    }
                }
                Divider()
                Text("Above 100% may distort loud audio")
            } label: {
                Label("Volume \(page.volumePercent)%",
                      systemImage: page.volumePercent > 100
                        ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
            }
            .disabled(!page.mediaVolumeAvailable)
            .accessibilityHint(page.mediaVolumeAvailable
                ? "Controls this video's audio level"
                : "Unavailable for this stream; use the hardware volume buttons")
            Divider()
            Button {
                page.actions.setObjectFit(page.objectFit == "cover" ? "contain" : "cover")
            } label: {
                Label(page.objectFit == "cover" ? "Fit to screen" : "Fill screen",
                      systemImage: "aspectratio")
            }
            Button { withAnimation { chrome.lock() } } label: {
                Label("Lock controls", systemImage: "lock")
            }
            Divider()
            Button { page.actions.exitTheater() } label: {
                Label("Leave player", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            circleLabel("ellipsis")
        }
        .accessibilityLabel("More player options")
    }

    // MARK: Lock

    /// A locked player shows one control. Everything else ignores touch, which
    /// is the entire point — a pocket or a resting hand cannot seek.
    private var lockedAffordance: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    withAnimation { chrome.unlock() }
                } label: {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 48, height: 48)
                        .background(.ultraThinMaterial, in: .circle)
                }
                .accessibilityLabel("Unlock controls")
                .opacity(chrome.areControlsVisible ? 1 : 0)
                .padding(.trailing, 18)
            }
            Spacer()
        }
    }

    // MARK: Episodes

    private var episodeSheet: some View {
        NavigationStack {
            Group {
                if page.episodes.isEmpty {
                    ContentUnavailableView(
                        "No episode list",
                        systemImage: "list.bullet",
                        description: Text("This page does not link its episodes "
                                          + "in a way the player can read."))
                } else {
                    List(page.episodes) { episode in
                        Button {
                            if let url = episode.url {
                                page.actions.goToEpisode(url)
                                showingEpisodes = false
                            }
                        } label: {
                            HStack {
                                Text(PlayerFormatting.episodeRowLabel(episode.label))
                                    .foregroundStyle(episode.current ? Color.accentColor
                                                                     : Color.primary)
                                Spacer()
                                if episode.current {
                                    Image(systemName: "play.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Episodes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingEpisodes = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Building blocks

    private func circleButton(_ symbol: String, label: String,
                              size: CGFloat = 15,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) { circleLabel(symbol, size: size) }
            .accessibilityLabel(label)
    }

    private var foregroundScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }

    private var rotationLabel: String {
        foregroundScene?.interfaceOrientation.isLandscape == true
            ? "Rotate to portrait" : "Rotate to landscape"
    }

    private func rotatePlayer() {
        guard let scene = foregroundScene else { return }
        let orientation: UIInterfaceOrientationMask = scene.interfaceOrientation.isLandscape
            ? .portrait : .landscape
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
    }

    private func circleLabel(_ symbol: String, size: CGFloat = 15) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)          // touch target floor
            .background(.black.opacity(0.38), in: .circle)
    }

    private func barButton(_ symbol: String, label: String, enabled: Bool = true,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 44, height: 44)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }

    private func barLabel(_ text: String, active: Bool) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(active ? Color.accentColor : .white)
            .frame(minWidth: 44, minHeight: 44)
    }

}

/// Compact feedback shared by web and local playback gestures. The fill is
/// normalized to each control's real range: brightness 0...100, volume 0...200.
struct PlayerLevelHUD: View {
    enum Kind {
        case brightness
        case volume

        var title: String { self == .brightness ? "Brightness" : "Volume" }
        var symbol: String { self == .brightness ? "sun.max.fill" : "speaker.wave.3.fill" }
        var maximum: Double { self == .brightness ? 100 : 200 }
    }

    let kind: Kind
    let percent: Int
    let isActive: Bool

    private var boosted: Bool { percent > 100 }
    private var atBrightnessMaximum: Bool { kind == .brightness && percent == 100 }
    private var accent: Color { boosted || atBrightnessMaximum ? .red : .white }

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: kind.symbol)
                .font(.headline)
                .foregroundStyle(accent)

            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule()
                        .fill(accent)
                        .frame(height: geometry.size.height
                               * min(max(Double(percent) / kind.maximum, 0), 1))
                }
            }
            .frame(width: 8, height: 104)

            Text("\(percent)%")
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(accent)
            if boosted {
                Text("BOOST")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.red)
            } else if atBrightnessMaximum {
                Text("MAX")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.red)
            }
        }
        .frame(width: 72)
        .padding(.vertical, 14)
        .background(.black.opacity(isActive ? 0.72 : 0.48), in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(isActive ? accent.opacity(0.8) : .clear, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.title)
        .accessibilityValue(boosted ? "\(percent) percent, boosted" : "\(percent) percent")
    }
}
