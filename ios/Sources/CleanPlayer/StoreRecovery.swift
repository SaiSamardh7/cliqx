import Foundation
import os

/// Decoding a saved store, without destroying it when it cannot be read.
///
/// Every store in the app decoded with `try?` and fell back to empty. The next
/// write then persisted that empty value over the original bytes, so a single
/// unreadable payload — a partial write, a schema the user downgraded past, a
/// corrupted preference plist — silently became "your library is gone", with
/// no message and nothing left to recover from.
///
/// Reading through here keeps the original: the bytes are copied aside before
/// anything else happens, and the failure is recorded rather than swallowed.
public enum StoreRecovery {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.saisamardh.cleanplayer",
        category: "Store")

    /// Where a quarantined payload is kept, so a support request can ask for it
    /// and a future version can migrate it.
    public static var quarantineDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("corrupt", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Decode, or quarantine the bytes and report the failure.
    ///
    /// Returns nil for "there was nothing saved" as well as for "it could not
    /// be read"; `didQuarantine` distinguishes them, because only the second
    /// one means the caller must not overwrite what is there.
    @discardableResult
    public static func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data?,
        named name: String,
        decoder: JSONDecoder = JSONDecoder(),
        didQuarantine: (URL?) -> Void = { _ in }
    ) -> T? {
        guard let data, !data.isEmpty else { return nil }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let destination = quarantineDirectory
                .appendingPathComponent("\(name)-\(stamp).bin")
            let saved = (try? data.write(to: destination, options: .atomic)) != nil
            log.error("""
                Store \(name, privacy: .public) could not be decoded: \
                \(error.localizedDescription, privacy: .public). \
                \(saved ? "Kept a copy." : "Could not keep a copy.", privacy: .public)
                """)
            didQuarantine(saved ? destination : nil)
            return nil
        }
    }
}

/// What the app knows about stores that would not load. Surfaced in Settings
/// rather than only in the log: a library that silently emptied itself is the
/// one failure a user cannot diagnose or report.
@MainActor
public final class StoreHealth: ObservableObject {
    public struct Problem: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public let store: String
        public let keptAt: URL?
        public let at: Date

        public init(store: String, keptAt: URL?, at: Date = Date()) {
            self.store = store
            self.keptAt = keptAt
            self.at = at
        }
    }

    public static let shared = StoreHealth()

    @Published public private(set) var problems: [Problem] = []

    public init() {}

    public func record(store: String, keptAt: URL?) {
        problems.append(Problem(store: store, keptAt: keptAt))
    }

    public func clear() { problems.removeAll() }
}
