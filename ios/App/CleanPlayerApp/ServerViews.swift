import CleanPlayer
import SwiftUI

// MARK: - Add a server

/// Address, username, password, Connect. The password goes to the server
/// once and is not kept; the token that comes back is.
///
/// When the address turns out not to be a Jellyfin server, the sheet offers to
/// play it as a direct stream instead. That covers the case this app had no
/// answer for: a file served over plain HTTP from a NAS, or an HLS endpoint,
/// where standing up a whole media server to watch one URL is absurd. It is
/// offered here rather than as a fourth button on the home screen because the
/// address field is where someone has already pasted the link.
struct AddServerSheet: View {
    @ObservedObject var servers: JellyfinServers
    @Environment(\.dismiss) private var dismiss
    /// Called with a URL to play directly. The sheet does not own a player.
    var onOpenStream: (URL) -> Void = { _ in }

    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var connecting = false
    @State private var error: String?
    /// Set when the probe says "not Jellyfin" and the address could still be a
    /// stream. Holding the URL rather than a flag means the button plays the
    /// address that was actually tested, not whatever the field says by then.
    @State private var streamCandidate: URL?
    @FocusState private var focused: Field?
    private enum Field { case address, username, password }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("media-server.local:8096", text: $address)
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
                if let streamCandidate {
                    Section {
                        Button {
                            onOpenStream(streamCandidate)
                            dismiss()
                        } label: {
                            Label("Play as a video stream", systemImage: "play.rectangle")
                        }
                    } footer: {
                        Text("Plays the address directly, with no sign-in. Works for a "
                             + "video file or a live stream you can already reach — not "
                             + "for a streaming service, whose video is encrypted and "
                             + "playable only in its own app.")
                    }
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
                        // No longer gated on a username: the probe runs first,
                        // and needing one is the answer rather than the entry
                        // fee. An address that cannot be parsed still cannot
                        // be tried.
                        Button("Connect") { connect() }
                            .disabled(JellyfinAPI.serverURL(from: address) == nil)
                    }
                }
            }
            .onAppear { focused = .address }
        }
    }

    /// Probe first, then sign in.
    ///
    /// The order matters. Asking "is this Jellyfin?" before the credentials
    /// are required means someone pasting a stream URL never has to invent a
    /// username to find out this is not a server — and the password is still
    /// sent only after the same check that always gated it.
    private func connect() {
        guard let url = JellyfinAPI.serverURL(from: address) else { return }
        connecting = true
        error = nil
        streamCandidate = nil
        Task {
            defer { connecting = false }
            do {
                try await JellyfinClient.confirmJellyfin(server: url)
            } catch {
                self.error = error.localizedDescription
                // Only offer what can actually be played. The stream URL is
                // read from the raw text, not from `url`: the Jellyfin parse
                // drops the filename and query, which for a stream is the
                // whole address.
                self.streamCandidate = StreamAddress.url(from: address)
                return
            }
            guard !username.isEmpty else {
                self.error = "That's a Jellyfin server. Enter your username to sign in."
                self.focused = .username
                return
            }
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

/// One screen for the whole tree below a library. A show, a season: all "a
/// folder with children"; a film or an episode: "a thing to play". Drilling
/// down pushes the same view with a new parent.
struct ServerBrowserView: View {
    @ObservedObject var servers: JellyfinServers
    let server: JellyfinServer
    let parent: JellyfinItem
    @ObservedObject var rules: RuleListController
    @ObservedObject var gestureSettings: PlayerGestureSettings
    @ObservedObject var preferences: PlaybackPreferences

    @State private var items: [JellyfinItem]?
    @State private var error: String?
    @StateObject private var playback = ServerPlayback()

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView {
                    Label("Couldn't reach \(server.name)", systemImage: "wifi.exclamationmark")
                } description: { Text(error) } actions: {
                    Button("Try again") { Task { await load() } }
                }
            } else if let items {
                if items.isEmpty {
                    ContentUnavailableView("Nothing here yet", systemImage: "film.stack",
                                           description: Text("This folder has no items."))
                } else {
                    grid(items)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(parent.name)
        .task(id: parent.id) { await load() }
        .refreshable { await load() }
        .serverPlayer(playback, servers: servers, rules: rules,
                      gestureSettings: gestureSettings,
                      subtitleStyle: preferences.subtitles) { Task { await load() } }
    }

    private func load() async {
        do {
            items = try await servers.client(for: server).items(userID: server.userID, parentID: parent.id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func grid(_ items: [JellyfinItem]) -> some View {
        ServerItemGrid(servers: servers, server: server, items: items,
                       rules: rules, gestureSettings: gestureSettings,
                       preferences: preferences) { playback.play($0, on: server) }
    }
}

/// The poster grid, shared by browsing and by search.
///
/// Shared rather than copied so a film found by typing its name looks and
/// behaves exactly like the same film found by drilling down — including the
/// part that matters: a folder pushes, a playable item plays.
struct ServerItemGrid: View {
    @ObservedObject var servers: JellyfinServers
    let server: JellyfinServer
    let items: [JellyfinItem]
    @ObservedObject var rules: RuleListController
    @ObservedObject var gestureSettings: PlayerGestureSettings
    @ObservedObject var preferences: PlaybackPreferences
    let onPlay: (JellyfinItem) -> Void

    var body: some View {
        GeometryReader { geo in
            // Fill the row: as many 2:3 posters as fit at ≥110pt.
            let count = max(2, Int((geo.size.width - 32 + 14) / (110 + 14)))
            let width = (geo.size.width - 32 - CGFloat(count - 1) * 14) / CGFloat(count)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: 14), count: count),
                          spacing: 18) {
                    ForEach(items) { item in
                        if item.isPlayable {
                            Button { onPlay(item) } label: {
                                PosterCard(server: server, item: item, width: width)
                            }
                            .buttonStyle(.plain)
                        } else {
                            NavigationLink {
                                ServerBrowserView(servers: servers, server: server, parent: item,
                                                  rules: rules, gestureSettings: gestureSettings,
                                                  preferences: preferences)
                            } label: { PosterCard(server: server, item: item, width: width) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
            }
        }
    }
}
