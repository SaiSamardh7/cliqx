import CleanPlayer
import SwiftUI

// MARK: - Playback, shared by the home and the grid

/// What a screen is playing from the server, if anything. The engine and
/// the progress reporting live in `ServerEngine`; this just holds the cover.
@MainActor
final class ServerPlayback: ObservableObject {
    @Published var playing: JellyfinItem?
    func play(_ item: JellyfinItem) { playing = item }
}

extension View {
    /// The full-screen Cliqx player over a server stream, and the reload once
    /// it closes: progress bars on the shelf come from the server.
    func serverPlayer(_ playback: ServerPlayback, server: JellyfinServer, servers: JellyfinServers,
                      rules: RuleListController, gestureSettings: PlayerGestureSettings,
                      subtitleStyle: SubtitleStyle,
                      onStop: @escaping () -> Void) -> some View {
        fullScreenCover(item: Binding(get: { playback.playing },
                                      set: { playback.playing = $0 }),
                        onDismiss: onStop) { item in
            ServerPlayerView(item: item, server: server, servers: servers,
                             rules: rules, gestureSettings: gestureSettings,
                             subtitleStyle: subtitleStyle,
                             onClose: { playback.playing = nil })
        }
    }
}

// MARK: - Home

/// The server's front page, the way its own web client lays it out: one
/// recommendation up top, My Media, Continue Watching, Next Up, and Recently
/// Added in each library. Every row is one endpoint; rows load independently
/// so a slow one does not hold the rest.
struct ServerHomeView: View {
    @ObservedObject var servers: JellyfinServers
    let server: JellyfinServer
    @ObservedObject var rules: RuleListController
    @ObservedObject var gestureSettings: PlayerGestureSettings
    @ObservedObject var preferences: PlaybackPreferences

    @State private var libraries: [JellyfinItem]?
    @State private var hero: JellyfinItem?
    @State private var resume: [JellyfinItem] = []
    @State private var nextUp: [JellyfinItem] = []
    @State private var latest: [String: [JellyfinItem]] = [:]
    @State private var error: String?
    @StateObject private var playback = ServerPlayback()

    /// Libraries worth a Recently Added row on a video shelf. Music and
    /// photos have their own shapes and are left to the grid.
    private var videoLibraries: [JellyfinItem] {
        (libraries ?? []).filter { ["movies", "tvshows", "homevideos", "mixed", nil].contains($0.collectionType) }
    }

