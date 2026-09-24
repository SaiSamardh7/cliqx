import Foundation
import MetricKit
import os

/// The minimum that makes "is v0.2 better than v0.1" answerable.
///
/// Two things, and only two: MetricKit's crash, hang and disk-write reports
/// written to Application Support where a sysdiagnose or Finder file sharing
/// can pick them up, and a counter for the product's one number — how many
/// Watch clean taps ended in a clean player. Both stay on the device; nothing
/// is uploaded anywhere.
///
/// ponytail: files and os_log, no SDK. Add a backend when there are users
/// whose devices you cannot plug in.
enum Diagnostics {
    enum Event: String {
        case watchCleanAttempted, watchCleanSucceeded
    }

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.saisamardh.cleanplayer",
        category: "Outcome")
    private static let subscriber = MetricSubscriber()
    private static let countsKey = "diagnostics.counts.v1"

    static func start() {
        MXMetricManager.shared.add(subscriber)
    }

    /// Per-event totals in UserDefaults, and a line in the unified log so
    /// `log show --predicate 'category == "Outcome"'` on a plugged-in phone
    /// gives the ratio without opening the app.
    static func count(_ event: Event) {
        var counts = UserDefaults.standard.dictionary(forKey: countsKey) as? [String: Int] ?? [:]
        counts[event.rawValue, default: 0] += 1
        UserDefaults.standard.set(counts, forKey: countsKey)
        log.notice("\(event.rawValue, privacy: .public) total=\(counts[event.rawValue] ?? 0)")
    }

    static var counts: [Event: Int] {
        let raw = UserDefaults.standard.dictionary(forKey: countsKey) as? [String: Int] ?? [:]
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            Event(rawValue: key).map { ($0, value) }
        })
    }

    private final class MetricSubscriber: NSObject, MXMetricManagerSubscriber {
        private var directory: URL {
            let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask)[0]
                .appendingPathComponent("diagnostics", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            return base
        }

        func didReceive(_ payloads: [MXMetricPayload]) {
            write(payloads.map { $0.jsonRepresentation() }, prefix: "metrics")
        }

        func didReceive(_ payloads: [MXDiagnosticPayload]) {
            write(payloads.map { $0.jsonRepresentation() }, prefix: "diagnostic")
        }

        private func write(_ blobs: [Data], prefix: String) {
            let stamp = ISO8601DateFormatter().string(from: Date())
            for (index, data) in blobs.enumerated() {
                let file = directory.appendingPathComponent("\(prefix)-\(stamp)-\(index).json")
                try? data.write(to: file, options: .atomic)
            }
        }
    }
}
