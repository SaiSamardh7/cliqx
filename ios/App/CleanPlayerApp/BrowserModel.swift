import Foundation
import SwiftUI
import WebKit

struct Site: Codable, Hashable, Identifiable {
    var url: URL
    var title: String
    var id: URL { url }

    var host: String { url.host()?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString }
    /// Monogram for the tile — no third-party marks are bundled. Taken from
    /// the title, not the host: "developer.mozilla.org" would read as "D".
    var initials: String { String(title.prefix(1)).uppercased() }
}

@MainActor
final class BrowserModel: ObservableObject {
    /// nil means "showing home".
    @Published var current: URL?
    @Published var address: String = ""
    @Published private(set) var recents: [Site] = []

    /// Neutral, openly licensed sources — useful for exercising the player
    /// without bundling anyone's catalogue or branding.
    let shortcuts: [Site] = [
        Site(url: URL(string: "https://archive.org/details/movies")!, title: "Archive"),
        Site(url: URL(string: "https://commons.wikimedia.org/wiki/Category:Videos")!, title: "Wikimedia"),
        Site(url: URL(string: "https://developer.mozilla.org")!, title: "MDN"),
        Site(url: URL(string: "https://en.wikipedia.org")!, title: "Wikipedia"),
    ]

    private let store = UserDefaults.standard
    private let recentsKey = "recents.v1"

    init() {
        if let data = store.data(forKey: recentsKey),
           let saved = try? JSONDecoder().decode([Site].self, from: data) {
            recents = saved
        }
    }

    // MARK: - Navigation

    /// Turns whatever is in the field into a URL: a bare host becomes https,
    /// anything else becomes a search. Never trusts the string as-is.
    static func resolve(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let url = URL(string: text), let scheme = url.scheme?.lowercased() {
            return (scheme == "https" || scheme == "http") ? url : nil
        }
        // Looks like a hostname: no spaces, has a dot, and a plausible TLD.
        if !text.contains(" "), let dot = text.lastIndex(of: "."),
           text.distance(from: dot, to: text.endIndex) > 2 {
            return URL(string: "https://\(text)")
        }
        var q = URLComponents(string: "https://duckduckgo.com/")
        q?.queryItems = [URLQueryItem(name: "q", value: text)]
        return q?.url
    }

    func open(_ url: URL) {
        current = url
        address = url.absoluteString
    }

    func submitAddress() {
        guard let url = Self.resolve(address) else { return }
        open(url)
    }

    func goHome() {
        current = nil
        address = ""
    }

    func record(_ url: URL, title: String?) {
        guard url.scheme?.hasPrefix("http") == true else { return }
        let site = Site(url: url, title: (title?.isEmpty == false ? title! : url.host() ?? url.absoluteString))
        recents.removeAll { $0.url == site.url }
        recents.insert(site, at: 0)
        if recents.count > 12 { recents.removeLast(recents.count - 12) }
        persist()
    }

    func clearRecents() {
        recents.removeAll()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(recents) else { return }
        store.set(data, forKey: recentsKey)
    }

    /// Cookies, caches and site storage for the persistent store. Recents are
    /// separate — this is the data the *sites* left behind, not the list of
    /// where you went.
    static func clearWebsiteData() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        await store.removeData(ofTypes: types, for: records)
    }
}
