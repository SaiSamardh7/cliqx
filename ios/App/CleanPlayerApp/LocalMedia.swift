import AVFoundation
import CleanPlayer
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VLCKitSPM

/// A local file to hand to the player. `scoped` files came from the document
/// picker and hold a security-scoped resource that must be released when the
/// player closes; Photos hands us a temp copy we own outright.
///
/// `fingerprint` identifies the media by content so progress survives the file
/// moving, and `bookmark` is what lets Continue Watching reopen it later.
struct LocalVideo: Identifiable {
    let id = UUID()
    let url: URL
    let scoped: Bool
    var fingerprint: String?
    var bookmark: Data?
    var sourceKind: String = "file"
    var displayName: String = ""
    /// Where to start, from a saved position.
    var resumeMs: Int = 0
}

/// VLCKit plays what AVFoundation will not — MKV, AVI, FLV, odd codecs — so
/// every local file goes through it and there is one player, not two. The cost
/// is VLC's software decode is less power-efficient than AVPlayer for plain
/// H.264/HEVC, and PiP is not built in.
///
/// ponytail: one engine for all local files. Ceiling — no PiP, and AVPlayer
/// would sip less battery on MP4. Split by format only if that bites.
@MainActor
final class LocalPlayerModel: NSObject, ObservableObject, @preconcurrency VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()

    @Published var isPlaying = false
    @Published var position: Float = 0          // 0…1, for the scrubber
    @Published var elapsed = "0:00"
    @Published var remaining = "-0:00"
    @Published var volumePercent = 100

    /// Embedded tracks the file carries, for the subtitle/audio pickers.
    @Published var subtitleTracks: [(id: Int32, name: String)] = []
    @Published var audioTracks: [(id: Int32, name: String)] = []

    /// While the user drags the scrubber the player keeps reporting its old
    /// position; holding this stops the thumb fighting the finger.
    private var scrubbing = false

    /// Applied once the media reports a length — VLC cannot seek before it has
    /// parsed the file, so the resume position waits for the first real tick.
    private var pendingResumeMs = 0
    private var didResume = false
    private var didReadTracks = false

    /// Called with (positionMs, durationMs) on the plan's save points.
    var onProgress: (Int, Int) -> Void = { _, _ in }

    func start(url: URL, resumeMs: Int = 0) {
        pendingResumeMs = resumeMs
        didResume = resumeMs <= 0
        player.delegate = self
        player.media = VLCMedia(url: url)
        player.play()
    }

    /// Save points from the plan: every 5s while playing, plus pause, PiP or
    /// background transitions, and shutdown — all routed through here.
    func reportProgress() {
        let length = Int(player.media?.length.intValue ?? 0)
        guard length > 0 else { return }
        onProgress(Int(player.time.intValue), length)
    }

    func selectSubtitle(_ id: Int32) {
        player.currentVideoSubTitleIndex = id
    }

    func selectAudio(_ id: Int32) {
        player.currentAudioTrackIndex = id
    }

    func setVolume(_ percent: Int) {
        let safe = min(max(percent, 0), 200)
        player.audio?.volume = Int32(safe)
        volumePercent = safe
    }

    func stop() { player.stop() }

    func togglePlay() { player.isPlaying ? player.pause() : player.play() }

    /// Relative seek in seconds, clamped to the media length.
    func skip(_ seconds: Double) {
        let length = Double(player.media?.length.intValue ?? 0)   // ms
        guard length > 0 else { return }
        let target = min(max(Double(player.time.intValue) + seconds * 1000, 0), length)
        player.time = VLCTime(int: Int32(target))
    }

    func beginScrub() { scrubbing = true }

    func scrub(to fraction: Float) { position = min(max(fraction, 0), 1) }

    func endScrub(to fraction: Float) {
        player.position = min(max(fraction, 0), 1)
        scrubbing = false
    }

    // MARK: VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ notification: Notification!) {
        isPlaying = player.isPlaying
    }

    func mediaPlayerTimeChanged(_ notification: Notification!) {
        if !scrubbing { position = player.position }
        elapsed = Self.clock(ms: player.time.intValue)
        let length = player.media?.length.intValue ?? 0
        remaining = "-" + Self.clock(ms: max(0, length - player.time.intValue))

        guard length > 0 else { return }

        // Seek to the saved position once the engine will actually accept it.
        // Seeking by fraction rather than by absolute time: the saved position
        // and the duration came from this same engine, so the ratio is
        // self-consistent even when a container's time index is unreliable —
        // which is what made an absolute seek land far from the mark.
        if !didResume, player.isSeekable {
            didResume = true
            if pendingResumeMs > 0, pendingResumeMs < Int(length) - 5000 {
                player.position = Float(pendingResumeMs) / Float(length)
            }
        }

        if !didReadTracks { readTracks() }

        // Every 5 seconds while playing.
        let now = Date()
        if now.timeIntervalSince(lastSave) >= 5 {
            lastSave = now
            reportProgress()
        }
    }

    private var lastSave = Date.distantPast

    /// VLC exposes embedded tracks only after the media is parsed, so this runs
    /// on the first real tick rather than at load.
    private func readTracks() {
        let subNames = (player.videoSubTitlesNames as? [String]) ?? []
        let subIDs = (player.videoSubTitlesIndexes as? [NSNumber]) ?? []
        let audNames = (player.audioTrackNames as? [String]) ?? []
        let audIDs = (player.audioTrackIndexes as? [NSNumber]) ?? []
        guard !subIDs.isEmpty || !audIDs.isEmpty else { return }
        didReadTracks = true
        subtitleTracks = zip(subIDs, subNames).map { ($0.int32Value, $1) }
        audioTracks = zip(audIDs, audNames).map { ($0.int32Value, $1) }
    }

    /// ms → M:SS or H:MM:SS. VLCTime.stringValue drops to the OS locale and
    /// has no "time left" form, so the two labels are formatted here.
    private static func clock(ms: Int32) -> String {
        let total = Int(ms) / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}

