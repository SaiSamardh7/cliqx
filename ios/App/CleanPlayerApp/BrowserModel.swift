import CleanPlayer
import Foundation
import SwiftUI
import WebKit

struct Site: Codable, Hashable, Identifiable {
    var url: URL
    var title: String
    /// Where playback stopped, and how long the video was. Optional so old
    /// saved data (and shortcuts) decode without them; a fraction drives the
    /// resume bar on the card and the seek on re-entry.
    var resumeAt: Double?
    var resumeDuration: Double?
    /// When this was last watched. Ordering reads from here rather than from
    /// array position, so replaying something old moves it to the front no
    /// matter what pinning or removal did to the list.
    var lastPlayed: Date?
    /// Keep this site's login across launches, by giving its session cookies
    /// an expiry the server did not.
    ///
    /// Off unless the user asks. A session cookie is short-lived because the
    /// server said so; overriding that silently means a stolen unlocked phone
    /// holds a month of logins the server believed had ended. Optional so
    /// existing payloads migrate; nil reads as off.
    var staySignedIn: Bool?
    /// Visible grouping metadata. Optional so the existing recents.v1 payload
    /// migrates without a decoding break.
    var seriesKey: String?
    var seriesTitle: String?
    var episodeLabel: String?
    var id: URL { url }

    /// 0…1 through the video, or nil when there is nothing to resume.
    var progress: Double? {
        guard let at = resumeAt, let dur = resumeDuration, dur > 0, at > 3 else { return nil }
        return min(at / dur, 1)
    }

    /// `HostKey.canonical`, not a bare "www." replacement: that one stripped
    /// the sequence wherever it appeared, including out of the middle of a
    /// host. Falls back to the raw host for anything canonical rejects.
    var host: String {
        guard let raw = url.host() else { return url.absoluteString }
        return HostKey.canonical(raw) ?? raw
    }
    /// Monogram for the tile — no third-party marks are bundled. Taken from
    /// the title, not the host: "developer.mozilla.org" would read as "D".
    /// From the SHOW's name where there is one, so the letter matches the
    /// label printed under the card: "Aniwave - The Exiled Heavy Knight" is
    /// shown as "The Exiled Heavy Knight" and read as "A".
    var initials: String {
        String((seriesTitle ?? title).prefix(1)).uppercased()
    }
}

private struct EpisodeProgress: Codable {
    var position: Double
    var duration: Double
}

@MainActor
final class BrowserModel: ObservableObject {
    /// nil means "showing home".
    @Published var current: URL?
    @Published var address: String = ""
    @Published private(set) var recents: [Site] = []
    /// Kept on their own: pinned items survive the recents cap and "Clear", and
    /// show above the rest. A separate list, not a flag, so eviction never
    /// touches them.
    @Published private(set) var pinned: [Site] = []

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
    private let pinnedKey = "pinned.v1"
    private let episodeProgressKey = "episode-progress.v1"
    private var episodeProgress: [String: EpisodeProgress] = [:]

    /// A store that would not decode. Nothing may be written back over it:
    /// persisting an empty list is what turns one unreadable payload into a
    /// library that is gone for good.
    private var unreadable: Set<String> = []

