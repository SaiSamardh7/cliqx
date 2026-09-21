import CleanPlayer
import Foundation
import Security
import UIKit
import os

// MARK: - Models

/// A server the user added. The access token lives in the keychain, keyed by
/// the server's id; everything else is plain and goes in UserDefaults.
struct JellyfinServer: Codable, Identifiable, Hashable {
    var id: String            // the server's own Id, from /System/Info/Public
    var name: String
    var url: URL
    var userID: String
    var username: String
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
/// ponytail: five endpoints, no retry, no cache. Add `ETag` handling when a
/// library is big enough for the grid to feel slow.
struct JellyfinClient {
    enum Failure: LocalizedError {
        case notAJellyfinServer
        case badCredentials
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .notAJellyfinServer: "That address didn't answer like a Jellyfin server."
            case .badCredentials: "Wrong username or password."
            case .http(let code): "The server answered \(code)."
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
        guard info.ProductName?.contains("Jellyfin") ?? true else { throw Failure.notAJellyfinServer }

        let body = ["Username": username, "Pw": password]
        let auth: AuthResult
        do {
            auth = try await anonymous.post("Users/AuthenticateByName", body: body)
        } catch Failure.http(401), Failure.http(403) {
            throw Failure.badCredentials
        }
        let record = JellyfinServer(id: info.Id, name: info.ServerName, url: server,
                                    userID: auth.User.Id, username: auth.User.Name)
        return (record, auth.AccessToken)
    }

    /// The user's libraries. Empty means the account can see none — the
    /// answer to "why are there no movies", straight from the server.
    func views(userID: String) async throws -> [JellyfinItem] {
        let page: Page = try await get("Users/\(userID)/Views")
        return page.Items
    }

    /// Children of a library or folder, ordered the way the server would
    /// show them; episodes by number, everything else by name.
    func items(userID: String, parentID: String) async throws -> [JellyfinItem] {
        let page: Page = try await get("Users/\(userID)/Items", query: [
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
        try await get("Users/\(userID)/Items/\(id)")
    }

    // MARK: The home rows, same endpoints the web client uses

    static let homeFields = "PrimaryImageAspectRatio,Overview,Genres,ProductionYear,Status,EndDate,ChildCount"

    /// Continue Watching: anything left partway through.
    func resume(userID: String) async throws -> [JellyfinItem] {
        let page: Page = try await get("Users/\(userID)/Items/Resume", query: [
            "Limit": "12", "MediaTypes": "Video", "Fields": Self.homeFields,
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
        try await get("Users/\(userID)/Items/Latest", query: [
            "ParentId": parentID, "Limit": "12", "Fields": Self.homeFields,
            "EnableImageTypes": "Primary,Backdrop,Logo",
        ])
    }

    /// The hero. First: something to pick back up. Else: an unwatched film,
    /// chosen at random so the shelf changes between visits.
    func recommended(userID: String) async throws -> JellyfinItem? {
        let page: Page = try await get("Users/\(userID)/Items", query: [
            "IncludeItemTypes": "Movie", "Recursive": "true", "Filters": "IsUnplayed",
            "SortBy": "Random", "Limit": "1", "Fields": Self.homeFields,
            "EnableImageTypes": "Primary,Backdrop,Logo", "ImageTypeLimit": "1",
        ])
        return page.Items.first
    }

    func setFavorite(userID: String, itemID: String, _ on: Bool) {
        var req = request("Users/\(userID)/FavoriteItems/\(itemID)")
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

    private func request(_ path: String, query: [String: String] = [:]) -> URLRequest {
        var parts = URLComponents(url: server.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: parts.url!)
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
        let (data, response) = try await URLSession.shared.data(for: request(path, query: query))
        try Self.check(response)
        return try Self.decoder.decode(T.self, from: data)
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        var req = request(path)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.check(response)
        return try Self.decoder.decode(T.self, from: data)
    }

    /// Progress reports: best effort, no result, never blocks the player.
    private func fire(_ path: String, _ body: [String: Any]) {
        var req = request(path)
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

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([JellyfinServer].self, from: data) {
            servers = saved
        }
    }

    func add(_ server: JellyfinServer, token: String) {
        Keychain.set(token, for: server.id)
        servers.removeAll { $0.id == server.id }
        servers.append(server)
        persist()
    }

    func remove(_ server: JellyfinServer) {
        Keychain.delete(server.id)
        servers.removeAll { $0.id == server.id }
        persist()
    }

    func client(for server: JellyfinServer) -> JellyfinClient {
        JellyfinClient(server: server.url, token: Keychain.get(server.id))
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// Generic-password items under one service. ponytail: the three calls the
/// store needs, nothing else.
///
/// Simulator builds are deliberately unsigned (`CODE_SIGNING_ALLOWED` is off
/// for that SDK so CI needs no identity), and an unsigned process has no
/// keychain: every SecItem call returns -34018. There the token goes to
/// UserDefaults instead, plainly and only there. A device build is signed
/// and uses the real keychain.
enum Keychain {
    private static let service = "com.saisamardh.cleanplayer.jellyfin"
#if targetEnvironment(simulator)
    static func set(_ value: String, for account: String) {
        UserDefaults.standard.set(value, forKey: service + "." + account)
    }
    static func get(_ account: String) -> String? {
        UserDefaults.standard.string(forKey: service + "." + account)
    }
    static func delete(_ account: String) {
        UserDefaults.standard.removeObject(forKey: service + "." + account)
    }
#else

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cliqx", category: "Keychain")

    static func set(_ value: String, for account: String) {
        delete(account)
        var item = query(account)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { log.error("SecItemAdd failed: \(status)") }
    }

    static func get(_ account: String) -> String? {
        var item = query(account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else {
            log.error("SecItemCopyMatching failed: \(status)")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
#endif
}
