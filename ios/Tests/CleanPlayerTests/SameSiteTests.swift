import XCTest
@testable import CleanPlayer

/// Two definitions of "same site" lived in one feature: the agent compared
/// origins, native compared registrable domains. A site serving its player
/// from one subdomain and its episodes from another got an empty episode list
/// from the agent, while the very same URLs passed native's check when a
/// navigation was attempted.
final class SameSiteTests: XCTestCase {
    private func url(_ string: String) -> URL { URL(string: string)! }

    func testSubdomainsOfOneSiteMatch() {
        XCTAssertTrue(HostKey.isSameSite(url("https://player.example.com/x"),
                                         as: url("https://www.example.com/watch")))
        XCTAssertTrue(HostKey.isSameSite(url("https://example.com/x"),
                                         as: url("https://cdn.example.com/watch")))
    }

    func testDifferentSitesDoNotMatch() {
        XCTAssertFalse(HostKey.isSameSite(url("https://elsewhere.com/x"),
                                          as: url("https://example.com/watch")))
        XCTAssertFalse(HostKey.isSameSite(url("https://notexample.com/x"),
                                          as: url("https://example.com/watch")))
    }

    /// The reason the agent cannot do this itself. A naive suffix rule calls
    /// these the same site; the Public Suffix List does not.
    func testTenantsOnASharedSuffixAreSeparateSites() {
        XCTAssertFalse(HostKey.isSameSite(url("https://evil.github.io/x"),
                                          as: url("https://good.github.io/watch")))
        XCTAssertFalse(HostKey.isSameSite(url("https://a.co.uk/x"),
                                          as: url("https://b.co.uk/watch")))
    }

    func testRegistrableDomainIsWhatTheAgentIsHanded() {
        XCTAssertEqual(HostKey.registrableDomain("player.example.com"), "example.com")
        XCTAssertEqual(HostKey.registrableDomain("www.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(HostKey.registrableDomain("good.github.io"), "good.github.io")
    }

    /// The agent's rule, expressed here so both halves are pinned in one place:
    /// equal to the site, or a label-boundary subdomain of it.
    func testTheAgentsSuffixRuleMatchesWhatNativeWouldAccept() {
        let site = HostKey.registrableDomain("www.example.com")!
        func agentWouldAccept(_ host: String) -> Bool {
            host == site || host.hasSuffix("." + site)
        }
        for host in ["example.com", "www.example.com", "player.example.com"] {
            XCTAssertTrue(agentWouldAccept(host), host)
            XCTAssertTrue(HostKey.isSameSite(url("https://\(host)/x"),
                                             as: url("https://www.example.com/w")), host)
        }
        for host in ["notexample.com", "example.com.evil.test", "elsewhere.com"] {
            XCTAssertFalse(agentWouldAccept(host), host)
            XCTAssertFalse(HostKey.isSameSite(url("https://\(host)/x"),
                                              as: url("https://www.example.com/w")), host)
        }
    }
}
