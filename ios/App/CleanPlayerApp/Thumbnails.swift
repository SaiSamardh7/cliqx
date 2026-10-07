import CleanPlayer
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

    /// Keeps a frame only if there is a picture in it.
    ///
    /// A staged video snapshots as solid black — WebKit does not capture the
    /// video layer — and a black JPEG is not nil, so `image(for:)` returned it
    /// and the card's monogram fallback never ran. The library filled with
    /// blank tiles. See `PosterFrame`.
    @discardableResult
    static func save(_ image: UIImage, for url: URL) -> Bool {
        guard let frame = image.cgImage, PosterFrame.carriesPicture(frame),
              let data = image.jpegData(compressionQuality: 0.7)
        else {
            // Clear any blank poster already cached for this page, so a
            // library that filled with black tiles heals on the next watch
            // rather than staying broken until the cache is evicted.
            remove(for: url)
            return false
        }
        try? data.write(to: file(for: url), options: .atomic)
        cache.setObject(image, forKey: file(for: url).path as NSString)
        return true
    }

    /// Decoded posters, kept in memory.
    ///
    /// `image(for:)` is called from inside a card's body, so SwiftUI asks for
    /// it again on every pass — and each ask was a file read and a decode of a
    /// 1440×2746 JPEG, on the main thread, for every visible card. Coming back
    /// to the app re-renders the whole shelf at once, which is exactly when
    /// that was felt. `NSCache` empties itself under memory pressure, which is
    /// the right behaviour for something regenerable.
    private static let cache = NSCache<NSString, UIImage>()

    static func image(for url: URL) -> UIImage? {
        let key = file(for: url).path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = UIImage(contentsOfFile: key as String) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    static func remove(for url: URL) {
        cache.removeObject(forKey: file(for: url).path as NSString)
        try? FileManager.default.removeItem(at: file(for: url))
    }
}
