import Foundation

/// When a password typed into an HTTP auth prompt may outlive the session.
///
/// Three conditions, all required, because each rules out a different way a
/// saved credential is replayed at something the user did not mean:
///
/// - **Pinned.** WebKit replays a permanent credential to any host matching the
///   protection space, and a protection space is an address, not an identity.
///   `192.168.1.170` is a different machine on every network, so a NAS password
///   saved at home would be offered to whatever answers on that address at an
///   airport. Pinning is the only signal that a server is the user's own.
/// - **HTTPS.** A cleartext credential is readable by the network, so it is
///   never written to the keychain, and the prompt says so.
/// - **Not private browsing.** Nothing outlives the session there.
public enum CredentialPolicy {
    public static let cleartextWarning =
        "This server is not using a secure connection. Your password will be sent unencrypted."

    public static func persistence(
        for protectionSpace: URLProtectionSpace,
        isPinnedHost: Bool,
        privateBrowsing: Bool
    ) -> URLCredential.Persistence {
        guard isPinnedHost, !privateBrowsing, isSecure(protectionSpace) else {
            return .forSession
        }
        return .permanent
    }

    public static func warning(for protectionSpace: URLProtectionSpace) -> String? {
        isSecure(protectionSpace) ? nil : cleartextWarning
    }

    /// `protocol` is nil for a space the system did not build from a URL.
    /// Treated as insecure: the safe answer when the scheme is unknown.
    private static func isSecure(_ protectionSpace: URLProtectionSpace) -> Bool {
        protectionSpace.protocol?.lowercased() == "https"
    }
}
