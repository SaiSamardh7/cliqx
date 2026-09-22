import CleanPlayer
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct HomeView: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var rules: RuleListController
    @ObservedObject var settings: ProtectionSettings
    @ObservedObject var gestureSettings: PlayerGestureSettings
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
                    if !library.continueWatching.isEmpty { continueWatchingSection }
                    if model.pinned.isEmpty && model.recents.isEmpty
                        && library.continueWatching.isEmpty {
                        emptyLibrary
                    } else {
                        // Recent sits above Pinned: what you just watched is
                        // what you are most likely to want back, so it stays in
                        // view without scrolling past the pins.
                        if !model.unpinnedRecents.isEmpty {
                            librarySection(title: "Recent", sites: model.unpinnedRecents, showClear: true)
                        }
                        if !model.pinned.isEmpty {
                            librarySection(title: "Pinned", sites: model.pinned, showClear: false)
                        }
                    }
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
                             gestureSettings: gestureSettings,
                             onProtectionChanged: {})
            }
            .sheet(isPresented: $addingServer) { AddServerSheet(servers: servers) }
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
                                gestureSettings: gestureSettings) { position, duration in
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
                                       rules: rules, gestureSettings: gestureSettings)
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
            Button { model.open(site.url) } label: { posterArt(site) }
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

    /// Local files you were partway through — the plan's Continue Watching.
    private var continueWatchingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Continue watching").font(.title3.weight(.semibold))
            LazyVGrid(columns: posterColumns, spacing: 16) {
                ForEach(library.continueWatching) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Button { resume(item) } label: {
                            Color(.tertiarySystemFill)
                                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .overlay {
                                    Image(systemName: "film")
                                        .font(.system(size: 34))
                                        .foregroundStyle(.secondary)
                                }
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: "play.circle.fill")
                                        .font(.title)
                                        .foregroundStyle(.white, .black.opacity(0.45))
                                        .padding(10)
                                }
                                .overlay(alignment: .bottom) {
                                    if let progress = item.progress {
                                        GeometryReader { geo in
                                            Rectangle().fill(.red)
                                                .frame(width: geo.size.width * progress, height: 3)
                                                .frame(maxHeight: .infinity, alignment: .bottom)
                                        }
                                    }
                                }
                                .clipShape(.rect(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .topTrailing) {
                            Menu {
                                Button(role: .destructive) {
                                    library.remove(item.fingerprint)
                                } label: { Label("Remove", systemImage: "trash") }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 30, height: 30)
                                    .background(.black.opacity(0.45), in: .circle)
                            }
                            .padding(6)
                        }
                        Text(item.displayName).font(.subheadline).lineLimit(2)
                        Text(Self.remaining(item)).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("\(item.displayName), \(Self.remaining(item))")
                }
            }
        }
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
