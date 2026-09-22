import CleanPlayer
import Foundation
import Security
import UIKit
import os

// MARK: - Models

/// A server the user added. The access token lives in the keychain; everything
/// else is plain and goes in UserDefaults.
///
/// A row is server + user + address, not the server's own Id alone. Keyed on
/// that alone, adding the same Jellyfin by a second address (the LAN IP and
/// the domain), or a second account on it, silently replaced the first row —
/// "adding any other server makes the previous one disappear".
///
/// The token is keyed by server + user, and shared by every address of the
/// same account: Jellyfin revokes a user's earlier token for this DeviceId
/// when they sign in again, so two rows holding separate tokens would break
/// each other at the second sign-in.
struct JellyfinServer: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var url: URL
    var userID: String
    var username: String
    /// The server's own Id. Nil on rows saved before rows were keyed by
    /// address; there `id` is the server Id, and the token key is `id`.
    var serverID: String?

    var tokenKey: String { serverID.map { "\($0)|\(userID)" } ?? id }

    static func identity(serverID: String, userID: String, url: URL) -> String {
        let host = url.host()?.lowercased() ?? ""
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(serverID)|\(userID)|\(host)\(port)"
    }
}

/// One library, folder, movie, season or episode. The same shape for all of
/// them: Jellyfin's item tree is uniform, so the browser can be one recursive
/// screen rather than one screen per kind.
struct JellyfinItem: Codable, Identifiable, Hashable {
    struct UserData: Codable, Hashable {
        var playbackPositionTicks: Int64?
        var played: Bool?
        var playedPercentage: Double?
        var unplayedItemCount: Int?
        var isFavorite: Bool?
        enum CodingKeys: String, CodingKey {
            case playbackPositionTicks = "PlaybackPositionTicks"
            case played = "Played"
            case playedPercentage = "PlayedPercentage"
            case unplayedItemCount = "UnplayedItemCount"
            case isFavorite = "IsFavorite"
        }
    }

    var id: String
    var name: String
    var type: String
    var isFolder: Bool?
    var collectionType: String?
    var productionYear: Int?
    var indexNumber: Int?
    var parentIndexNumber: Int?
    var seriesName: String?
    var runTimeTicks: Int64?
    var imageTags: [String: String]?
    var backdropImageTags: [String]?
    var parentBackdropItemId: String?
    var parentBackdropImageTags: [String]?
    var seriesId: String?
    var seasonId: String?
    var seriesPrimaryImageTag: String?
    var userData: UserData?
    var childCount: Int?
    var communityRating: Double?
    var officialRating: String?
    var genres: [String]?
    var overview: String?
    var status: String?
    var endDate: Date?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", type = "Type", isFolder = "IsFolder"
        case collectionType = "CollectionType", productionYear = "ProductionYear"
        case indexNumber = "IndexNumber", parentIndexNumber = "ParentIndexNumber"
        case seriesName = "SeriesName", runTimeTicks = "RunTimeTicks"
        case imageTags = "ImageTags", backdropImageTags = "BackdropImageTags"
        case parentBackdropItemId = "ParentBackdropItemId", parentBackdropImageTags = "ParentBackdropImageTags"
        case seriesId = "SeriesId", seasonId = "SeasonId", seriesPrimaryImageTag = "SeriesPrimaryImageTag"
        case userData = "UserData", childCount = "ChildCount"
        case communityRating = "CommunityRating", officialRating = "OfficialRating"
        case genres = "Genres", overview = "Overview", status = "Status", endDate = "EndDate"
    }

    /// Something the player can open, as opposed to something to drill into.
    var isPlayable: Bool { ["Movie", "Episode", "Video", "MusicVideo"].contains(type) }
    var primaryImageTag: String? { imageTags?["Primary"] }
    var logoImageTag: String? { imageTags?["Logo"] }
    var resumeMs: Int { JellyfinAPI.milliseconds(fromTicks: userData?.playbackPositionTicks ?? 0) }

    /// The wide picture: the item's own backdrop, else its series'. Returns
    /// which item to ask and with what tag, since the two differ.
    var backdrop: (itemID: String, tag: String)? {
        if let tag = backdropImageTags?.first { return (id, tag) }
        if let parent = parentBackdropItemId, let tag = parentBackdropImageTags?.first { return (parent, tag) }
        return nil
    }

    /// "2008 – 2013" for a finished show, "2025 – Present" for a running one,
    /// the year for a film.
    var yearRange: String? {
        guard let start = productionYear else { return nil }
        guard type == "Series" else { return String(start) }
        if status == "Continuing" { return "\(start) – Present" }
        if let end = endDate.map({ Calendar.current.component(.year, from: $0) }), end != start {
            return "\(start) – \(end)"
        }
        return String(start)
    }

    /// "S2 · E5" for an episode, the year for a film, a count for a folder.
    var subtitle: String? {
        if type == "Episode", let e = indexNumber {
            return parentIndexNumber.map { "S\($0) · E\(e)" } ?? "Episode \(e)"
        }
        if isPlayable || type == "Series" { return yearRange }
        if let childCount { return "\(childCount) items" }
        return nil
    }

    /// 0…1 partway through, nil when there is nothing to show.
    var progress: Double? {
        guard let pct = userData?.playedPercentage, pct > 1, pct < 100 else { return nil }
        return pct / 100
    }
}

