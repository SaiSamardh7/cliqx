import CleanPlayer
import SwiftUI

/// The player chrome shown over a staged video.
///
/// Everything here is native. The page's own controls are hidden along with the
/// rest of the page, so if a control is not in this file the user does not have
/// it — which is why play/pause, seeking and subtitles all live here rather
/// than being left to the site.
struct PlayerOverlay: View {
    @ObservedObject var page: PageState
    @ObservedObject var rules: RuleListController

    /// Controls fade out during playback and come back on a tap. Kept here
    /// rather than in PageState because nothing outside this view cares.
    @State private var visible = true
    @State private var locked = false
    @State private var showingEpisodes = false
    @State private var hideTask: Task<Void, Never>?

    /// Non-nil only while a drag is in flight. The page keeps reporting its own
    /// position, and without holding the target the thumb jumps back under the
    /// user's finger.
    @State private var scrubTarget: Double?
    @State private var isScrubbing = false

    /// Briefly shown after a double-tap, so the gesture has a visible result.
    @State private var seekFlash: Double?

    /// Seconds left on the up-next countdown, nil when it is not running.
    /// Dismissed for this video once the user says no, so it does not come
    /// back if they replay the last few seconds.
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?
    @State private var declinedNext = false

    private static let autoHide: Duration = .seconds(3.5)
    private static let upNextSeconds = 5

