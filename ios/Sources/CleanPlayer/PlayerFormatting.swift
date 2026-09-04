import Foundation

/// Turning what a page says into what a player shows.
///
/// Pure string work, kept out of the view so it can be tested — the first
/// version of `showTitle` returned the site's own name for the very page it was
/// written against, and nothing caught it.
public enum PlayerFormatting {

    public static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    public static func rateText(_ rate: Double) -> String {
        rate == rate.rounded() ? String(Int(rate)) : String(format: "%.2g", rate)
}

    /// h:mm:ss only when there is an hour to show.
    public static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let s = total % 60, m = (total / 60) % 60, h = total / 3600
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
}

    /// VoiceOver reads "one minute five seconds", not "1:05".
    public static func spoken(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 seconds" }
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        f.unitsStyle = .spellOut
        return f.string(from: seconds) ?? "\(Int(seconds)) seconds"
}

    /// Page titles are built for search engines, not for players:
    /// "Aniwave - Hunter x Hunter (2011) — Episode 112: Monster", or
    /// "Big Buck Bunny : Free Download, Borrow ... : Internet Archive".
    ///
    /// Taking the part before the first separator is wrong, because the site
    /// name sits on the left as often as the right — that rule returned
    /// "Aniwave" for the first title above. So: split into segments, drop the
    /// one that is the site's own name, and take the first that is left.
    ///
    /// Separators are matched *spaced* — " : " and not ":" — because
    /// "Episode 112: Monster" is one segment, not two.
    public static func showTitle(_ raw: String, host: String = "") -> String {
        var working = raw
        for separator in [" | ", " : ", " – ", " — ", " - ", " · " ] {
            working = working.replacingOccurrences(of: separator, with: "\u{1}")
        }
        let segments = working.split(separator: "\u{1}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !segments.isEmpty else { return raw }

        let site = HostKey.registrableDomain(host)?
            .split(separator: ".").first.map(String.init)?.lowercased() ?? ""
        guard !site.isEmpty else { return segments[0] }

        // Both directions: a site called "aniwaves.ru" brands itself "Aniwave",
        // and "Internet Archive" contains "archive". The length floor stops a
        // short real title being mistaken for the site name.
        let kept = segments.filter { segment in
            let lower = segment.lowercased()
            if lower.contains(site) { return false }
            if segment.count >= 4 && site.contains(lower) { return false }
            return true
        }
        return kept.first ?? segments[0]
}

    /// Episode links are often labelled with a bare number. "112" alone reads
    /// as noise in a list; "Episode 112" reads as an episode.
    public static func episodeRowLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.allSatisfy(\.isNumber) else { return trimmed }
        return "Episode \(trimmed)"
}

    /// "Episode 110" pulled out of the page title, when it is there to find.
    public static func episodeLabel(_ raw: String) -> String? {
        let pattern = #"(?i)\bep(?:isode)?\.?\s*(\d{1,4})"#
        guard let match = raw.range(of: pattern, options: .regularExpression)
        else { return nil }
        let text = raw[match]
        guard let number = text.range(of: #"\d{1,4}"#, options: .regularExpression)
        else { return nil }
        return "Episode \(text[number])"
}
}