// MARK: - Client

/// The handful of calls the shelf needs. `URLSession.shared`, JSON, no SDK.
///
/// Paths are the user-scoped forms that take `userId` as a query parameter
/// (`UserViews`, `Items/Latest`, `UserItems/Resume`, …). The older
/// `Users/{id}/…` routes were removed from the server; a 404 on `Latest` was
/// swallowed by the shelf and simply left every Recently Added row out.
/// The query forms exist from 10.9 on, so older servers still answer.
///
/// ponytail: five endpoints, no retry, no cache. Add `ETag` handling when a
/// library is big enough for the grid to feel slow.
struct JellyfinClient {
    enum Failure: LocalizedError {
        case notAJellyfinServer
        case badCredentials
        case http(Int)
        /// A path or query that will not form a URL. Was a force-unwrap, so a
        /// server address with a stray character crashed inside the network
        /// layer instead of showing a message.
        case badURL

        var errorDescription: String? {
            switch self {
            case .notAJellyfinServer: "That address didn't answer like a Jellyfin server."
            case .badCredentials: "Wrong username or password."
            case .http(let code): "The server answered \(code)."
            case .badURL: "That server address can't be used."
            }
        }
    }

    let server: URL
    var token: String?
    static let deviceID: String = {
        // Shared with MediaLibrary so the server lists one device, not two.
        let key = "device.id.v1"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()

    private struct PublicInfo: Decodable {
        var Id: String
        var ServerName: String
        /// Required here although the schema marks it nullable: together with
        /// Id it is what separates a Jellyfin public-info response from any
        /// other JSON object with an id, and this is the reply that decides
        /// whether the password is sent.
        var Version: String
        var ProductName: String?
    }
    private struct AuthResult: Decodable {
        struct User: Decodable { var Id: String; var Name: String }
        var User: User
        var AccessToken: String
    }
    private struct Page: Decodable { var Items: [JellyfinItem] }

    /// Sign in: confirm the address is Jellyfin, then exchange the password
    /// for a token. The password is sent once, in a JSON body over the
    /// connection the user chose, and never stored.
    static func signIn(server: URL, username: String, password: String) async throws
        -> (JellyfinServer, token: String) {
        let anonymous = JellyfinClient(server: server, token: nil)
        let info: PublicInfo
        do {
            info = try await anonymous.get("System/Info/Public")
        } catch {
            throw Failure.notAJellyfinServer
        }
        // `?? true` meant a missing ProductName PASSED, so anything returning
        // JSON with an Id was "a Jellyfin server" — and then got the password.
        // The field is genuinely nullable, so absence cannot be fatal; what it
        // must not do is name something else. Id and Version carry the rest of
        // the proof, and failing to decode them is itself a rejection.
        if let product = info.ProductName, !product.contains("Jellyfin") {
            throw Failure.notAJellyfinServer
        }

        let body = ["Username": username, "Pw": password]
        let auth: AuthResult
        do {
            auth = try await anonymous.post("Users/AuthenticateByName", body: body)
        } catch Failure.http(401), Failure.http(403) {
            throw Failure.badCredentials
        }
        let record = JellyfinServer(id: JellyfinServer.identity(serverID: info.Id, userID: auth.User.Id,
                                                                url: server),
                                    name: info.ServerName, url: server,
                                    userID: auth.User.Id, username: auth.User.Name,
                                    serverID: info.Id)
        return (record, auth.AccessToken)
    }

    /// The user's libraries. Empty means the account can see none — the
    /// answer to "why are there no movies", straight from the server.
    func views(userID: String) async throws -> [JellyfinItem] {
        let page: Page = try await get("UserViews", query: ["userId": userID])
        return page.Items
    }

    /// Children of a library or folder, ordered the way the server would
    /// show them; episodes by number, everything else by name.
    func items(userID: String, parentID: String) async throws -> [JellyfinItem] {
        let page: Page = try await get("Items", query: [
            "userId": userID,
            "ParentId": parentID,
            "SortBy": "IsFolder,SortName",
            "SortOrder": "Ascending",
            "Fields": "ChildCount,ProductionYear",
        ])
        return page.Items
    }

    /// Where the film was left, so the next screen can offer Resume without
    /// another round trip. Keeps the server the source of truth for position.
    func item(userID: String, id: String) async throws -> JellyfinItem {
        try await get("Items/\(id)", query: ["userId": userID])
    }

    // MARK: The home rows, same endpoints the web client uses

    static let homeFields = "PrimaryImageAspectRatio,Overview,Genres,ProductionYear,Status,EndDate,ChildCount"

    /// Continue Watching: anything left partway through.
    func resume(userID: String) async throws -> [JellyfinItem] {
        let page: Page = try await get("UserItems/Resume", query: [
            "userId": userID, "Limit": "12", "MediaTypes": "Video", "Fields": Self.homeFields,
            "EnableImageTypes": "Primary,Backdrop,Thumb",
        ])
        return page.Items
    }

    /// Next Up: the episode after the last one watched, per show.
    func nextUp(userID: String) async throws -> [JellyfinItem] {
        let page: Page = try await get("Shows/NextUp", query: [
            "UserId": userID, "Limit": "12", "Fields": Self.homeFields,
            "EnableImageTypes": "Primary,Backdrop,Thumb",
        ])
        return page.Items
    }

    /// Recently Added in one library. This endpoint returns a bare array.
    func latest(userID: String, parentID: String) async throws -> [JellyfinItem] {
        try await get("Items/Latest", query: [
            "userId": userID, "ParentId": parentID, "Limit": "12", "Fields": Self.homeFields,
            "EnableImageTypes": "Primary,Backdrop,Logo",
        ])
    }

    /// The hero. First: something to pick back up. Else: an unwatched film,
    /// chosen at random so the shelf changes between visits.
    func recommended(userID: String) async throws -> JellyfinItem? {
        let page: Page = try await get("Items", query: [
            "userId": userID, "IncludeItemTypes": "Movie", "Recursive": "true", "Filters": "IsUnplayed",
            "SortBy": "Random", "Limit": "1", "Fields": Self.homeFields,
            "EnableImageTypes": "Primary,Backdrop,Logo", "ImageTypeLimit": "1",
        ])
        return page.Items.first
    }

    func setFavorite(userID: String, itemID: String, _ on: Bool) {
        guard var req = try? request("UserFavoriteItems/\(itemID)", query: ["userId": userID])
        else { return }
        req.httpMethod = on ? "POST" : "DELETE"
        URLSession.shared.dataTask(with: req).resume()
    }

    // MARK: Progress, so the TV and the browser agree with the phone

    func reportStart(itemID: String, positionMs: Int) {
        fire("Sessions/Playing", ["ItemId": itemID,
                                  "PositionTicks": JellyfinAPI.ticks(fromMilliseconds: positionMs),
                                  "PlayMethod": "DirectPlay"])
    }

    func reportProgress(itemID: String, positionMs: Int, paused: Bool) {
        fire("Sessions/Playing/Progress", ["ItemId": itemID,
                                           "PositionTicks": JellyfinAPI.ticks(fromMilliseconds: positionMs),
                                           "IsPaused": paused])
    }

    func reportStopped(itemID: String, positionMs: Int) {
        fire("Sessions/Playing/Stopped", ["ItemId": itemID,
                                          "PositionTicks": JellyfinAPI.ticks(fromMilliseconds: positionMs)])
    }

    // MARK: Plumbing

    private func request(_ path: String, query: [String: String] = [:]) throws -> URLRequest {
        guard var parts = URLComponents(url: server.appendingPathComponent(path),
                                        resolvingAgainstBaseURL: false)
        else { throw Failure.badURL }
        if !query.isEmpty { parts.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = parts.url else { throw Failure.badURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(JellyfinAPI.authorization(deviceID: Self.deviceID,
                                                   deviceName: UIDevice.current.name,
                                                   token: token),
                         forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { container in
            let text = try container.singleValueContainer().decode(String.self)
            if let date = iso.date(from: text) ?? plain.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: container.codingPath,
                                                    debugDescription: "not ISO 8601: \(text)"))
        }
        return decoder
    }()

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: try request(path, query: query))
        try Self.check(response)
        return try Self.decoder.decode(T.self, from: data)
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        var req = try request(path)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.check(response)
        return try Self.decoder.decode(T.self, from: data)
    }

