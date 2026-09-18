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

    /// Private, link-local and `.local` hosts — the ones behind the router,
    /// where a trusted certificate is the exception rather than the rule.
    public static func isLocalHost(_ host: String) -> Bool {
        let name = host.lowercased()
        if name == "localhost" || name.hasSuffix(".local") { return true }
        let parts = name.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (192, 168), (169, 254), (127, _): return true
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

    private static func query(_ text: String, on engine: URL) -> URL? {
        var components = URLComponents(url: engine, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "q", value: text)]
        return components?.url
    }
}
