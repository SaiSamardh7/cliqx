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
        .serverPlayer(playback, server: server, servers: servers, rules: rules,
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
        GeometryReader { geo in
            // Fill the row: as many 2:3 posters as fit at ≥110pt.
            let count = max(2, Int((geo.size.width - 32 + 14) / (110 + 14)))
            let width = (geo.size.width - 32 - CGFloat(count - 1) * 14) / CGFloat(count)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: 14), count: count),
                          spacing: 18) {
                    ForEach(items) { item in
                        if item.isPlayable {
                            Button { playback.play(item) } label: {
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