/// VLC renders into a plain UIView, which is exactly what lets us put our own
/// gesture and control layer on top.
struct VLCVideoSurface: UIViewRepresentable {
    let player: VLCMediaPlayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        player.drawable = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}
}

/// The system Photos picker. Out-of-process, so it needs no photo-library
/// permission and sees nothing the user does not hand it.
///
/// `onFinish` always fires — with a URL when a video was chosen, nil on
/// cancel — so the host can dismiss the sheet either way. The host presents
/// the player from the sheet's onDismiss, never in this callback: presenting a
/// cover in the same tick the sheet is dismissing loses the cover.
struct PhotoVideoPicker: UIViewControllerRepresentable {
    let onFinish: (URL?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onFinish: (URL?) -> Void
        init(onFinish: @escaping (URL?) -> Void) { self.onFinish = onFinish }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider,
                  provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
            else { DispatchQueue.main.async { self.onFinish(nil) }; return }
            // The representation URL is valid only inside the closure, so copy
            // it out to tmp before returning. iOS reclaims tmp on its own.
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                let copy = url.map { src -> URL in
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + "-" + src.lastPathComponent)
                    try? FileManager.default.copyItem(at: src, to: dest)
                    return dest
                }
                DispatchQueue.main.async { self.onFinish(copy) }
            }
        }
    }
}

/// The local player: VLC video, our gesture layer, minimal controls. Vertical
/// drags on the left set brightness, on the right set volume; horizontal drags
/// seek — the same arbitration the web player uses, via PlayerGestureClassifier.
struct LocalPlayerView: View {
    let video: LocalVideo
    let onClose: () -> Void
    @ObservedObject var gestureSettings: PlayerGestureSettings
    /// (positionMs, durationMs) at each of the plan's save points.
    var onProgress: (Int, Int) -> Void = { _, _ in }

    @StateObject private var model = LocalPlayerModel()
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    // Drag state, mirrored from PlayerOverlay's gesture. Two small copies beat
    // abstracting the working web overlay for the sake of it.
    @State private var dragAction: PlayerDragAction?
    @State private var dragStartBrightness: CGFloat = 0
    @State private var dragStartVolume = 100
    @State private var seekFlash: Double?
    @State private var gestureBrightnessPercent: Int?
    @State private var gestureVolumePercent: Int?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VLCVideoSurface(player: model.player)
                .ignoresSafeArea()
                // VLC's drawable is a UIKit view and swallows touches, so the
                // surface is taken out of hit testing entirely.
                .allowsHitTesting(false)

            // The catcher. Nearly-but-not-fully transparent on purpose: a
            // genuinely drawn layer reliably takes part in hit testing above a
            // UIViewRepresentable, where Color.clear did not.
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture { toggleControls() }
                .simultaneousGesture(dragGesture)

            if let seekFlash {
                Label("\(Int(abs(seekFlash)))s",
                      systemImage: seekFlash < 0 ? "gobackward.10" : "goforward.10")
                    .font(.headline)
                    .padding(14)
                    .background(.black.opacity(0.6), in: .capsule)
                    .foregroundStyle(.white)
            }

            if gestureBrightnessPercent != nil || gestureVolumePercent != nil {
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
            }

