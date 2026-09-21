import XCTest
@testable import CleanPlayer

final class CredentialPolicyTests: XCTestCase {
    func testHTTPBasicCredentialIsSessionOnly() {
        let space = protectionSpace(
            protocol: "http",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic)

        XCTAssertEqual(
            CredentialPolicy.persistence(for: space, privateBrowsing: false),
            .forSession)
        XCTAssertEqual(
            CredentialPolicy.warning(for: space),
            CredentialPolicy.cleartextWarning)
    }

    func testHTTPSBasicCredentialMayPersist() {
        let space = protectionSpace(
            protocol: "https",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic)

        XCTAssertEqual(
            CredentialPolicy.persistence(for: space, privateBrowsing: false),
            .permanent)
        XCTAssertNil(CredentialPolicy.warning(for: space))
    }

    private func protectionSpace(
        protocol protocolName: String,
        authenticationMethod: String
    ) -> URLProtectionSpace {
        URLProtectionSpace(
            host: "media-server.local",
            port: protocolName == "http" ? 80 : 443,
            protocol: protocolName,
            realm: "Media server",
            authenticationMethod: authenticationMethod)
    }
}