    private func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        StoreRecovery.decode(type, from: store.data(forKey: key), named: key) { kept in
            self.unreadable.insert(key)
            StoreHealth.shared.record(store: key, keptAt: kept)
        }
    }

    init() {
        if let saved = load([Site].self, key: recentsKey) {
            recents = saved
        }
        if let saved = load([String: EpisodeProgress].self, key: episodeProgressKey) {
            // Keys used to be absolute URL strings. Fold each onto its
            // normalised key; where two collapse, keep the further position.
            for (key, progress) in saved {
                let folded = URL(string: key).map(AddressResolver.resumeKey(for:)) ?? key
                if let existing = episodeProgress[folded], existing.position >= progress.position { continue }
                episodeProgress[folded] = progress
            }
        }
        if let saved = load([Site].self, key: pinnedKey) {
            pinned = saved
        }
        migrateAndCollapseRecents()
    }

    /// Recents minus anything pinned — the pinned copy is shown in its own
    /// section, so it should not appear twice.
    var unpinnedRecents: [Site] {
        recents.filter { site in !pinned.contains { $0.url == site.url } }
    }

    func isPinned(_ site: Site) -> Bool {
        pinned.contains { $0.url == site.url }
    }

    // MARK: - Navigation

    /// Turns whatever is in the field into a URL: a bare host becomes https,
    /// anything else becomes a search. Never trusts the string as-is.
    ///
    /// The rule itself lives in `AddressResolver`, in the package, because the
    /// app target has no unit tests and this is worth testing.
    static func resolve(_ raw: String) -> URL? {
        AddressResolver.resolve(raw)
    }

    func open(_ url: URL) {
        current = url
        address = url.absoluteString
    }

    /// A card from the library: this URL is already known to be a video.
    ///
    /// Typing an address is a request to see a page; tapping a card you watched
    /// before is a request to carry on watching it. Without this the two were
    /// the same, so a recent landed on the site and the player had to be found
    /// and opened by hand every time, resume position and all.
    ///
    /// The flag is consumed on the next navigation, not held: it says something
    /// about this one tap, and must not still be armed for whatever the user
    /// browses to afterwards.
    func openWatched(_ url: URL) {
        pendingAutoTheater = url
        open(url)
    }

    /// Set by `openWatched`, read once by the web view.
    @Published var pendingAutoTheater: URL?

    /// Spent by the next navigation whether or not it is the one that was
    /// armed — which is what the comment above has always claimed. Leaving it
    /// set on a mismatch meant a tap on a card could still be armed pages
    /// later, and open a player over something the user merely browsed to.
    func consumeAutoTheater(for url: URL) -> Bool {
        guard let armed = pendingAutoTheater else { return false }
        pendingAutoTheater = nil
        return armed == url
    }

    /// WebKit can navigate without going through `open` (links, redirects,
    /// forms and hash routes). Keep the SwiftUI source of truth on the page
    /// that is actually visible so rebuilding the web view, especially when
    /// private browsing changes, cannot jump back to an older URL.
    func synchronizeCurrent(_ url: URL) {
        guard url.scheme == "http" || url.scheme == "https" else { return }
        if current != url { current = url }
        if address != url.absoluteString { address = url.absoluteString }
    }

    func submitAddress() {
        guard let url = Self.resolve(address) else { return }
        open(url)
    }

    func goHome() {
        current = nil
        address = ""
    }

    /// A page becomes a "recent" only when it is actually watched — the browser
    /// records nothing on plain navigation, so the library is videos, not
    /// history. Preserves any resume position already saved for this URL.
    func recordWatched(_ url: URL, title: String?) {
        guard url.scheme?.hasPrefix("http") == true else { return }
        let name = (title?.isEmpty == false) ? title! : (url.host() ?? url.absoluteString)
        let key = PlayerFormatting.seriesIdentity(title: name, url: url)
        let show = PlayerFormatting.seriesTitle(name, host: url.host() ?? "")
        let existing = recents.first { $0.url == url } ?? pinned.first { $0.url == url }
        let saved = episodeProgress[AddressResolver.resumeKey(for: url)]
        let site = Site(url: url, title: name,
                        resumeAt: saved?.position ?? existing?.resumeAt,
                        resumeDuration: saved?.duration ?? existing?.resumeDuration,
                        lastPlayed: Date(), seriesKey: key,
                        seriesTitle: show,
                        episodeLabel: PlayerFormatting.episodeLabel(name))
        // Exact URL first, and never only by series.
        //
        // The series key is derived from the title, and the title is not stable
        // across a page's life, so the same URL could be saved twice under keys
        // that differed by a few characters of truncation. Two cards then
        // carried the same `Site.id`, and `ForEach` given duplicate ids reuses
        // rows — which is how tapping one show opened another.
        recents.removeAll { $0.url == url }
        // One visible card per series. Episode progress is retained separately.
        recents.removeAll { ($0.seriesKey ?? seriesIdentity(for: $0)) == key }
        recents.insert(site, at: 0)
        // Newest play first. Anything saved before this field existed has no
        // date, so it sorts after the dated entries rather than jumping around.
        recents.sort { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        if recents.count > 12 { recents.removeLast(recents.count - 12) }
        persist()
        // Keep the pinned copy's title fresh too.
        if let index = pinned.firstIndex(where: { $0.url == url }) {
            pinned[index].title = name
            persistPinned()
        }
    }

    /// Corrects a recent's name once the page's title has caught up.
    ///
    /// `recordWatched` has to run the moment theater opens, because resume and
    /// the poster hang off it. The title is not reliable then: these sites
    /// change episode by replacing the player and pushing history, so the URL
    /// updates at once and `WKWebView.title` lags. The card was therefore
    /// saved with the new URL under the previous episode's name — tap it and
    /// the other show played. `urlDidChange` already defers its own title read
    /// for exactly this reason.
    ///
    /// The URL was never wrong, so this repairs the label and everything
    /// derived from it, rather than re-recording the entry.
    func retitleWatched(_ url: URL, title: String?) {
        guard let corrected = title, !corrected.isEmpty,
              let index = recents.firstIndex(where: { $0.url == url }),
              recents[index].title != corrected
        else { return }

        let key = PlayerFormatting.seriesIdentity(title: corrected, url: url)
        recents[index].title = corrected
        recents[index].seriesKey = key
        recents[index].seriesTitle = PlayerFormatting.seriesTitle(corrected,
                                                                 host: url.host() ?? "")
        recents[index].episodeLabel = PlayerFormatting.episodeLabel(corrected)
        // The name decides the series, so a corrected name can belong to a card
        // already standing for that show. One visible card per series still.
        recents.removeAll { $0.url != url && ($0.seriesKey ?? seriesIdentity(for: $0)) == key }
        // A corrected title can also reveal a plain duplicate of this URL.
        var seenURLs = Set<URL>()
        recents.removeAll { !seenURLs.insert($0.url).inserted }
        persist()

        if let index = pinned.firstIndex(where: { $0.url == url }) {
            pinned[index].title = corrected
            persistPinned()
        }
    }

    /// Remember where playback stopped, in both lists so the bar shows wherever
    /// the card lives.
    func saveResume(_ url: URL, at seconds: Double, duration: Double) {
        guard duration > 0 else { return }
        episodeProgress[AddressResolver.resumeKey(for: url)] = EpisodeProgress(position: seconds,
                                                              duration: duration)
        for index in recents.indices where recents[index].url == url {
            recents[index].resumeAt = seconds
            recents[index].resumeDuration = duration
        }
        for index in pinned.indices where pinned[index].url == url {
            pinned[index].resumeAt = seconds
            pinned[index].resumeDuration = duration
        }
        persist()
        persistPinned()
        persistEpisodeProgress()
    }

    /// Saved position for a URL, or 0.
    func resume(for url: URL) -> Double {
        episodeProgress[AddressResolver.resumeKey(for: url)]?.position
            ?? (recents.first { $0.url == url } ?? pinned.first { $0.url == url })?.resumeAt
            ?? 0
    }

    /// Clears the Recent list. Pinned items are deliberately kept — pinning is
    /// how you say "not this".
    func clearRecents() {
        recents.removeAll()
        persist()
    }

    /// Remove one item entirely: out of Recent and unpinned.
    func remove(_ site: Site) {
        recents.removeAll { $0.url == site.url }
        pinned.removeAll { $0.url == site.url }
        persist()
        persistPinned()
    }

    /// Pin a site from the browser, by its root. This is how a server of your
    /// own gets onto the home screen: Recent only fills when a video is
    /// actually watched, and a media server's watch page is a hash route that
    /// opens to nothing on its own, so neither path ever produced a usable
    /// tile for one. Titled by the page when it has a title, else by the host.
    func pinSite(_ url: URL, title: String?) {
        guard let root = AddressResolver.siteRoot(of: url), !isPinned(root) else { return }
        let name = (title?.isEmpty == false) ? title! : (root.host() ?? root.absoluteString)
        let existing = recents.first { $0.url == root }
        pinned.insert(existing ?? Site(url: root, title: name), at: 0)
        persistPinned()
    }

    func isPinned(_ url: URL) -> Bool {
        guard let root = AddressResolver.siteRoot(of: url) else { return false }
        return pinned.contains { $0.url == root }
    }

    /// A host the user pinned. The one signal that a server is theirs.
    func isPinnedHost(_ host: String) -> Bool {
        guard let wanted = HostKey.canonical(host) else { return false }
        return pinned.contains { $0.url.host().flatMap(HostKey.canonical) == wanted }
    }

    /// Pinned AND asked to stay signed in. Only these sites have their session
    /// cookies given an expiry.
    func keepsSignIn(_ host: String) -> Bool {
        guard let wanted = HostKey.canonical(host) else { return false }
        return pinned.contains {
            $0.staySignedIn == true
                && $0.url.host().flatMap(HostKey.canonical) == wanted
        }
    }

    func setStaySignedIn(_ on: Bool, for site: Site) {
        guard let index = pinned.firstIndex(where: { $0.url == site.url }) else { return }
        pinned[index].staySignedIn = on
        persistPinned()
    }

    func unpinSite(_ url: URL) {
        guard let root = AddressResolver.siteRoot(of: url) else { return }
        pinned.removeAll { $0.url == root }
        persistPinned()
    }

    func togglePin(_ site: Site) {
        if let index = pinned.firstIndex(where: { $0.url == site.url }) {
            pinned.remove(at: index)
        } else {
            pinned.insert(site, at: 0)
        }
        persistPinned()
    }

    private func persist() {
        write(recents, key: recentsKey)
    }

    private func persistPinned() {
        write(pinned, key: pinnedKey)
    }

    private func persistEpisodeProgress() {
        write(episodeProgress, key: episodeProgressKey)
    }

    /// Never writes over a payload that failed to decode this launch.
    private func write<T: Encodable>(_ value: T, key: String) {
        guard !unreadable.contains(key) else { return }
        guard let data = try? JSONEncoder().encode(value) else {
            StoreHealth.shared.record(store: key, keptAt: nil)
            return
        }
        store.set(data, forKey: key)
    }

    private func seriesIdentity(for site: Site) -> String {
        PlayerFormatting.seriesIdentity(title: site.title, url: site.url)
    }

    /// Upgrade existing per-episode cards in place. The newest card wins, but
    /// every old card first contributes its resume point to hidden history.
    private func migrateAndCollapseRecents() {
        var seen = Set<String>()
        var seenURLs = Set<URL>()
        var collapsed: [Site] = []
        for var site in recents.sorted(by: {
            ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast)
        }) {
            if let at = site.resumeAt, let duration = site.resumeDuration {
                episodeProgress[AddressResolver.resumeKey(for: site.url)] = EpisodeProgress(position: at,
                                                                          duration: duration)
            }
            // Drops duplicates already written by earlier builds, newest kept
            // — its resume point has just been folded into `episodeProgress`,
            // so nothing is lost by discarding the older card.
            guard seenURLs.insert(site.url).inserted else { continue }
            let key = site.seriesKey ?? seriesIdentity(for: site)
            guard seen.insert(key).inserted else { continue }
            site.seriesKey = key
            site.seriesTitle = site.seriesTitle
                ?? PlayerFormatting.seriesTitle(site.title, host: site.url.host() ?? "")
            site.episodeLabel = site.episodeLabel ?? PlayerFormatting.episodeLabel(site.title)
            collapsed.append(site)
        }
        if collapsed != recents {
            recents = collapsed
            persist()
        }
        persistEpisodeProgress()
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
