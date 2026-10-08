import CleanPlayer
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct HomeView: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var rules: RuleListController
    @ObservedObject var settings: ProtectionSettings
    @ObservedObject var gestureSettings: PlayerGestureSettings
    @ObservedObject var playback: PlaybackPreferences
    @FocusState private var searchFocused: Bool
    @State private var showingSettings = false
    /// The browser entry is a button, not the first thing on screen: this app
    /// leads with what you watch, and reveals the address field on demand.
    @State private var showingSearch = false

    /// Local playback: pick a file or a Photos video, play it in the native
    /// player. `playing` non-nil drives the full-screen cover.
    /// Local playback progress — Continue Watching reads it, the player writes.
    @StateObject private var library = MediaLibrary()
    /// Media servers the user signed into. Their own shelf, above the web.
    @StateObject private var servers = JellyfinServers()
    @State private var addingServer = false
    /// What every signed-in server says you were part-way through. The server
    /// is the source of truth for position, so this is read from it rather
    /// than stored here — nothing to keep in step, and the phone, the TV and
    /// the browser already agree.
    @State private var serverResume: [ServerResumeItem] = []
    @StateObject private var serverPlayback = ServerPlayback()
    /// What this device remembers watching from a server, for when the server
    /// itself cannot be reached. Shared, because the engine writes to it from
    /// wherever playback was started.
    @ObservedObject private var serverMemory = ServerHistory.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var importingFile = false
    @State private var pickingPhoto = false
    @State private var playing: LocalVideo?
    /// Set when a saved bookmark no longer resolves, so we can ask for access
    /// again rather than failing silently.
    @State private var staleItem: MediaProgress?
    /// Held between the Photos sheet dismissing and the player presenting, so
    /// the two do not fight over the same runloop tick.
    @State private var pendingPhoto: URL?

    /// What the file picker will let you choose. `.movie` alone greys out MKV
    /// in the browser even though it conforms — VLC plays these, so name the
    /// container types explicitly rather than trust conformance.
    static let playableTypes: [UTType] = {
        var types: [UTType] = [.movie, .video, .audiovisualContent]
        for ext in ["mkv", "avi", "flv", "ts", "m2ts", "webm", "wmv", "ogv", "mov", "mp4", "m4v"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }()

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 16)]
    /// Poster grid for the library. Wider minimum than the shortcut tiles —
    /// these are the hero, not a row of favicons.
    private let posterColumns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    deviceBar
                    serversSection
                    browseBar
                    if rules.status.isPreparing { preparingNote }
                    shelves
                    tiles(title: "Places to start", sites: model.shortcuts)
                }
                .padding(20)
                // iPad: a full-width list of one-line rows is unreadable and
                // the tile grid sprawls. Cap the measure and centre it.
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Cliqx")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showingSettings) {
                // Nothing to reload: the home screen has no web view. The
                // empty closure is the statement, not an omission.
                SettingsView(model: model, rules: rules, settings: settings,
                             gestureSettings: gestureSettings, playback: playback,
                             onProtectionChanged: {})
            }
            .sheet(isPresented: $addingServer) {
                AddServerSheet(servers: servers) { url in
                    playing = streamVideo(for: url)
                }
            }
            // Re-read when a server is added or removed, and again whenever the
            // app comes back to the front: the position moves while you are
            // watching on the television, and a stale row is the whole reason
            // this is read from the server rather than remembered here.
            .task(id: servers.servers.map(\.id)) { await loadServerResume() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await loadServerResume() }
            }
            .serverPlayer(serverPlayback, servers: servers, rules: rules,
                          gestureSettings: gestureSettings,
                          subtitleStyle: playback.subtitles) {
                Task { await loadServerResume() }
            }
            .fileImporter(isPresented: $importingFile,
                          allowedContentTypes: Self.playableTypes,
                          allowsMultipleSelection: false) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                // A document-picker URL is security-scoped; playing it requires
                // holding access open until the player closes.
                let scoped = url.startAccessingSecurityScopedResource()
                playing = localVideo(for: url, scoped: scoped, sourceKind: "file",
                                     // Bookmark only after explicit selection,
                                     // which is exactly what just happened.
                                     bookmark: try? url.bookmarkData())
            }
            .sheet(isPresented: $pickingPhoto, onDismiss: {
                if let url = pendingPhoto {
                    pendingPhoto = nil
                    // No bookmark: a Photos export is a temp copy with no
                    // durable identity, so it resumes if re-picked but cannot
                    // be reopened from Continue Watching.
                    playing = localVideo(for: url, scoped: false,
                                         sourceKind: "photos", bookmark: nil)
                }
            }) {
                PhotoVideoPicker { url in
                    pendingPhoto = url
                    pickingPhoto = false
                }
                .ignoresSafeArea()
            }
            // A bookmark can go stale when the file moves or access lapses;
            // the plan's answer is to ask for access again, not to fail quietly.
            .alert("Can't open this file",
                   isPresented: Binding(get: { staleItem != nil },
                                        set: { if !$0 { staleItem = nil } })) {
                Button("Choose again") { staleItem = nil; importingFile = true }
                Button("Remove", role: .destructive) {
                    if let staleItem { library.remove(staleItem.fingerprint) }
                    staleItem = nil
                }
                Button("Cancel", role: .cancel) { staleItem = nil }
            } message: {
                Text("It may have been moved, renamed, or deleted. Pick it again to keep watching.")
            }
            .fullScreenCover(item: $playing) { video in
                LocalPlayerView(video: video, onClose: { playing = nil },
                                gestureSettings: gestureSettings,
                                subtitleStyle: playback.subtitles) { position, duration in
                    guard let fingerprint = video.fingerprint else { return }
                    library.save(fingerprint: fingerprint, sourceKind: video.sourceKind,
                                 displayName: video.displayName,
                                 positionMs: position, durationMs: duration,
                                 bookmark: video.bookmark)
                }
            }
        }
    }

    /// The one-time first-launch state. Saying "basic blocking is already on"
    /// matters: the alternative reading is that nothing is protecting you yet.
    private var preparingNote: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Preparing full protection\u{2026} basic blocking is already on.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    /// Servers the user has signed into, one tile each, plus the way to add
    /// one. Jellyfin today; the tile shape does not care.
    private var serversSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Servers").font(.title3.weight(.semibold))
                Spacer()
                Button { addingServer = true } label: {
                    Label("Add", systemImage: "plus").font(.subheadline)
                }
                .accessibilityLabel("Add server")
            }
            if servers.servers.isEmpty {
                Button { addingServer = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "server.rack")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Add your media server").fontWeight(.medium)
                            Text("Jellyfin — movies and shows from your own server, "
                                 + "with resume that follows you.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            } else {
                ForEach(servers.servers) { server in
                    NavigationLink {
                        ServerHomeView(servers: servers, server: server,
                                       rules: rules, gestureSettings: gestureSettings,
                                       preferences: playback)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "server.rack")
                                .font(.title3)
                                .frame(width: 44, height: 44)
                                .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name).fontWeight(.medium)
                                Text("\(server.username) · \(server.url.host() ?? "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    // A signed-in server, as opposed to the prompt to add one
                    // — whose copy also says "Jellyfin", which is how a UI
                    // test looking for a server row opened the Add sheet on a
                    // machine that had none.
                    .accessibilityIdentifier("server.row")
                }
            }
        }
    }

    /// Play something already on the device. Two native pickers, no
    /// permissions: Files/iCloud via the document importer, the camera roll
    /// via the Photos picker.
    private var deviceBar: some View {
        HStack(spacing: 12) {
            deviceButton(title: "Open file", systemImage: "folder") {
                importingFile = true
            }
            deviceButton(title: "Photos", systemImage: "photo.on.rectangle") {
                pickingPhoto = true
            }
        }
    }

    private func deviceButton(title: String, systemImage: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(title).fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    /// Collapsed: a Browse button. Tapped: the address field, focused. One
    /// control either way, so the browser is always one tap from home without
    /// being the face of it.
    @ViewBuilder private var browseBar: some View {
        if showingSearch {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search or enter address", text: $model.address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.webSearch)
                    .submitLabel(.go)
                    .focused($searchFocused)
                    .onSubmit { model.submitAddress() }
                if !model.address.isEmpty {
                    Button {
                        model.address = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
        } else {
            Button {
                showingSearch = true
                searchFocused = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "globe")
                    Text("Browse the web").fontWeight(.medium)
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Browse the web")
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 10) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Nothing watched yet")
                .font(.headline)
            Text("Browse to a video site and tap Watch clean, or enter your media "
                 + "server's address and choose Add to Home to keep it here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func librarySection(title: String, sites: [Site], showClear: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.title3.weight(.semibold))
                Spacer()
                if showClear {
                    Button("Clear", role: .destructive) { model.clearRecents() }
                        .font(.subheadline)
                }
            }
            LazyVGrid(columns: posterColumns, spacing: 16) {
                ForEach(sites) { site in
                    posterCard(site)
                }
            }
        }
    }

    private func posterCard(_ site: Site) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { model.openWatched(site.url) } label: { posterArt(site) }
                .buttonStyle(.plain)
                .overlay(alignment: .topTrailing) {
                    cardMenu(site).padding(6)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(site.seriesTitle ?? site.title).font(.subheadline).lineLimit(2)
                Text(site.episodeLabel ?? site.host)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(site.seriesTitle ?? site.title), "
                            + "\(site.episodeLabel ?? site.host)")
    }

    /// The 16:9 media tile: a captured poster if there is one, else a monogram,
    /// with the play glyph and the resume bar over it. A clear slot defines the
    /// size and the poster fills it, so every card is the same shape.
    private func posterArt(_ site: Site) -> some View {
        Color(.tertiarySystemFill)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let poster = Thumbnails.image(for: site.url) {
                    Image(uiImage: poster).resizable().scaledToFill()
                } else {
                    Text(site.initials)
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "play.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white, .black.opacity(0.45))
                    .padding(10)
            }
            .overlay(alignment: .bottom) {
                if let progress = site.progress {
                    GeometryReader { geo in
                        Rectangle().fill(.red)
                            .frame(width: geo.size.width * progress, height: 3)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            .clipShape(.rect(cornerRadius: 14))
    }

    /// Fingerprint the file, look up any saved position, and bundle what the
    /// player and the progress store both need.
    private func localVideo(for url: URL, scoped: Bool,
                            sourceKind: String, bookmark: Data?) -> LocalVideo {
        let fingerprint = MediaFingerprint.compute(url: url)
        let saved = fingerprint.flatMap { library.progress(for: $0) }
        return LocalVideo(
            url: url, scoped: scoped,
            fingerprint: fingerprint,
            bookmark: bookmark,
            sourceKind: sourceKind,
            displayName: url.deletingPathExtension().lastPathComponent,
            // A finished video starts over rather than resuming at the end.
            resumeMs: (saved?.completed == true) ? 0 : (saved?.positionMs ?? 0))
    }

    /// A URL played directly, with nothing stored about it.
    ///
    /// No fingerprint, so no position is saved and no Continue Watching card
    /// appears. `MediaFingerprint.compute` hashes the first 256 KB off disk
    /// and returns nil for anything it cannot open as a file, so a stream
    /// would get nil here anyway — this says so deliberately rather than
    /// relying on that. Resuming a stream needs the URL persisted in
    /// `MediaProgress`, which it has no field for; until it does, a card that
    /// cannot reopen is worse than no card.
    ///
    /// ponytail: play it and forget it. Add the URL field when someone asks
    /// to resume a stream, not before.
    private func streamVideo(for url: URL) -> LocalVideo {
        LocalVideo(url: url, scoped: false, fingerprint: nil, bookmark: nil,
                   sourceKind: "url",
                   displayName: StreamAddress.displayName(for: url))
    }

    /// Reopen from a saved bookmark. A stale bookmark means the file moved or
    /// access lapsed, so the picker is the honest fallback.
    private func resume(_ item: MediaProgress) {
        guard let bookmark = item.bookmark,
              let url = MediaLibrary.resolve(bookmark: bookmark) else {
            staleItem = item
            return
        }
        playing = localVideo(for: url, scoped: true,
                             sourceKind: item.sourceKind, bookmark: bookmark)
    }

    /// One thing to carry on with, wherever it came from.
    ///
    /// A server episode, a file on this device and a page on the web are three
    /// unrelated things to the code and the same thing to the person looking at
    /// the shelf: something they were part way through. The shelf is sorted
    /// across all three, so they need one notion of when it was last watched
    /// and one of what to draw.
    private enum ContinueItem: Identifiable {
        case server(ServerResumeItem)
        case file(MediaProgress)
        case page(Site)

        var id: String {
            switch self {
            case .server(let entry): "server|\(entry.id)"
            case .file(let item): "file|\(item.fingerprint)"
            case .page(let site): "page|\(site.url.absoluteString)"
            }
        }

        var lastPlayed: Date {
            switch self {
            case .server(let entry): entry.item.userData?.lastPlayedDate ?? .distantPast
            case .file(let item): item.updatedAt
            case .page(let site): site.lastPlayed ?? .distantPast
            }
        }

        var progress: Double? {
            switch self {
            case .server(let entry): entry.item.progress
            case .file(let item): item.progress
            case .page(let site): site.progress
            }
        }

        var title: String {
            switch self {
            case .server(let entry): entry.item.seriesName ?? entry.item.name
            case .file(let item): item.displayName
            case .page(let site): site.seriesTitle ?? site.title
            }
        }

        /// The second line: which episode, how much is left, or which site.
        var detail: String {
            switch self {
            case .server(let entry):
                let item = entry.item
                if item.seriesName == nil { return item.subtitle ?? entry.server.name }
                return [item.subtitle, item.name].compactMap { $0 }.joined(separator: " \u{00B7} ")
            case .file(let item): return HomeView.remaining(item)
            case .page(let site): return site.episodeLabel ?? site.host
            }
        }
    }

    /// Everything part way through, newest first, whatever holds it. This was
    /// three shelves — a server row, a local grid and "Recent" — which is three
    /// places to look for the one thing the question "what was I watching?"
    /// means.
    private var continueItems: [ContinueItem] {
        (serverResume.map(ContinueItem.server)
            + library.continueWatching.map(ContinueItem.file)
            + model.unpinnedRecents.map(ContinueItem.page))
            .sorted { $0.lastPlayed > $1.lastPlayed }
    }

    /// Lifted out of `body`: with every shelf inline the whole view stopped
    /// type-checking in reasonable time.
    @ViewBuilder
    private var shelves: some View {
        let carryOn = continueItems
        if !carryOn.isEmpty { continueWatchingSection(carryOn) }
        // Pinned stays its own shelf: pinning is how you say "keep this",
        // which is a different statement from "I was part way through this".
        if !model.pinned.isEmpty {
            librarySection(title: "Pinned", sites: model.pinned, showClear: false)
        }
        if carryOn.isEmpty && model.pinned.isEmpty { emptyLibrary }
    }

    private func continueWatchingSection(_ items: [ContinueItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Continue Watching").font(.title3.weight(.semibold))
                Spacer()
                Button("Clear", role: .destructive) { clearShelf() }
                    .font(.subheadline)
            }
            LazyVGrid(columns: posterColumns, spacing: 16) {
                ForEach(items) { continueTile($0) }
            }
        }
    }

    /// Clears what THIS DEVICE holds. An item the server still lists in its own
    /// Continue Watching comes back on the next read, because the server is the
    /// authority on its own history and this button is not a way to argue with
    /// it — remove it there, or finish watching it.
    private func clearShelf() {
        model.clearRecents()
        library.clear()
        serverMemory.forgetAll()
        Task { await loadServerResume() }
    }

    private func continueTile(_ entry: ContinueItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open(entry) } label: { continueArt(entry) }
                .buttonStyle(.plain)
                .overlay(alignment: .topTrailing) { continueMenu(entry).padding(6) }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.subheadline).lineLimit(2)
                Text(entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.title), \(entry.detail)")
    }

    private func open(_ entry: ContinueItem) {
        switch entry {
        case .server(let e): serverPlayback.play(e.item, on: e.server)
        case .file(let item): resume(item)
        case .page(let site): model.openWatched(site.url)
        }
    }

    /// The 16:9 tile every kind shares: its own artwork, the play glyph, and
    /// the resume bar. One slot defines the size and the art fills it, so a
    /// shelf of three different sources is still one shelf.
    private func continueArt(_ entry: ContinueItem) -> some View {
        Color(.tertiarySystemFill)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay { artwork(entry) }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "play.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white, .black.opacity(0.45))
                    .padding(10)
            }
            .overlay(alignment: .bottom) {
                if let progress = entry.progress {
                    GeometryReader { geo in
                        Rectangle().fill(.red)
                            .frame(width: geo.size.width * progress, height: 3)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            .clipShape(.rect(cornerRadius: 14))
    }

    @ViewBuilder
    private func artwork(_ entry: ContinueItem) -> some View {
        switch entry {
        case .server(let e):
            // The wide still where the server has one, its poster otherwise.
            if let backdrop = e.item.backdrop {
                RemoteImage(url: JellyfinAPI.imageURL(server: e.server.url, itemID: backdrop.itemID,
                                                      tag: backdrop.tag, kind: .backdrop, maxHeight: 300))
            } else {
                RemoteImage(url: JellyfinAPI.imageURL(server: e.server.url, itemID: e.item.id,
                                                      tag: e.item.primaryImageTag, maxHeight: 300))
            }
        case .file:
            Image(systemName: "film").font(.system(size: 34)).foregroundStyle(.secondary)
        case .page(let site):
            if let poster = Thumbnails.image(for: site.url) {
                Image(uiImage: poster).resizable().scaledToFill()
            } else {
                Text(site.initials)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A server item has no menu: removing it here would not remove it there,
    /// and a Remove that does nothing is worse than none.
    @ViewBuilder
    private func continueMenu(_ entry: ContinueItem) -> some View {
        switch entry {
        case .server:
            EmptyView()
        case .file(let item):
            Menu {
                Button(role: .destructive) {
                    library.remove(item.fingerprint)
                } label: { Label("Remove", systemImage: "trash") }
            } label: { menuGlyph }
        case .page(let site):
            cardMenu(site)
        }
    }

    private var menuGlyph: some View {
        Image(systemName: "ellipsis")
            .font(.footnote.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(.black.opacity(0.45), in: .circle)
    }

    private func loadServerResume() async {
        // In parallel, like the server shelf's own rows: a server that is off
        // sits on a 15-second timeout, and asking them in turn would make the
        // live one wait behind the dead one on every return to the app.
        //
        // nil from a server means it could not be answered at all, which is a
        // different thing from an empty list and the only case where what this
        // device remembers gets to stand in.
        let clients = servers.servers.map { ($0, servers.client(for: $0)) }
        let replies = await withTaskGroup(of: (JellyfinServer, [JellyfinItem]?).self) { group in
            for (server, client) in clients {
                group.addTask {
                    (server, try? await client.resume(userID: server.userID))
                }
            }
            var all: [(JellyfinServer, [JellyfinItem]?)] = []
            for await reply in group { all.append(reply) }
            return all
        }

        var live: [ServerResumeItem] = []
        var answered: Set<String> = []
        for (server, items) in replies {
            guard let items else { continue }
            answered.insert(server.id)
            live += items.map { ServerResumeItem(server: server, item: $0) }
        }

        // A server that answered has had its say, including when it said
        // nothing: an item it no longer lists is one the user finished.
        let byID = Dictionary(uniqueKeysWithValues: servers.servers.map { ($0.id, $0) })
        let remembered = serverMemory.standingIn(forServersOtherThan: answered)
            .compactMap { entry in
                byID[entry.serverID].map { ServerResumeItem(server: $0, item: entry.item) }
            }
        serverResume = live + remembered
    }

    private static func remaining(_ item: MediaProgress) -> String {
        let left = max(0, item.durationMs - item.positionMs) / 1000
        return left >= 3600
            ? "\(left / 3600) hr \((left % 3600) / 60) min left"
            : "\(max(1, left / 60)) min left"
    }

    /// The three-dot menu on each card: pin, copy, remove.
    private func cardMenu(_ site: Site) -> some View {
        Menu {
            Button {
                model.togglePin(site)
            } label: {
                Label(model.isPinned(site) ? "Unpin" : "Pin",
                      systemImage: model.isPinned(site) ? "pin.slash" : "pin")
            }
            // Only for a pinned site, and off by default: this gives the
            // site's session cookies an expiry the server did not set, so it
            // has to be something the user asked for rather than something
            // pinning did to them.
            if model.isPinned(site) {
                Button {
                    model.setStaySignedIn(!model.keepsSignIn(site.host), for: site)
                } label: {
                    Label(model.keepsSignIn(site.host)
                            ? "Don't stay signed in" : "Stay signed in",
                          systemImage: model.keepsSignIn(site.host)
                            ? "person.badge.minus" : "person.badge.key")
                }
            }
            Button {
                UIPasteboard.general.string = site.url.absoluteString
            } label: {
                Label("Copy link", systemImage: "doc.on.doc")
            }
            Button(role: .destructive) {
                model.remove(site)
                Thumbnails.remove(for: site.url)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.black.opacity(0.45), in: .circle)
        }
        .accessibilityLabel("More options for \(site.title)")
    }

    private func tiles(title: String, sites: [Site]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(sites) { site in
                    Button { model.open(site.url) } label: { tile(site) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(site.title), \(site.host)")
                }
            }
        }
    }

    private func tile(_ site: Site) -> some View {
        VStack(spacing: 6) {
            Text(site.initials)
                .font(.title2.weight(.semibold))
                .frame(width: 60, height: 60)
                .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 16))
            Text(site.title)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
    }

}

/// One thing to carry on with, and the server it came from.
struct ServerResumeItem: Identifiable {
    let server: JellyfinServer
    let item: JellyfinItem
    var id: String { "\(server.id)|\(item.id)" }
}
