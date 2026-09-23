import Foundation

/// The request shapes for talking to a Jellyfin server. Pure: builds URLs and
/// headers, sends nothing, so the parts that are easy to get subtly wrong —
/// the auth header grammar, where the token goes for media URLs — can be
/// checked without a server.
///
/// Why direct API and not the web UI in a web view: the web UI is a website,
/// and a website inside a browser is what Cliqx already does. This gives the
/// server a shelf on Home, the native player, and resume that the server
/// itself keeps — so the phone, the TV and the browser agree.
public enum JellyfinAPI {
    public static let client = "Cliqx"
    /// The shipped version, so the server's Devices dashboard names the build
    /// that actually connected. Hard-coding it meant the dashboard reported
    /// 0.1 forever; VERSION is the one source, see tools/check-version.py.
    public static let version =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "0"

    /// `Authorization: MediaBrowser Client="…", Device="…", DeviceId="…",
    /// Version="…", Token="…"`. The token is omitted before sign-in; the rest
    /// is what the server shows under Dashboard → Devices.
    public static func authorization(deviceID: String, deviceName: String,
                                     token: String? = nil) -> String {
        var fields = [
            "Client=\"\(client)\"",
            "Device=\"\(quoteSafe(deviceName))\"",
            "DeviceId=\"\(quoteSafe(deviceID))\"",
            "Version=\"\(version)\"",
        ]
        if let token, !token.isEmpty { fields.append("Token=\"\(token)\"") }
        return "MediaBrowser " + fields.joined(separator: ", ")
    }

    /// Direct stream of the container as stored. VLC decodes whatever it is,
    /// so no transcode is asked for. The token rides in the query because the
    /// player fetches this URL itself and cannot add headers.
    public static func streamURL(server: URL, itemID: String, token: String) -> URL? {
        var parts = URLComponents(url: server.appendingPathComponent("Videos/\(itemID)/stream"),
                                  resolvingAgainstBaseURL: false)
        parts?.queryItems = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "api_key", value: token),
        ]
        return parts?.url
    }

    public enum ImageKind: String { case primary = "Primary", backdrop = "Backdrop", logo = "Logo", thumb = "Thumb" }

    /// Art of one kind, capped in height. Nil when the item reports no such
    /// image, so the caller can draw a monogram instead of a broken image.
    public static func imageURL(server: URL, itemID: String, tag: String?,
                                kind: ImageKind = .primary, maxHeight: Int = 450) -> URL? {
        guard let tag else { return nil }
        var parts = URLComponents(url: server.appendingPathComponent("Items/\(itemID)/Images/\(kind.rawValue)"),
                                  resolvingAgainstBaseURL: false)
        parts?.queryItems = [
            URLQueryItem(name: "maxHeight", value: String(maxHeight)),
            URLQueryItem(name: "tag", value: tag),
        ]
        return parts?.url
    }

    /// "Ends at 01:51 AM": when a film finishes if played from `positionMs`
    /// starting now. Nil without a runtime.
    public static func endsAt(runtimeTicks: Int64?, positionMs: Int, now: Date = Date()) -> Date? {
        guard let runtimeTicks, runtimeTicks > 0 else { return nil }
        let remainingMs = max(0, milliseconds(fromTicks: runtimeTicks) - positionMs)
        return now.addingTimeInterval(Double(remainingMs) / 1000)
    }

    /// Jellyfin positions are in ticks: 10,000,000 per second.
    public static let ticksPerMillisecond: Int64 = 10_000
    public static func ticks(fromMilliseconds ms: Int) -> Int64 { Int64(ms) * ticksPerMillisecond }
    public static func milliseconds(fromTicks ticks: Int64) -> Int { Int(ticks / ticksPerMillisecond) }

    /// The server root a person typed: scheme defaulted the way the address
    /// bar does (http for a LAN address, https otherwise), path dropped —
    /// `http://nas:8096/web/index.html` is the same server as `http://nas:8096`.
    public static func serverURL(from text: String) -> URL? {
        guard let resolved = AddressResolver.resolve(text),
              resolved.host() != AddressResolver.defaultSearch.host()
        else { return nil }
        return AddressResolver.siteRoot(of: resolved)
    }

    /// The decoder every response goes through.
    ///
    /// Tolerant about dates on purpose. `dateDecodingStrategy` applies to the
    /// whole payload, so a single value it refuses throws away the entire
    /// response — a shelf, a library listing, or the episode list that Next
    /// and Previous are built from. Every date here is decoration, a year
    /// under a title, and losing a screen to protect one of them is the wrong
    /// trade. Jellyfin has been seen emitting timestamps with no zone, which
    /// neither ISO 8601 formatter accepts.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let zoneless = DateFormatter()
        zoneless.locale = Locale(identifier: "en_US_POSIX")
        zoneless.timeZone = TimeZone(identifier: "UTC")
        zoneless.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSS"
        let dayOnly = DateFormatter()
        dayOnly.locale = Locale(identifier: "en_US_POSIX")
        dayOnly.timeZone = TimeZone(identifier: "UTC")
        dayOnly.dateFormat = "yyyy-MM-dd"

        decoder.dateDecodingStrategy = .custom { container in
            let text = try container.singleValueContainer().decode(String.self)
            if let date = iso.date(from: text) ?? plain.date(from: text)
                ?? zoneless.date(from: text) ?? dayOnly.date(from: text) {
                return date
            }
            return unparseableDate
        }
        return decoder
    }

    /// What an unreadable timestamp becomes. Distinct enough that a caller can
    /// tell "the server said nothing useful" from a real date.
    public static let unparseableDate = Date.distantPast

    private static func quoteSafe(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "'")
    }
}
