import Foundation

/// An address typed into the Add Server sheet, read as a stream to play rather
/// than as a server to sign in to.
///
/// Separate from `JellyfinAPI.serverURL(from:)` because the two want opposite
/// things from the same text. A Jellyfin address is a *mount point*, so that
/// one trims `/web`, trims a trailing filename, and drops the query — a server
/// does not live at `…/film.mkv?token=abc`. A stream is exactly that filename
/// and exactly that query, so everything those rules remove is the part that
/// matters here.
///
/// ponytail: no media-extension allowlist. VLC decides what it can play, and an
/// HLS endpoint is frequently a bare path with no extension at all, so a guess
/// made here would reject working streams to catch typing mistakes the player
/// already reports.
public enum StreamAddress {
    /// The address as a playable URL, or nil if it is not one.
    ///
    /// Returns nil for anything `AddressResolver` would have searched for: a
    /// phrase, a scheme this app does not open. Handing a search-results page
    /// to the player would "work" — VLC would fetch HTML and show nothing —
    /// so it is rejected here, where the reason can still be explained.
    public static func url(from text: String, search engine: URL = AddressResolver.defaultSearch) -> URL? {
        guard let resolved = AddressResolver.resolve(text, search: engine),
              let scheme = resolved.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = resolved.host(), !host.isEmpty,
              // `resolve` answers a search URL for text it could not read as an
              // address. That is a real URL with a real host, so the only thing
              // separating it from a stream the user meant is where it points.
              resolved.host() != engine.host()
        else { return nil }
        return resolved
    }

    /// What to call a stream in the player, derived from the address.
    ///
    /// The last path segment without its extension, which is the filename for
    /// `…/The Thing.mkv` and something useful for most direct links. An
    /// address with no path to speak of falls back to the host, because an
    /// empty title reads as a loading failure.
    public static func displayName(for url: URL) -> String {
        let last = url.deletingPathExtension().lastPathComponent
        if !last.isEmpty, last != "/" { return last }
        return url.host() ?? url.absoluteString
    }
}
