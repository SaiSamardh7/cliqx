import Foundation

public enum EpisodeDirection: String, Sendable {
    case next
    case previous
}

/// The security and page-world pieces of an episode handoff.
public enum EpisodeTransition {
    /// JavaScript intentionally evaluated in `WKContentWorld.page`: calling
    /// `click()` there invokes the event listeners installed by the website.
    /// The private app content world shares the DOM, but not the page's JS
    /// environment, which is the distinction that caused direct navigation.
    public static func siteControlScript(for direction: EpisodeDirection) -> String {
        let selector = switch direction {
        case .next:
            ".ctrl.forward.next, [data-action='next-episode'], [data-testid='next-episode']"
        case .previous:
            ".ctrl.forward.prev, [data-action='previous-episode'], [data-testid='previous-episode']"
        }
        return """
        (() => {
          const control = document.querySelector(\(javascriptString(selector)));
          if (!control) return false;
          control.click();
          return true;
        })()
        """
    }

    /// Canonical paths may change during the site's AJAX handoff. The resume
    /// remains valid only while WebKit is still on the same registrable site.
    public static func mayResume(expected: URL, current: URL) -> Bool {
        guard ["http", "https"].contains(expected.scheme?.lowercased() ?? ""),
              ["http", "https"].contains(current.scheme?.lowercased() ?? "")
        else { return false }
        return HostKey.isSameSite(current, as: expected)
    }

    /// Playback from the outgoing iframe is stale until that frame proves its
    /// staged video actually changed source. A replacement iframe completes by
    /// sending `theater`, so it never needs this fallback.
    public static func playbackCompletesResume(isFromOutgoingFrame: Bool,
                                               outgoingSourceChanged: Bool) -> Bool {
        !isFromOutgoingFrame || outgoingSourceChanged
    }

    private static func javascriptString(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}