    /// Progress reports: best effort, no result, never blocks the player.
    private func fire(_ path: String, _ body: [String: Any]) {
        guard var req = try? request(path) else { return }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req).resume()
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else { throw Failure.http(http.statusCode) }
    }
}

// MARK: - Store

/// The servers the user added, and their tokens. Records in UserDefaults,
/// tokens in the keychain: a token is a password-equivalent and does not
/// belong in a plist that Finder file sharing can read.
@MainActor
final class JellyfinServers: ObservableObject {
    @Published private(set) var servers: [JellyfinServer] = []
    private let key = "servers.v1"
    private let tokens: TokenStore

    /// The saved list would not decode. Writing over it would drop every
    /// server the user added, silently.
    private var unreadable = false

    init(tokens: TokenStore = Keychain()) {
        self.tokens = tokens
        if let saved = StoreRecovery.decode([JellyfinServer].self,
                                            from: UserDefaults.standard.data(forKey: key),
                                            named: key,
                                            didQuarantine: { kept in
                                                self.unreadable = true
                                                StoreHealth.shared.record(store: key, keptAt: kept)
                                            }) {
            servers = saved
        }
    }

    func add(_ server: JellyfinServer, token: String) {
        // An old row for this same account was keyed by server Id alone and
        // holds a token the server has just revoked. Move it onto the shared
        // key so it keeps working, rather than dying at the next request.
        if let serverID = server.serverID {
            for index in servers.indices
            where servers[index].serverID == nil && servers[index].id == serverID
                && servers[index].userID == server.userID {
                tokens.delete(servers[index].id)
                servers[index].serverID = serverID
            }
        }
        tokens.set(token, for: server.tokenKey)
        servers.removeAll { $0.id == server.id }
        servers.append(server)
        persist()
    }

