import CryptoKit
import Foundation

public enum FilterUpdateError: Error, Equatable {
    case httpStatus(Int)
    case unexpectedContentType(String?)
    case declaredTooLarge(Int)
    case bodyTooLarge(Int)
    case empty
    case notAFilterList
    case checksumMismatch
}

/// Fetches filter lists and puts them on disk without ever destroying the copy
/// that currently works.
///
/// Everything downloaded is untrusted input: it is size-capped before and after
/// transfer, type-checked, sniffed for filter-list shape, and only then written
/// — atomically, so an interrupted update cannot leave a half-file behind.
public final class FilterListUpdater {
    public struct Outcome: Equatable {
        /// nil when the server answered 304.
        public let data: Data?
        public let state: FilterState
        public var wasModified: Bool { data != nil }
    }

    /// Roughly weekly, per the source lists' own publishing cadence.
    public static let checkInterval: TimeInterval = 7 * 24 * 60 * 60

    private let session: URLSession
    private let directory: URL
    private let now: () -> Date

    public init(session: URLSession = .shared, directory: URL,
                now: @escaping () -> Date = Date.init) {
        self.session = session
        self.directory = directory
        self.now = now
    }

    // MARK: Scheduling

    public func needsCheck(_ state: FilterState,
                           interval: TimeInterval = checkInterval) -> Bool {
        guard let last = state.lastUpdated else { return true }
        return now().timeIntervalSince(last) >= interval
    }

    public func nextCheck(after state: FilterState,
                          interval: TimeInterval = checkInterval) -> Date {
        (state.lastUpdated ?? now()).addingTimeInterval(interval)
    }

    // MARK: Fetch

    public func fetch(_ source: FilterSource,
                      state: FilterState) async throws -> Outcome {
        var request = URLRequest(url: source.url)
        request.timeoutInterval = 30
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        // Conditional request: the lists are large and change weekly.
        if let etag = state.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let modified = state.lastModified {
            request.setValue(modified, forHTTPHeaderField: "If-Modified-Since")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FilterUpdateError.httpStatus(-1)
        }

        if http.statusCode == 304 { return Outcome(data: nil, state: state) }
        guard http.statusCode == 200 else {
            throw FilterUpdateError.httpStatus(http.statusCode)
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type")
        guard let contentType,
              contentType.lowercased().hasPrefix(source.expectedContentType)
        else { throw FilterUpdateError.unexpectedContentType(contentType) }

        // Refuse before reading the body where the server tells us the size.
        if let declared = http.value(forHTTPHeaderField: "Content-Length"),
           let bytes = Int(declared), bytes > source.maxBytes {
            throw FilterUpdateError.declaredTooLarge(bytes)
        }
        guard data.count <= source.maxBytes else {
            throw FilterUpdateError.bodyTooLarge(data.count)
        }
        guard !data.isEmpty else { throw FilterUpdateError.empty }
        guard Self.looksLikeFilterList(data) else {
            throw FilterUpdateError.notAFilterList
        }

        var updated = state
        updated.lastUpdated = now()
        updated.checksum = Self.checksum(data)
        updated.etag = http.value(forHTTPHeaderField: "ETag") ?? state.etag
        updated.lastModified = http.value(forHTTPHeaderField: "Last-Modified")
            ?? state.lastModified
        updated.version = Self.version(in: data) ?? state.version
        return Outcome(data: data, state: updated)
    }

    // MARK: Storage

    public func storedURL(for source: FilterSource) -> URL {
        directory.appendingPathComponent("\(source.id).txt")
    }

    public func loadStored(_ source: FilterSource) -> Data? {
        try? Data(contentsOf: storedURL(for: source))
    }

    /// Writes via a temporary file and an atomic replace. A crash or a killed
    /// download therefore leaves the previous list intact rather than a
    /// truncated one.
    @discardableResult
    public func store(_ data: Data, for source: FilterSource,
                      expecting checksum: String? = nil) throws -> URL {
        if let checksum, Self.checksum(data) != checksum {
            throw FilterUpdateError.checksumMismatch
        }
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let destination = storedURL(for: source)
        let temporary = directory.appendingPathComponent(
            "\(source.id).\(UUID().uuidString).partial")

        try data.write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }

        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        return destination
    }

    // MARK: Validation helpers

    /// Cheap shape check. A filter list opens with an `[Adblock ...]` marker or
    /// a `!` comment header; an HTML error page or a captive-portal redirect
    /// does not.
    static func looksLikeFilterList(_ data: Data) -> Bool {
        guard let head = String(data: data.prefix(512), encoding: .utf8) else {
            return false
        }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("[Adblock") || trimmed.hasPrefix("!")
    }

    static func version(in data: Data) -> String? {
        guard let head = String(data: data.prefix(2048), encoding: .utf8) else {
            return nil
        }
        for line in head.split(separator: "\n", omittingEmptySubsequences: true) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("!") else { continue }
            let body = text.dropFirst().trimmingCharacters(in: .whitespaces)
            if body.lowercased().hasPrefix("version:") {
                return body.dropFirst("version:".count)
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
