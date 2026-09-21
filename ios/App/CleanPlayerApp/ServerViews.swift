import CleanPlayer
import SwiftUI

// MARK: - Add a server

/// Address, username, password, Connect. The password goes to the server
/// once and is not kept; the token that comes back is.
struct AddServerSheet: View {
    @ObservedObject var servers: JellyfinServers
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var connecting = false
    @State private var error: String?
    @FocusState private var focused: Field?
    private enum Field { case address, username, password }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("192.168.1.170:8096", text: $address)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused, equals: .address)
                        .onSubmit { focused = .username }
                } header: {
                    Text("Server address")
                } footer: {
                    Text("The address you'd type in a browser. A home server on your "
                         + "Wi-Fi is usually an IP address and port.")
                }
                Section("Sign in") {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused, equals: .username)
                        .onSubmit { focused = .password }
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focused, equals: .password)
                        .onSubmit { connect() }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if connecting {
                        ProgressView()
                    } else {
                        Button("Connect") { connect() }
                            .disabled(JellyfinAPI.serverURL(from: address) == nil || username.isEmpty)
                    }
                }
            }
            .onAppear { focused = .address }
        }
    }

    private func connect() {
        guard let url = JellyfinAPI.serverURL(from: address), !username.isEmpty else { return }
        connecting = true
        error = nil
        Task {
            defer { connecting = false }
            do {
                let (server, token) = try await JellyfinClient.signIn(
                    server: url, username: username, password: password)
                servers.add(server, token: token)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Browse

/// One screen for the whole tree. A library, a show, a season: all "a folder
/// with children"; a film or an episode: "a thing to play". Drilling down
/// pushes the same view with a new parent.
struct ServerBrowserView: View {
    @ObservedObject var servers: JellyfinServers
    let server: JellyfinServer
    /// nil at the top: the user's libraries.
    var parent: JellyfinItem?
    @ObservedObject var gestureSettings: PlayerGestureSettings

    @State private var items: [JellyfinItem]?
    @State private var error: String?
    @State private var playing: LocalVideo?
    @State private var nowPlaying: JellyfinItem?
    @State private var lastPositionMs = 0

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 14)]

    var body: some View {
        Group {
            if let error {
                unavailable("Couldn't reach \(server.name)", error, symbol: "wifi.exclamationmark")
            } else if let items {
                if items.isEmpty { empty } else { grid(items) }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(parent?.name ?? server.name)
        .toolbar {
            if parent == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Text("Signed in as \(server.username)")
                        Button("Remove server", role: .destructive) { servers.remove(server) }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .task(id: parent?.id) { await load() }
        .refreshable { await load() }
        .fullScreenCover(item: $playing, onDismiss: {
            if let item = nowPlaying {
                servers.client(for: server).reportStopped(itemID: item.id, positionMs: lastPositionMs)
                nowPlaying = nil
                Task { await load() }   // the grid's progress bars come from the server
            }
        }) { video in
            LocalPlayerView(video: video, onClose: { playing = nil },
                            gestureSettings: gestureSettings) { positionMs, _ in
                lastPositionMs = positionMs
                if let item = nowPlaying {
                    servers.client(for: server).reportProgress(itemID: item.id,
                                                               positionMs: positionMs, paused: false)
                }
            }
        }
    }

    private func load() async {
        let client = servers.client(for: server)
        do {
            items = if let parent {
                try await client.items(userID: server.userID, parentID: parent.id)
            } else {
                try await client.views(userID: server.userID)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The honest answer to an empty shelf. At the top level it is almost
    /// always permissions: the account exists but has no libraries ticked.
    private var empty: some View {
        if parent == nil {
            unavailable("No libraries for \(server.username)",
                        "The server is up, but this account can't see any libraries. "
                        + "Whoever runs \(server.name) needs to open Dashboard → Users → "
                        + "\(server.username) → Access and enable the libraries.",
                        symbol: "lock.rectangle.stack")
        } else {
            unavailable("Nothing here yet", "This folder has no items.", symbol: "film.stack")
        }
    }

    private func unavailable(_ title: String, _ message: String, symbol: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            Button("Try again") { Task { await load() } }
        }
    }

    private func grid(_ items: [JellyfinItem]) -> some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(items) { item in
                    if item.isPlayable {
                        Button { play(item) } label: { ItemCard(server: server, item: item) }
                            .buttonStyle(.plain)
                    } else {
                        NavigationLink {
                            ServerBrowserView(servers: servers, server: server, parent: item,
                                              gestureSettings: gestureSettings)
                        } label: { ItemCard(server: server, item: item) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
    }

    /// Direct stream into the same player local files use. The server's own
    /// saved position is the resume point, so a film paused on the TV
    /// continues here.
    private func play(_ item: JellyfinItem) {
        let client = servers.client(for: server)
        guard let token = client.token,
              let url = JellyfinAPI.streamURL(server: server.url, itemID: item.id, token: token)
        else { return }
        nowPlaying = item
        lastPositionMs = item.resumeMs
        client.reportStart(itemID: item.id, positionMs: item.resumeMs)
        playing = LocalVideo(url: url, scoped: false, sourceKind: "jellyfin",
                             displayName: item.seriesName.map { "\($0) — \(item.name)" } ?? item.name,
                             resumeMs: item.resumeMs)
    }
}

/// Poster, title, one line under. Same 2:3 slot whether the art loads or not.
private struct ItemCard: View {
    let server: JellyfinServer
    let item: JellyfinItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color(.tertiarySystemFill)
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay {
                    AsyncImage(url: JellyfinAPI.imageURL(server: server.url, itemID: item.id,
                                                         tag: item.primaryImageTag)) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Text(String(item.name.prefix(1)).uppercased())
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
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
        .accessibilityElement(children: .combine)
    }
}
