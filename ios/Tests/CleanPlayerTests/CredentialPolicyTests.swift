import XCTest
@testable import CleanPlayer

final class CredentialPolicyTests: XCTestCase {
    func testHTTPBasicCredentialIsSessionOnlyEvenWhenPinned() {
        let space = protectionSpace(
            protocol: "http",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic)

        XCTAssertEqual(
            CredentialPolicy.persistence(for: space, isPinnedHost: true,
                                         privateBrowsing: false),
            .forSession)
        XCTAssertEqual(
            CredentialPolicy.warning(for: space),
            CredentialPolicy.cleartextWarning)
    }

    func testHTTPSCredentialPersistsOnlyForAPinnedHost() {
        let space = protectionSpace(
            protocol: "https",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic)

        XCTAssertEqual(
            CredentialPolicy.persistence(for: space, isPinnedHost: true,
                                         privateBrowsing: false),
            .permanent)
        XCTAssertNil(CredentialPolicy.warning(for: space))
    }

    /// The finding this rule exists for: a protection space is an address, not
    /// an identity. A credential saved for 192.168.1.170 at home would be
    /// replayed to whatever answers on that address anywhere else.
    func testUnpinnedHostNeverPersists() {
        let space = protectionSpace(
            protocol: "https",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic)

        XCTAssertEqual(
            CredentialPolicy.persistence(for: space, isPinnedHost: false,
                                         privateBrowsing: false),
            .forSession)
    }

    func testPrivateBrowsingNeverPersists() {
        let space = protectionSpace(
            protocol: "https",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic)

        XCTAssertEqual(
            CredentialPolicy.persistence(for: space, isPinnedHost: true,
                                         privateBrowsing: true),
            .forSession)
    }

    /// A space the system did not build from a URL reports no protocol.
    /// Unknown is treated as insecure rather than assumed safe.
    func testUnknownProtocolIsTreatedAsCleartext() {
        let space = URLProtectionSpace(
            host: "media-server.local", port: 8096, protocol: nil,
            realm: "Media server",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic)

        XCTAssertEqual(
            CredentialPolicy.persistence(for: space, isPinnedHost: true,
                                         privateBrowsing: false),
            .forSession)
        XCTAssertEqual(
            CredentialPolicy.warning(for: space),
            CredentialPolicy.cleartextWarning)
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