    func remove(_ server: JellyfinServer) {
        servers.removeAll { $0.id == server.id }
        // The token outlives this row while another address of the same
        // account still uses it.
        if !servers.contains(where: { $0.tokenKey == server.tokenKey }) {
            tokens.delete(server.tokenKey)
        }
        persist()
    }

    func client(for server: JellyfinServer) -> JellyfinClient {
        JellyfinClient(server: server.url, token: tokens.get(server.tokenKey))
    }

    private func persist() {
        guard !unreadable, let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// Where access tokens live.
///
/// A protocol rather than a free enum so the real keychain path is the one the
/// app always takes, and tests inject a fake instead. It used to be swapped out
/// by `#if targetEnvironment(simulator)`, which meant the code that ships had
/// never run in CI — and that a Release simulator build wrote tokens to a plist.
protocol TokenStore: Sendable {
    func set(_ value: String, for account: String)
    func get(_ account: String) -> String?
    func delete(_ account: String)
}

/// Generic-password items under one service.
///
/// An unsigned process has no keychain and every SecItem call returns -34018.
/// That is the simulator's default (`CODE_SIGNING_ALLOWED` is off for that SDK
/// so CI needs no identity). Rather than compile a different store there, the
/// failure is detected at runtime and an in-memory store takes over for the
/// session: the device path is then the only one in the binary, and a token
/// never lands on disk in the clear.
struct Keychain: TokenStore {
    private static let service = "com.saisamardh.cleanplayer.jellyfin"
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cliqx",
                                    category: "Keychain")

    /// Populated only when the keychain is unavailable to this process.
    private static let fallback = InMemoryTokenStore()
    private static let keychainUnavailable = OSAllocatedUnfairLock(initialState: false)

    private static var usingFallback: Bool {
        keychainUnavailable.withLock { $0 }
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Update in place, add when there is nothing to update. Delete-then-add
    /// loses the token outright if the process dies between the two.
    func set(_ value: String, for account: String) {
        if Self.usingFallback { return Self.fallback.set(value, for: account) }
        let data = Data(value.utf8)
        let updated = SecItemUpdate(
            Self.query(account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }

        var item = Self.query(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added != errSecSuccess else { return }
        if Self.isUnavailable(added) {
            Self.useFallback(after: added)
            Self.fallback.set(value, for: account)
        } else {
            Self.log.error("SecItemAdd failed: \(added)")
        }
    }

    func get(_ account: String) -> String? {
        if Self.usingFallback { return Self.fallback.get(account) }
        var item = Self.query(account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &out)
        if status == errSecSuccess, let data = out as? Data {
            return String(data: data, encoding: .utf8)
        }
        if Self.isUnavailable(status) {
            Self.useFallback(after: status)
            return Self.fallback.get(account)
        }
        if status != errSecItemNotFound { Self.log.error("SecItemCopyMatching failed: \(status)") }
        return nil
    }

    func delete(_ account: String) {
        if Self.usingFallback { return Self.fallback.delete(account) }
        let status = SecItemDelete(Self.query(account) as CFDictionary)
        if Self.isUnavailable(status) {
            Self.useFallback(after: status)
            Self.fallback.delete(account)
        }
    }

    /// -34018 errSecMissingEntitlement, -25291 errSecNotAvailable: the
    /// process has no keychain at all, as opposed to this item being absent.
    private static func isUnavailable(_ status: OSStatus) -> Bool {
        status == -34018 || status == errSecNotAvailable
    }

    private static func useFallback(after status: OSStatus) {
        let firstTime = keychainUnavailable.withLock { flag -> Bool in
            defer { flag = true }
            return !flag
        }
        guard firstTime else { return }
        log.error("""
            Keychain unavailable (\(status)); tokens are kept in memory for             this session only.
            """)
    }
}

/// Tokens for a process with no keychain, and for tests. Never touches disk.
final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func set(_ value: String, for account: String) {
        lock.withLock { values[account] = value }
    }

    func get(_ account: String) -> String? {
        lock.withLock { values[account] }
    }

    func delete(_ account: String) {
        lock.withLock { _ = values.removeValue(forKey: account) }
    }
}