            if controlsVisible { controls }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            MediaSession.activate()
            model.onProgress = onProgress
            model.start(url: video.url, resumeMs: video.resumeMs)
            scheduleHide()
        }
        .onDisappear {
            // Shutdown save, before the engine is torn down.
            model.reportProgress()
            model.stop()
            if video.scoped { video.url.stopAccessingSecurityScopedResource() }
        }
        // Backgrounding is a save point too.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didEnterBackgroundNotification)) { _ in
            model.reportProgress()
        }
    }

    private var controls: some View {
        VStack {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .padding(12)
                        .background(.black.opacity(0.4), in: .circle)
                }
                .accessibilityLabel("Close")
                Spacer()
                volumeMenu
                if !model.subtitleTracks.isEmpty || !model.audioTracks.isEmpty {
                    trackMenu
                }
            }
            .padding()

            Spacer()

            Button {
                model.togglePlay()
                model.reportProgress()      // pause is a save point
                scheduleHide()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")

            Spacer()

            HStack(spacing: 10) {
                Text(model.elapsed).font(.caption.monospacedDigit())
                Slider(value: Binding(get: { model.position },
                                      set: { model.scrub(to: $0) }),
                       in: 0...1) { editing in
                    if editing { model.beginScrub() }
                    else { model.endScrub(to: model.position); scheduleHide() }
                }
                Text(model.remaining).font(.caption.monospacedDigit())
            }
            .foregroundStyle(.white)
            .padding()
            .background(.black.opacity(0.4))
        }
        .tint(.white)
    }

    /// Embedded subtitle and audio tracks — the thing MKV carries several of.
    private var trackMenu: some View {
        Menu {
            if !model.subtitleTracks.isEmpty {
                Section("Subtitles") {
                    ForEach(model.subtitleTracks, id: \.id) { track in
                        Button(track.name) { model.selectSubtitle(track.id) }
                    }
                }
            }
            if !model.audioTracks.isEmpty {
                Section("Audio") {
                    ForEach(model.audioTracks, id: \.id) { track in
                        Button(track.name) { model.selectAudio(track.id) }
                    }
                }
            }
        } label: {
            Image(systemName: "captions.bubble")
                .font(.title3.weight(.semibold))
                .padding(12)
                .background(.black.opacity(0.4), in: .circle)
        }
        .accessibilityLabel("Subtitles and audio tracks")
    }

    private var volumeMenu: some View {
        Menu {
            Picker("Volume", selection: Binding(
                get: { model.volumePercent },
                set: { model.setVolume($0); scheduleHide() }
            )) {
                ForEach([0, 25, 50, 75, 100, 125, 150, 175, 200], id: \.self) { level in
                    Text(level > 100 ? "\(level)% Boost" : "\(level)%").tag(level)
                }
            }
            Divider()
            Text("Above 100% may distort loud audio")
        } label: {
            Image(systemName: model.volumePercent > 100
                  ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
                .font(.title3.weight(.semibold))
                .padding(12)
                .background(.black.opacity(0.4), in: .circle)
        }
        .accessibilityLabel("Volume, \(model.volumePercent) percent")
    }

    // MARK: Gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                let size = UIScreen.main.bounds.size
                let width = max(Double(size.width), 1)
                if dragAction == nil {
                    dragAction = PlayerGestureClassifier.classify(
                        dx: Double(value.translation.width),
                        dy: Double(value.translation.height),
                        startXFraction: Double(value.startLocation.x) / width)
                    dragStartBrightness = UIScreen.main.brightness
                    dragStartVolume = model.volumePercent
                }
                guard let dragAction else { return }
                switch dragAction {
                case .seek:
                    guard gestureSettings.swipeSeeking else { return }
                    seekFlash = PlayerGestureClassifier
                        .seekDelta(dx: Double(value.translation.width), width: width).rounded()
                case .brightness:
                    guard gestureSettings.brightnessAndVolume else { return }
                    let change = -value.translation.height / max(size.height, 1)
                    let brightness = min(max(dragStartBrightness + change, 0), 1)
                    UIScreen.main.brightness = brightness
                    gestureBrightnessPercent = Int((brightness * 100).rounded())
                    gestureVolumePercent = model.volumePercent
                case .volume:
                    guard gestureSettings.brightnessAndVolume else { return }
                    let change = Int((-value.translation.height
                                      / max(size.height, 1) * 200).rounded())
                    let volume = min(max(dragStartVolume + change, 0), 200)
                    model.setVolume(volume)
                    gestureBrightnessPercent = Int((UIScreen.main.brightness * 100).rounded())
                    gestureVolumePercent = volume
                case .dismiss:
                    break
                }
            }
            .onEnded { value in
                defer {
                    dragAction = nil
                    seekFlash = nil
                    gestureBrightnessPercent = nil
                    gestureVolumePercent = nil
                }
                if dragAction == .dismiss, gestureSettings.swipeToDismiss,
                   PlayerGestureClassifier.shouldDismiss(dx: Double(value.translation.width),
                                                         dy: Double(value.translation.height)) {
                    onClose()
                    return
                }
                guard dragAction == .seek, gestureSettings.swipeSeeking else { return }
                let width = max(Double(UIScreen.main.bounds.width), 1)
                let delta = PlayerGestureClassifier
                    .seekDelta(dx: Double(value.translation.width), width: width).rounded()
                model.skip(delta)
                scheduleHide()
            }
    }

    private func toggleControls() {
        controlsVisible.toggle()
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard controlsVisible else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, model.isPlaying else { return }
            controlsVisible = false
        }
    }
}
