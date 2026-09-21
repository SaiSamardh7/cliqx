import Foundation

public enum CredentialPolicy {
    public static let cleartextWarning =
        "This server is not using a secure connection. Your password will be sent unencrypted."

    public static func persistence(
        for protectionSpace: URLProtectionSpace,
        privateBrowsing: Bool
    ) -> URLCredential.Persistence {
        if privateBrowsing || protectionSpace.protocol?.lowercased() == "http" {
            return .forSession
        }
        return .permanent
    }

    public static func warning(for protectionSpace: URLProtectionSpace) -> String? {
        protectionSpace.protocol?.lowercased() == "http" ? cleartextWarning : nil
    }
}
