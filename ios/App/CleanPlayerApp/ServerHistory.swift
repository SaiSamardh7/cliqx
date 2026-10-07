import CleanPlayer
import Foundation

/// What was watched from a server on THIS device.
///
/// The server holds the real position, and while it can be reached that is the
/// only copy worth reading — it moves while you are watching on a television,
/// and it knows when something is finished. But a home server is off, or on a
/// network you have left, for most of the day, and a home screen that empties
/// itself the moment that happens does not remember anything at all.
///
/// So this is a fallback, not a second source of truth: it stands in only for a
/// server that could not be reached. A server that answers, even with an empty
/// list, overrules everything remembered here — an item it no longer lists has
/// been finished or removed, and keeping it would be the app arguing with the
/// server about the user's own history.
@MainActor
final class ServerHistory: ObservableObject {
    /// One item, and the server it came from. The whole `JellyfinItem` is kept
    /// rather than a reduction of it: it is already `Codable`, and the card the
    /// home screen draws wants its art tags, its series and episode numbers and
    /// its progress — which is every field anyway.
    struct Entry: Codable, Identifiable {
        var serverID: String
        var item: JellyfinItem
        var watchedAt: Date

        var id: String { "\(serverID)|\(item.id)" }
    }

    static let shared = ServerHistory()

    @Published private(set) var items: [Entry] = []

    /// Deliberately small. This is a shelf, not an archive, and the server has
    /// the real history for anyone who wants to scroll it.
    private static let limit = 12

    private let key = "server-history.v1"
    private let store: UserDefaults
    /// The saved list would not decode. Writing over it would drop the one
    /// copy of this that exists off the server.
    private var unreadable = false

    init(store: UserDefaults = .standard) {
        self.store = store
        if let saved = StoreRecovery.decode([Entry].self,
                                            from: store.data(forKey: key),
                                            named: key,
                                            didQuarantine: { [weak self] kept in
                                                self?.unreadable = true
                                                StoreHealth.shared.record(store: "server-history",
                                                                          keptAt: kept)
                                            }) {
            items = saved
        }
    }

    /// Record a play, or move the position of one already recorded.
    ///
    /// `positionMs` is nil when the item has only just been opened — the
    /// position it carries from the server is still the right one, and
    /// overwriting it with zero would lose the resume point the user came for.
    func remember(_ item: JellyfinItem, on server: JellyfinServer, positionMs: Int? = nil) {
        var stored = item
        var data = stored.userData ?? JellyfinItem.UserData()
        if let positionMs {
            data.playbackPositionTicks = JellyfinAPI.ticks(fromMilliseconds: positionMs)
            if let runtime = stored.runTimeTicks, runtime > 0 {
                data.playedPercentage = Double(positionMs)
                    / Double(JellyfinAPI.milliseconds(fromTicks: runtime)) * 100
            }
        }
        data.lastPlayedDate = Date()
        stored.userData = data

        let entry = Entry(serverID: server.id, item: stored, watchedAt: Date())
        items.removeAll { $0.id == entry.id }
        // One card per show, like the browser's library: watching three
        // episodes in a row should leave one row to carry on from, not three.
        if let series = stored.seriesId {
            items.removeAll { $0.serverID == server.id && $0.item.seriesId == series }
        }
        items.insert(entry, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        persist()
    }

    /// Everything remembered for servers that are NOT in `answered`, newest
    /// first. A server that answered has already said what it has.
    func standingIn(forServersOtherThan answered: Set<String>) -> [Entry] {
        items.filter { !answered.contains($0.serverID) }
            .sorted { $0.watchedAt > $1.watchedAt }
    }

    func forget(_ id: Entry.ID) {
        items.removeAll { $0.id == id }
        persist()
    }

    func forgetAll() {
        items.removeAll()
        persist()
    }

    /// Drops everything remembered for a server, for when it is signed out of.
    func forgetServer(_ serverID: String) {
        items.removeAll { $0.serverID == serverID }
        persist()
    }

    private func persist() {
        guard !unreadable, let data = try? JSONEncoder().encode(items) else { return }
        store.set(data, forKey: key)
    }
}
