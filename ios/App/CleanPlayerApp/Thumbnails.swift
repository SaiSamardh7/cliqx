import CryptoKit
import Foundation
import UIKit

/// Poster frames captured from what you watched, cached on disk by page URL.
///
/// In Caches, not Documents: they are regenerable and the OS may reclaim them
/// under pressure, which is exactly right for thumbnails. Keyed by a hash of
/// the URL so the filename is stable and filesystem-safe.
enum Thumbnails {
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static func file(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("jpg")
    }

    static func save(_ data: Data, for url: URL) {
        try? data.write(to: file(for: url), options: .atomic)
    }

    static func image(for url: URL) -> UIImage? {
        UIImage(contentsOfFile: file(for: url).path)
    }

    static func remove(for url: URL) {
        try? FileManager.default.removeItem(at: file(for: url))
    }
}