    var body: some View {
        ScrollView {
            if let error {
                ContentUnavailableView {
                    Label("Couldn't reach \(server.name)", systemImage: "wifi.exclamationmark")
                } description: { Text(error) } actions: {
                    Button("Try again") { Task { await loadAll() } }
                }
                .padding(.top, 80)
            } else if libraries?.isEmpty == true {
                noLibraries
            } else {
                VStack(alignment: .leading, spacing: 28) {
                    if let hero { HeroCard(server: server, item: hero, servers: servers) { play(hero) } }
                    if let libraries, !libraries.isEmpty {
                        row("My Media") {
                            ForEach(libraries) { library in
                                NavigationLink { browser(library) } label: { LibraryCard(server: server, item: library) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    if !resume.isEmpty { row("Continue Watching") { wideCards(resume) } }
                    if !nextUp.isEmpty { row("Next Up") { wideCards(nextUp) } }
                    ForEach(videoLibraries) { library in
                        if let items = latest[library.id], !items.isEmpty {
                            row("Recently Added in \(library.name)", destination: library) {
                                ForEach(items) { item in posterCard(item) }
                            }
                        }
                    }
                    if libraries == nil { ProgressView().frame(maxWidth: .infinity).padding(.top, 60) }
                }
                .padding(.vertical, 12)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(server.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Text("Signed in as \(server.username)")
                    Button("Remove server", role: .destructive) { servers.remove(server) }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task { await loadAll() }
        .refreshable { await loadAll() }
        .serverPlayer(playback, server: server, servers: servers, rules: rules,
                      gestureSettings: gestureSettings,
                      subtitleStyle: preferences.subtitles) { Task { await loadRows() } }
    }

    // MARK: Loading

    private func loadAll() async {
        let client = servers.client(for: server)
        do {
            libraries = try await client.views(userID: server.userID)
            error = nil
        } catch {
            self.error = error.localizedDescription
            return
        }
        await loadRows()
    }

    /// Everything but the library list, in parallel. A row that fails just
    /// stays empty; the shelf is not an all-or-nothing page.
    private func loadRows() async {
        let client = servers.client(for: server)
        let user = server.userID
        async let heroTask = try? client.recommended(userID: user)
        async let resumeTask = (try? client.resume(userID: user)) ?? []
        async let nextUpTask = (try? client.nextUp(userID: user)) ?? []
        let (h, r, n) = await (heroTask, resumeTask, nextUpTask)
        // Keep the hero across refreshes unless it has been watched since.
        if hero == nil || hero.map({ item in r.contains { $0.id == item.id } }) == true { hero = h ?? hero }
        resume = r
        nextUp = n
        await withTaskGroup(of: (String, [JellyfinItem]).self) { group in
            for library in videoLibraries {
                group.addTask { (library.id, (try? await client.latest(userID: user, parentID: library.id)) ?? []) }
            }
            for await (id, items) in group { latest[id] = items }
        }
    }

    // MARK: Pieces

    private func play(_ item: JellyfinItem) { playback.play(item) }

    private func browser(_ parent: JellyfinItem) -> some View {
        ServerBrowserView(servers: servers, server: server, parent: parent,
                          rules: rules, gestureSettings: gestureSettings,
                          preferences: preferences)
    }

    /// A titled, horizontally scrolling shelf. The title itself links to the
    /// library when there is one, the way the web client's "›" does.
    private func row<Content: View>(_ title: String, destination: JellyfinItem? = nil,
                                    @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let destination {
                    NavigationLink { browser(destination) } label: {
                        HStack(spacing: 4) {
                            Text(title).font(.title3.weight(.semibold))
                            Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(title).font(.title3.weight(.semibold))
                }
            }
            .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) { content() }
                    .padding(.horizontal, 20)
            }
        }
    }

    @ViewBuilder
    private func wideCards(_ items: [JellyfinItem]) -> some View {
        ForEach(items) { item in
            Button { play(item) } label: { WideCard(server: server, item: item) }
                .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func posterCard(_ item: JellyfinItem) -> some View {
        if item.isPlayable {
            Button { play(item) } label: { PosterCard(server: server, item: item) }
                .buttonStyle(.plain)
        } else {
            NavigationLink { browser(item) } label: { PosterCard(server: server, item: item) }
                .buttonStyle(.plain)
        }
    }

    /// The honest answer to an empty shelf: the login worked and the server
    /// is fine, but the account has no libraries ticked.
    private var noLibraries: some View {
        ContentUnavailableView {
            Label("No libraries for \(server.username)", systemImage: "lock.rectangle.stack")
        } description: {
            Text("The server is up, but this account can't see any libraries. Whoever runs "
                 + "\(server.name) needs to open Dashboard → Users → \(server.username) → Access "
                 + "and enable the libraries.")
        } actions: {
            Button("Try again") { Task { await loadAll() } }
        }
        .padding(.top, 80)
    }
}

// MARK: - Cards

/// The recommendation: backdrop, the title treatment if the server has one,
/// rating · year · certificate · ends-at, genres, two lines of overview, Play.
private struct HeroCard: View {
    let server: JellyfinServer
    let item: JellyfinItem
    @ObservedObject var servers: JellyfinServers
    let play: () -> Void
    @State private var favorite: Bool
    /// Compact height is landscape on a phone.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    init(server: JellyfinServer, item: JellyfinItem, servers: JellyfinServers, play: @escaping () -> Void) {
        self.server = server; self.item = item; self.servers = servers; self.play = play
        _favorite = State(initialValue: item.userData?.isFavorite ?? false)
    }

    /// The backdrop, sized for the screen it is on.
    ///
    /// 16:9 at full width is 491pt tall on a phone held in landscape, where
    /// the whole screen is 402pt: the hero alone was taller than the viewport,
    /// so My Media, Continue Watching and every Recently Added row started
    /// below the fold and the page looked empty. Landscape gets a fixed,
    /// shorter band instead of the ratio.
    @ViewBuilder
    private var backdrop: some View {
        let art = Color.black
            .overlay {
                if let backdrop = item.backdrop {
                    RemoteImage(url: JellyfinAPI.imageURL(server: server.url, itemID: backdrop.itemID,
                                                          tag: backdrop.tag, kind: .backdrop, maxHeight: 720))
                }
            }
            .overlay {
                LinearGradient(colors: [.clear, .clear, .black.opacity(0.85)],
                               startPoint: .top, endPoint: .bottom)
            }
        if verticalSizeClass == .compact {
            art.frame(width: 300, height: 170)
        } else {
            art.aspectRatio(16 / 9, contentMode: .fit)
        }
    }

    /// Backdrop with the title or logo across the bottom of it.
    private var poster: some View {
        ZStack(alignment: .bottomLeading) {
            backdrop
            Group {
                    if let logo = JellyfinAPI.imageURL(server: server.url, itemID: item.id,
                                                       tag: item.logoImageTag, kind: .logo, maxHeight: 200) {
                        RemoteImage(url: logo, contentMode: .fit)
                            .frame(maxWidth: 220, maxHeight: 70, alignment: .leading)
                    } else {
                        Text(item.name).font(.title.weight(.bold)).foregroundStyle(.white).lineLimit(2)
                    }
                }
            .padding(16)
        }
        .clipped()
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if let rating = item.communityRating {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                            .foregroundStyle(.yellow)
                    }
                    if let year = item.yearRange { Text(year) }
                    if let cert = item.officialRating {
                        Text(cert).fontWeight(.semibold)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary, lineWidth: 1))
                    }
                    if let ends = JellyfinAPI.endsAt(runtimeTicks: item.runTimeTicks, positionMs: item.resumeMs) {
                        Text("Ends at \(ends.formatted(date: .omitted, time: .shortened))")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let genres = item.genres, !genres.isEmpty {
                    Text(genres.prefix(3).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
                if let overview = item.overview, !overview.isEmpty {
                    Text(overview).font(.subheadline).foregroundStyle(.secondary)
                        // One line in landscape: the screen is 402pt tall and
                        // every line here is a line the shelves lose.
                        .lineLimit(verticalSizeClass == .compact ? 1 : 2)
                }
                HStack(spacing: 14) {
                    Button(action: play) {
                        Label(item.resumeMs > 0 ? "Resume" : "Play", systemImage: "play.fill")
                            .fontWeight(.semibold)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        favorite.toggle()
                        servers.client(for: server).setFavorite(userID: server.userID, itemID: item.id, favorite)
                    } label: {
                        Image(systemName: favorite ? "heart.fill" : "heart")
                            .font(.title3)
                            .foregroundStyle(favorite ? .red : .primary)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(favorite ? "Remove from favorites" : "Add to favorites")
                }
                .padding(.top, 4)
        }
        .padding(16)
    }

    /// Stacked in portrait, side by side in landscape.
    ///
    /// Stacking both on a phone held sideways put the shelves below a 402pt
    /// screen — the page the server is for began off the bottom of it. In
    /// landscape the width is the thing there is plenty of, so the poster
    /// takes a fixed column and the details sit beside it.
    var body: some View {
        Group {
            if verticalSizeClass == .compact {
                HStack(alignment: .top, spacing: 0) {
                    poster
                    details
                    Spacer(minLength: 0)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    poster
                    details
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 16))
        .padding(.horizontal, 20)
        .accessibilityElement(children: .contain)
    }
}

/// A library: wide tile with its art, name beneath.
private struct LibraryCard: View {
    let server: JellyfinServer
    let item: JellyfinItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color(.tertiarySystemFill)
                .frame(width: 200, height: 112)
                .overlay {
                    RemoteImage(url: JellyfinAPI.imageURL(server: server.url, itemID: item.id,
                                                          tag: item.primaryImageTag, maxHeight: 300))
                }
                .overlay { LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom) }
                .overlay(alignment: .bottomLeading) {
                    Text(item.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white).padding(10)
                }
                .clipShape(.rect(cornerRadius: 12))
        }
        .accessibilityLabel(item.name)
    }
}

/// Continue Watching / Next Up: 16:9 still, progress bar, show and episode.
private struct WideCard: View {
    let server: JellyfinServer
    let item: JellyfinItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color(.tertiarySystemFill)
                .frame(width: 220, height: 124)
                .overlay {
                    if let backdrop = item.backdrop {
                        RemoteImage(url: JellyfinAPI.imageURL(server: server.url, itemID: backdrop.itemID,
                                                              tag: backdrop.tag, kind: .backdrop, maxHeight: 300))
                    } else {
                        RemoteImage(url: JellyfinAPI.imageURL(server: server.url, itemID: item.id,
                                                              tag: item.primaryImageTag, maxHeight: 300))
                    }
                }
                .overlay(alignment: .center) {
                    Image(systemName: "play.circle.fill").font(.system(size: 36))
                        .foregroundStyle(.white, .black.opacity(0.45))
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
                .clipShape(.rect(cornerRadius: 10))
            Text(item.seriesName ?? item.name).font(.footnote.weight(.medium)).lineLimit(1)
            Text(item.seriesName == nil ? (item.subtitle ?? "") : [item.subtitle, item.name].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 220, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Recently Added: 2:3 poster, unplayed-count badge for shows, name and year.
struct PosterCard: View {
    let server: JellyfinServer
    let item: JellyfinItem
    var width: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color(.tertiarySystemFill)
                .frame(width: width, height: width * 1.5)
                .overlay {
                    RemoteImage(url: JellyfinAPI.imageURL(server: server.url, itemID: item.id,
                                                          tag: item.primaryImageTag)) {
                        Text(String(item.name.prefix(1)).uppercased())
                            .font(.system(size: 34, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let unplayed = item.userData?.unplayedItemCount, unplayed > 0, !item.isPlayable {
                        Text(unplayed > 99 ? "99+" : String(unplayed))
                            .font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.blue, in: .capsule).padding(6)
                    }
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
                .clipShape(.rect(cornerRadius: 10))
            Text(item.name).font(.footnote.weight(.medium)).lineLimit(2)
            if let subtitle = item.subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// AsyncImage with a placeholder slot and a fill that clips. ponytail: no
/// disk cache beyond URLCache's default; posters are small and the server
/// is on the LAN.
struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    init(url: URL?, contentMode: ContentMode = .fill,
         @ViewBuilder placeholder: @escaping () -> Placeholder = { EmptyView() }) {
        self.url = url; self.contentMode = contentMode; self.placeholder = placeholder
    }

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
    }
}
