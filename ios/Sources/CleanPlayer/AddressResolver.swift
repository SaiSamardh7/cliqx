import Foundation

/// Turning what someone typed into somewhere to go.
///
/// Lives in the package rather than in `BrowserModel` for one reason: the app
/// target has no unit tests, and this is the one piece of the address bar that
/// is pure enough to check properly. Every bug found in the browsing layer so
/// far has been in code shaped like this and reachable only through the UI.
public enum AddressResolver {
    /// The only schemes the browser opens. Anything else is treated as text to
    /// search for, never handed to another app.
    private static let webSchemes: Set<String> = ["http", "https"]

    public static func resolve(_ raw: String,
                               search engine: URL = defaultSearch) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let url = URL(string: text), let scheme = url.scheme?.lowercased() {
            if webSchemes.contains(scheme) { return url }
            // "localhost:8096" and "nas.local:8096" parse as a scheme followed
            // by a path — both are syntactically valid scheme names — when what
            // was typed is a host and a port. Fall through to host handling for
            // those rather than searching for them.
            if !isLocalHost(scheme) {
                // Not a page this app opens — but returning nil made the address
                // bar do nothing at all, with no message. "ratio:16" is a search,
                // not a navigation the user should have to guess was rejected.
                return query(text, on: engine)
            }
        }

        guard !text.contains(" ") else { return query(text, on: engine) }

        // A home server is the one case where https-first is wrong. A NAS or
        // Jellyfin box on the LAN almost never has a publicly trusted
        // certificate, so defaulting it to https guarantees the load dies on
        // ATS — while cleartext to a private address is explicitly allowed.
        // Public hosts keep the secure default.
        let local = isLocalHost(hostPart(of: text))
        // Looks like a hostname: has a dot and a plausible TLD — or is a local
        // address, which may be a bare name like "localhost" with no dot.
        let looksLikeHost = local || (text.lastIndex(of: ".").map {
            text.distance(from: $0, to: text.endIndex) > 2
        } ?? false)

        if looksLikeHost, let url = URL(string: "\(local ? "http" : "https")://\(text)") {
            return url
        }
        return query(text, on: engine)
    }

    /// The host on its own: no path, no port.
    private static func hostPart(of text: String) -> String {
        let beforePath = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        return beforePath.split(separator: ":").first.map(String.init) ?? beforePath
    }

    /// Private and `.local` hosts — the ones controlled by the user, where a
    /// trusted certificate is the exception rather than the rule. Link-local
    /// addresses are deliberately excluded because peers can claim them on a
    /// shared network.
    public static func isLocalHost(_ host: String) -> Bool {
        let name = host.lowercased()
        if name == "localhost" || name.hasSuffix(".local") { return true }
        let parts = name.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (192, 168), (127, _): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    /// The site a page belongs to: scheme, host and port, nothing else.
    ///
    /// What someone pins from the browser is "my Jellyfin", not the route they
    /// happened to be on. A home-server app is a single page that routes with
    /// the fragment — `/web/index.html#/video` — and that route means nothing
    /// when opened cold; the server root always does.
    public static func siteRoot(of url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), webSchemes.contains(scheme),
              let host = url.host(), !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        components.path = "/"
        return components.url
    }

    public static let defaultSearch = URL(string: "https://duckduckgo.com/")!

    /// The identity of a watch page, for keying resume positions.
    ///
    /// The absolute string was the key, and the same episode arrived under
    /// five of them: `www.` or not, a `?t=` the site added on share, a
    /// `utm_source` from wherever the link was pasted, a trailing slash. Host
    /// is canonicalised, the scheme dropped (a site moving to https keeps its
    /// history), tracking and timestamp parameters removed, the rest kept
    /// in order. The fragment stays: single-page servers route with it.
    public static func resumeKey(for url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        let host = parts.host.flatMap(HostKey.canonical) ?? parts.host ?? ""
        let port = parts.port.map { ":\($0)" } ?? ""
        var path = parts.path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        parts.queryItems = parts.queryItems?.filter { item in
            !isNoise(item)
        }
        let query = (parts.queryItems?.isEmpty == false) ? "?" + (parts.percentEncodedQuery ?? "") : ""
        let fragment = parts.fragment.map { "#" + $0 } ?? ""
        return host + port + path + query + fragment
    }

    /// Share-sheet and referrer noise: these carry no content identity, so
    /// they go whatever their value.
    private static let alwaysNoise: Set<String> = [
        "fbclid", "gclid", "msclkid", "igshid", "mc_cid", "mc_eid",
        "ref", "ref_src", "si", "feature",
    ]

    /// "Start at" parameters, dropped only when the VALUE looks like a time.
    ///
    /// `t` is a timestamp on YouTube and a thread id on a dozen forums; the
    /// name alone cannot tell them apart, but `120`, `1h2m3s` and `90s` are
    /// not content ids.
    private static let timeLike: Set<String> = ["t", "start", "time_continue", "starttime"]

    /// `90`, `90s`, `1h2m3s`, `2m30s`, `00:01:30`.
    private static let timeValue = try? NSRegularExpression(
        pattern: #"^(\d+s?|(\d+h)?(\d+m)?(\d+s)?|\d{1,2}(:\d{2}){1,2})$"#,
        options: [.caseInsensitive])

    private static func isNoise(_ item: URLQueryItem) -> Bool {
        let name = item.name.lowercased()
        if name.hasPrefix("utm_") || alwaysNoise.contains(name) { return true }
        guard timeLike.contains(name) else { return false }
        guard let value = item.value, !value.isEmpty else { return true }
        return looksLikeTime(value)
    }

    static func looksLikeTime(_ value: String) -> Bool {
        guard let timeValue else { return false }
        let range = NSRange(value.startIndex..., in: value)
        guard let match = timeValue.firstMatch(in: value, range: range),
              match.range == range else { return false }
        // The empty alternation matches an empty string; a value that is only
        // letters ("abc") cannot reach here, but "s" alone would.
        return value.contains(where: \.isNumber)
    }

    private static func query(_ text: String, on engine: URL) -> URL? {
        var components = URLComponents(url: engine, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "q", value: text)]
        return components?.url
    }
}
