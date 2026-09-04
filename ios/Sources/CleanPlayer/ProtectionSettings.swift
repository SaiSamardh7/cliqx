import Foundation

/// Canonical form of a host, so that an exception added on one spelling of a
/// site is found again on another.
///
/// Case, a trailing root dot and a leading `www.` are all noise: a user who
/// turns protection off on `WWW.Example.com.` means `example.com`. Everything
/// stored and every lookup goes through here, so the two can never disagree.
public enum HostKey {
    public static func canonical(_ raw: String) -> String? {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // A URL may have been pasted in whole.
        if host.contains("://"), let url = URL(string: host), let h = url.host() {
            host = h.lowercased()
        }
        while host.hasSuffix(".") { host.removeLast() }
        while host.hasPrefix(".") { host.removeFirst() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard !host.isEmpty, host.contains("."), !host.contains("/"),
              !host.contains(" ")
        else { return nil }
        return host
    }

    /// Second-level labels that are part of the suffix rather than a site:
    /// the `com` in `com.pl`, the `co` in `co.uk`.
    ///
    /// This replaced a hardcoded list of 21 known suffixes. That list was
    /// written when `registrableDomain` only resolved user exceptions, where
    /// over-reducing was cosmetic. It stopped being cosmetic when
    /// `isSameSite` became a security predicate: every ccTLD second level the
    /// list omitted — `com.pl`, `co.il`, `com.ua`, `com.ar` and most others —
    /// reduced `evil.com.pl` and `victim.com.pl` both to `com.pl`, so they
    /// compared equal and a cross-site redirect was let straight through.
    ///
    /// Matching the shape instead of enumerating instances covers all of them,
    /// and errs the safe way: an unknown suffix yields a *more* specific
    /// domain, so two different sites never collide.
    private static let suffixSecondLevels: Set<String> = [
        "com", "co", "net", "org", "gov", "edu", "ac", "or", "ne", "go",
        "mil", "int", "info", "biz", "name", "web", "in",
    ]

    /// The registrable part of a host: `cdn.player.example.com` -> `example.com`.
    ///
    /// ponytail: shape-matching, not the real Public Suffix List. Ceiling — a
    /// suffix whose second level is an ordinary word (`blogspot.com`, where the
    /// PSL makes each subdomain its own site) still reduces one label too far,
    /// so two subdomains of it compare equal. Upgrade path: bundle the PSL and
    /// match against it here; `isSameSite` and its tests do not change.
    public static func registrableDomain(_ raw: String) -> String? {
        guard let host = canonical(raw) else { return nil }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }

        // A two-letter TLD with a generic second level is a country-code
        // suffix: take one more label so the site itself is included.
        let tld = labels[labels.count - 1]
        let second = labels[labels.count - 2]
        if labels.count >= 3, tld.count == 2, suffixSecondLevels.contains(second) {
            return labels.suffix(3).joined(separator: ".")
        }
        return labels.suffix(2).joined(separator: ".")
    }

    /// Whether a destination belongs to the same site the user is already on.
    ///
    /// Used to decide whether a page may open a window that replaces what the
    /// user is watching. A user gesture is not consent on its own: the standard
    /// ad trick is an invisible anchor over the video, so the tap that looks
    /// like Play is real but the destination is not what was intended.
    ///
    /// Deliberately not `matches(stored:host:)` — that relation is
    /// one-directional, made for exceptions where the user names a base domain.
    /// Here neither host is the base: a page on `player.example.com` linking to
    /// `cdn.example.com` is the same site, and a one-directional test says no.
    public static func isSameSite(_ destination: URL, as current: URL?) -> Bool {
        guard let current, let from = current.host(), let to = destination.host(),
              let a = registrableDomain(from), let b = registrableDomain(to)
        else { return false }
        return a == b
    }

    /// Subdomain policy: an exception covers the host it was added for and
    /// everything under it. A user who allows `example.com` because the player
    /// is broken means the player on `cdn.example.com` too.
    public static func matches(stored: String, host: String) -> Bool {
        guard let candidate = canonical(host) else { return false }
        return candidate == stored || candidate.hasSuffix("." + stored)
    }
}

/// Protection preferences, persisted. Everything the Settings screen writes and
/// the rule pipeline reads lives here.
@MainActor
public final class ProtectionSettings: ObservableObject {
    @Published public var level: ProtectionLevel {
        didSet { store.set(level.rawValue, forKey: Keys.level) }
    }

    /// Hosts the user has switched protection off for, canonical form.
    @Published public private(set) var exemptHosts: [String] {
        didSet { store.set(exemptHosts, forKey: Keys.exemptions) }
    }

    /// Non-persistent data store: no cookies, cache or local storage survive.
    @Published public var privateBrowsing: Bool {
        didSet { store.set(privateBrowsing, forKey: Keys.privateBrowsing) }
    }

    /// Set once the user has been shown what the app does.
    @Published public var hasOnboarded: Bool {
        didSet { store.set(hasOnboarded, forKey: Keys.onboarded) }
    }

    private enum Keys {
        static let level = "protection.level.v1"
        static let exemptions = "protection.exemptions.v1"
        static let privateBrowsing = "protection.private.v1"
        static let onboarded = "protection.onboarded.v1"
    }

    private let store: UserDefaults

    public init(store: UserDefaults = .standard) {
        self.store = store
        self.level = (store.string(forKey: Keys.level)
            .flatMap(ProtectionLevel.init(rawValue:))) ?? .standard
        self.exemptHosts = store.stringArray(forKey: Keys.exemptions) ?? []
        self.privateBrowsing = store.bool(forKey: Keys.privateBrowsing)
        self.hasOnboarded = store.bool(forKey: Keys.onboarded)
    }

    // MARK: Per-site exceptions

    public func isExempt(_ host: String) -> Bool {
        exemptHosts.contains { HostKey.matches(stored: $0, host: host) }
    }

    @discardableResult
    public func addExemption(_ host: String) -> Bool {
        guard let key = HostKey.canonical(host), !exemptHosts.contains(key)
        else { return false }
        exemptHosts = (exemptHosts + [key]).sorted()
        return true
    }

    public func removeExemption(_ host: String) {
        guard let key = HostKey.canonical(host) else { return }
        exemptHosts.removeAll { $0 == key }
    }

    public func setExempt(_ exempt: Bool, for host: String) {
        if exempt { addExemption(host) } else { removeExemption(host) }
    }
}
