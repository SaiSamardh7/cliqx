import Foundation

/// Page-supplied text, made safe to put in native UI.
///
/// A realm string, a `<source>` label, a track name, an alert body and a page
/// title are all written by the site. Two things follow from that, and neither
/// is exotic — both are one line of HTML:
///
/// - An unbounded string fills an alert and pushes its buttons off screen, and
///   turns a native menu row into a paragraph.
/// - Bidi overrides let a string *render* as something other than what it says,
///   which is how a menu row reads "Sign in to continue" while saying anything
///   at all.
public enum PageText {
    /// Bidi controls: the embeddings and overrides, the isolates, and the two
    /// plain marks. Stripped rather than escaped — none of them belong in a
    /// label, and keeping them is what lets the render disagree with the text.
    private static let bidiControls: Set<UInt32> = Set(
        Array(0x202A...0x202E) + Array(0x2066...0x2069) + [0x200E, 0x200F, 0x061C])

    public static func sanitized(_ value: String, limit: Int = 120) -> String {
        let stripped = value.unicodeScalars.filter { !bidiControls.contains($0.value) }
        let collapsed = String(String.UnicodeScalarView(stripped))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return collapsed.prefix(limit).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}