    var body: some View {
        ZStack {
            tapLayer

            if locked {
                lockedAffordance
            } else if visible {
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    centreTransport
                    Spacer(minLength: 0)
                    bottomBar
                }
                .transition(.opacity)
            }

            if let flash = seekFlash { seekFlashLabel(flash) }

            if let remaining = countdown, let next = page.nextEpisode {
                upNextCard(remaining: remaining, next: next)
            }
        }
        // Must fill. The parent is a ZStack aligned to .bottom and Color.clear
        // has no intrinsic size, so without this the overlay collapses to a
        // sliver at the bottom and every tap lands on the page behind it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.18), value: visible)
        .animation(.easeInOut(duration: 0.18), value: locked)
        .onAppear { scheduleHide() }
        .onChange(of: page.isPlaying) { _, _ in scheduleHide() }
        .onChange(of: page.playbackEnded) { _, ended in
            if ended { startCountdown() } else { stopCountdown(declined: false) }
        }
        // A new episode is a new video: whatever the user declined last time
        // has nothing to do with this one.
        .onChange(of: page.nextEpisode) { _, _ in declinedNext = false }
        .onDisappear { countdownTask?.cancel() }
        .sheet(isPresented: $showingEpisodes) { episodeSheet }
    }

    // MARK: Tap and double-tap

    /// Single tap toggles the chrome; a double-tap on either half seeks.
    ///
    /// The double-tap gesture is declared first so SwiftUI gives it priority —
    /// otherwise the single tap fires immediately and the second tap only
    /// toggles the controls back.
    private var tapLayer: some View {
        HStack(spacing: 0) {
            seekHalf(by: -10)
            seekHalf(by: 10)
        }
    }

    private func seekHalf(by seconds: Double) -> some View {
        Color.clear
            .contentShape(.rect)
            .onTapGesture(count: 2) {
                guard !locked else { return }
                page.actions.skip(seconds)
                flash(seconds)
            }
            .onTapGesture { toggleControls() }
            .accessibilityHidden(true)   // the buttons carry these actions
    }

    private func toggleControls() {
        guard !locked else {
            // A locked player still has to be unlockable, so a tap reveals the
            // padlock and nothing else.
            withAnimation { visible = true }
            scheduleHide()
            return
        }
        withAnimation { visible.toggle() }
        scheduleHide()
    }

    /// Only auto-hides while something is actually playing. Hiding the controls
    /// on a paused video leaves a still frame the user cannot act on.
    private func scheduleHide() {
        hideTask?.cancel()
        guard visible, page.isPlaying else { return }
        hideTask = Task {
            try? await Task.sleep(for: Self.autoHide)
            guard !Task.isCancelled else { return }
            withAnimation { visible = false }
        }
    }

    private func flash(_ seconds: Double) {
        seekFlash = seconds
        Task {
            try? await Task.sleep(for: .seconds(0.6))
            seekFlash = nil
        }
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

    /// Offered only when the video actually finished and there is somewhere to
    /// go. A paused video must not trigger this, which is why it hangs off
    /// `playbackEnded` rather than off `isPlaying`.
    private func startCountdown() {
        guard !declinedNext, page.nextEpisode != nil else { return }
        countdownTask?.cancel()
        countdown = Self.upNextSeconds
        // The controls must not fade out from under a card that is about to
        // navigate.
        hideTask?.cancel()
        withAnimation { visible = true }

        countdownTask = Task {
            for remaining in stride(from: Self.upNextSeconds - 1, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                countdown = remaining
            }
            guard !Task.isCancelled, let next = page.nextEpisode else { return }
            countdown = nil
            page.actions.goToEpisode(next)
        }
    }

    /// `declined` separates the two ways this ends: the user said no and should
    /// not be asked again for this video, versus playback resumed and the offer
    /// is simply no longer relevant.
    private func stopCountdown(declined: Bool) {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
        if declined { declinedNext = true }
    }

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
                            stopCountdown(declined: false)
                            page.actions.goToEpisode(next)
                        } label: {
                            Label("Play now", systemImage: "play.fill")
                                .font(.footnote.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 34)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Cancel") { stopCountdown(declined: true) }
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
        .animation(.easeOut(duration: 0.22), value: countdown != nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Up next: \(nextLabel), playing in \(remaining) seconds")
    }

    private func countdownRing(_ remaining: Int) -> some View {
        ZStack {
            Circle().stroke(.white.opacity(0.25), lineWidth: 2)
            Circle()
                .trim(from: 0, to: Double(remaining) / Double(Self.upNextSeconds))
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

            if page.airplayAvailable {
                circleButton("airplayvideo", label: "AirPlay") {
                    page.actions.showAirPlay()
                }
            }
            if page.pipAvailable {
                circleButton("pip.enter", label: "Picture in Picture") {
                    page.actions.togglePiP()
                }
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
                scheduleHide()
            }
            Button {
                page.actions.togglePlay()
                scheduleHide()
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
                scheduleHide()
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
            Text(PlayerFormatting.timecode(scrubTarget ?? page.currentTime))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                // A GeometryReader takes every point it is offered, so without
                // priority the timecodes get no width at all and spill off the
                // edges: "0:29" rendered as "29", "23:40" as "23:".
                .fixedSize()
                .layoutPriority(1)

            GeometryReader { geo in
                let width = geo.size.width
                let played = fraction(scrubTarget ?? page.currentTime) * width
                let buffered = fraction(page.bufferedTo) * width

                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white.opacity(0.35)).frame(width: max(0, buffered))
                    Capsule().fill(Color.accentColor).frame(width: max(0, played))
                    Circle()
                        .fill(.white)
                        .frame(width: isScrubbing ? 17 : 12)
                        .offset(x: max(0, played - (isScrubbing ? 8.5 : 6)))
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(scrubGesture(width: width))
                .animation(.easeOut(duration: 0.12), value: isScrubbing)
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
                if !isScrubbing {
                    isScrubbing = true
                    page.actions.beginScrub()
                    hideTask?.cancel()
                }
                let ratio = min(max(value.location.x / width, 0), 1)
                scrubTarget = ratio * page.duration
            }
            .onEnded { _ in
                if let target = scrubTarget { page.actions.seek(target) }
                scrubTarget = nil
                isScrubbing = false
                scheduleHide()
            }
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
                withAnimation { locked = true; visible = true }
                scheduleHide()
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
            Button {
                page.actions.setObjectFit(page.objectFit == "cover" ? "contain" : "cover")
            } label: {
                Label(page.objectFit == "cover" ? "Fit to screen" : "Fill screen",
                      systemImage: "aspectratio")
            }
            Button { withAnimation { locked = true } } label: {
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
                    withAnimation { locked = false; visible = true }
                    scheduleHide()
                } label: {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 48, height: 48)
                        .background(.ultraThinMaterial, in: .circle)
                }
                .accessibilityLabel("Unlock controls")
                .opacity(visible ? 1 : 0)
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
