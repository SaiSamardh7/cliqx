import CryptoKit
import Foundation

/// A file's identity, derived from its content rather than its path. Per the
/// plan: "Never identify a file only by its path; SMB mount points and device
/// paths change." Size plus a hash of the first chunk is stable across moves
/// and cheap — a full-file hash would stall on multi-GB video.
enum MediaFingerprint {
    static func compute(url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let head = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        var hasher = SHA256()
        withUnsafeBytes(of: Int64(size).littleEndian) { hasher.update(bufferPointer: $0) }
        hasher.update(data: head)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// One saved position. Fields follow the plan's LOCAL PLAYBACK PROGRESS record
/// so the shape is stable before sync exists — `deviceID`/`revision` are unused
/// locally but keep the contract forward-compatible for Milestone 5.
struct MediaProgress: Codable, Identifiable, Hashable {
    var fingerprint: String
    var sourceKind: String          // "file" | "photos"
    var displayName: String
    var positionMs: Int
    var durationMs: Int
    var completed: Bool
    var updatedAt: Date
    /// Security-scoped bookmark, file sources only. Photos hands out a temp
    /// copy with no durable identity, so those save progress but cannot reopen.
    var bookmark: Data?
    var deviceID: String
    var revision: Int

    var id: String { fingerprint }

    /// 0…1 for the resume bar; nil when there is nothing worth resuming.
    var progress: Double? {
        guard durationMs > 0, positionMs > 3000, !completed else { return nil }
        return min(Double(positionMs) / Double(durationMs), 1)
    }

    var initials: String { String(displayName.prefix(1)).uppercased() }
}

/// Local playback progress for files. Continue Watching reads from here; the
/// player writes to it. A JSON file in Application Support, not UserDefaults —
/// this list grows and does not belong in the preferences plist.
@MainActor
final class MediaLibrary: ObservableObject {
    @Published private(set) var items: [MediaProgress] = []

    /// Reopenable, unfinished, newest first. Only file sources have a bookmark
    /// to reopen from, so only they appear as cards.
    var continueWatching: [MediaProgress] {
        items.filter { $0.bookmark != nil && !$0.completed && $0.progress != nil }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private let store: URL
    private let deviceID: String

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        store = base.appendingPathComponent("media-progress.json")

        let key = "device.id.v1"
        if let existing = UserDefaults.standard.string(forKey: key) {
            deviceID = existing
        } else {
            deviceID = UUID().uuidString
            UserDefaults.standard.set(deviceID, forKey: key)
        }

        if let data = try? Data(contentsOf: store),
           let saved = try? JSONDecoder().decode([MediaProgress].self, from: data) {
            items = saved
        }
    }

    func progress(for fingerprint: String) -> MediaProgress? {
        items.first { $0.fingerprint == fingerprint }
    }

    /// Upsert a position. 95% watched counts as completed (plan rule), which
    /// drops it from Continue Watching without deleting the record.
    func save(fingerprint: String, sourceKind: String, displayName: String,
              positionMs: Int, durationMs: Int, bookmark: Data?) {
        guard durationMs > 0 else { return }
        let completed = Double(positionMs) / Double(durationMs) >= 0.95
        if let index = items.firstIndex(where: { $0.fingerprint == fingerprint }) {
            items[index].positionMs = positionMs
            items[index].durationMs = durationMs
            items[index].completed = completed
            items[index].displayName = displayName
            items[index].updatedAt = Date()
            items[index].revision += 1
            if let bookmark { items[index].bookmark = bookmark }
        } else {
            items.insert(MediaProgress(
                fingerprint: fingerprint, sourceKind: sourceKind, displayName: displayName,
                positionMs: positionMs, durationMs: durationMs, completed: completed,
                updatedAt: Date(), bookmark: bookmark, deviceID: deviceID, revision: 1), at: 0)
        }
        persist()
    }

    func remove(_ fingerprint: String) {
        items.removeAll { $0.fingerprint == fingerprint }
        persist()
    }

    func clear() {
        items.removeAll()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: store, options: .atomic)
    }

    /// Resolve a saved bookmark back to a URL, starting scoped access. Returns
    /// nil (and the caller re-prompts) when the bookmark is stale — the plan's
    /// "Detect stale bookmarks and ask the user to grant access again."
    static func resolve(bookmark: Data) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                 options: [],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale),
              !stale,
              url.startAccessingSecurityScopedResource()
        else { return nil }
        return url
    }
}
