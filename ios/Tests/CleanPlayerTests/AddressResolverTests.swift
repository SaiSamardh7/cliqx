import XCTest
@testable import CleanPlayer

/// The address bar is the one place a user hands the browser arbitrary text, so
/// every branch here is either a navigation or a decision not to make one.
final class AddressResolverTests: XCTestCase {

    private func resolve(_ text: String) -> URL? {
        AddressResolver.resolve(text)
    }

    func testWebURLsArePassedThroughUnchanged() {
        XCTAssertEqual(resolve("https://example.com/watch?v=1")?.absoluteString,
                       "https://example.com/watch?v=1")
        XCTAssertEqual(resolve("http://example.com")?.absoluteString,
                       "http://example.com")
    }

    func testBareHostsBecomeHTTPS() {
        XCTAssertEqual(resolve("example.com")?.absoluteString,
                       "https://example.com")
        XCTAssertEqual(resolve("  archive.org  ")?.absoluteString,
                       "https://archive.org")
    }

    func testEmptyInputGoesNowhere() {
        XCTAssertNil(resolve(""))
        XCTAssertNil(resolve("   \n "))
    }

    func testWordsBecomeASearch() {
        let url = resolve("big buck bunny")
        XCTAssertEqual(url?.host(), "duckduckgo.com")
        XCTAssertEqual(URLComponents(url: url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "q" }?.value, "big buck bunny")
    }

    /// A non-web scheme used to return nil, which made `submitAddress` do
    /// nothing at all: no navigation, no search, no message. Anything with a
    /// colon in it — "ratio:16", "note:buy milk" — hit that path.
    func testNonWebSchemesBecomeASearchRatherThanSilence() {
        for text in ["ratio:16", "note:buy milk", "mailto:someone@example.com"] {
            let url = resolve(text)
            XCTAssertEqual(url?.host(), "duckduckgo.com",
                           "\(text) should have become a search")
        }
    }

    /// The important half of the rule above: a scheme that is not http(s) must
    /// never be handed onwards as a URL to open.
    func testDangerousSchemesAreNeverReturnedAsNavigations() {
        for text in ["javascript:alert(1)", "file:///etc/passwd",
                     "data:text/html,<script>x</script>", "ftp://example.com"] {
            let url = resolve(text)
            XCTAssertNotEqual(url?.scheme?.lowercased(), "javascript")
            XCTAssertNotEqual(url?.scheme?.lowercased(), "file")
            XCTAssertNotEqual(url?.scheme?.lowercased(), "data")
            XCTAssertNotEqual(url?.scheme?.lowercased(), "ftp")
            // Whatever it becomes, it is a search on the web engine.
            XCTAssertEqual(url?.host(), "duckduckgo.com",
                           "\(text) escaped as something openable")
        }
    }

    /// A dot is not enough on its own — "3.5" is a number, not a host.
    func testSomethingWithATooShortSuffixIsSearched() {
        XCTAssertEqual(resolve("3.5")?.host(), "duckduckgo.com")
    }

    // A home server on the LAN has no publicly trusted certificate, so
    // https-first guarantees an ATS failure. Measured against a real Jellyfin
    // box: typing its address landed on https and died on the certificate.
    func testAPrivateAddressDefaultsToHTTP() {
        XCTAssertEqual(resolve("192.168.1.170")?.scheme, "http")
        XCTAssertEqual(resolve("192.168.1.170:8096")?.scheme, "http")
        XCTAssertEqual(resolve("192.168.1.170:8096")?.port, 8096)
        XCTAssertEqual(resolve("10.0.0.5")?.scheme, "http")
        XCTAssertEqual(resolve("172.16.4.9")?.scheme, "http")
        XCTAssertEqual(resolve("nas.local")?.scheme, "http")
        XCTAssertEqual(resolve("localhost:8096")?.scheme, "http")
        XCTAssertEqual(resolve("localhost:8096")?.host(), "localhost")
    }

    /// Only the private ranges. A public address keeps the secure default.
    func testAPublicHostStillDefaultsToHTTPS() {
        XCTAssertEqual(resolve("example.com")?.scheme, "https")
        XCTAssertEqual(resolve("8.8.8.8")?.scheme, "https")
        XCTAssertEqual(resolve("172.32.0.1")?.scheme, "https")
        XCTAssertEqual(resolve("193.168.1.1")?.scheme, "https")
    }

    /// An explicit scheme is always obeyed, local or not.
    func testAnExplicitSchemeIsKept() {
        XCTAssertEqual(resolve("https://192.168.1.170")?.scheme, "https")
        XCTAssertEqual(resolve("http://example.com")?.scheme, "http")
    }

    /// Pinning from the browser keeps the server, not the route. A media
    /// server's watch page is a hash route that opens to nothing on its own.
    func testSiteRootKeepsSchemeHostAndPortOnly() {
        XCTAssertEqual(
            AddressResolver.siteRoot(of: URL(string: "http://192.168.1.170:8096/web/index.html#/video")!)?
                .absoluteString,
            "http://192.168.1.170:8096/")
        XCTAssertEqual(
            AddressResolver.siteRoot(of: URL(string: "https://nas.example.com/watch?v=1")!)?
                .absoluteString,
            "https://nas.example.com/")
        XCTAssertNil(AddressResolver.siteRoot(of: URL(string: "about:blank")!))
    }

    func testTheSearchEngineIsNotHardcodedIntoTheCaller() {
        let engine = URL(string: "https://example.org/find")!
        let url = AddressResolver.resolve("hello", search: engine)
        XCTAssertEqual(url?.host(), "example.org")
        XCTAssertEqual(url?.path(), "/find")
    }

    // MARK: Resume key

    /// One episode, five URLs. They have to land on one saved position.
    func testResumeKeyIgnoresTheWaysASiteDressesUpTheSameURL() {
        let key = { AddressResolver.resumeKey(for: URL(string: $0)!) }
        let expected = key("https://example.com/watch/ep-4")
        XCTAssertEqual(key("http://www.example.com/watch/ep-4/"), expected)
        XCTAssertEqual(key("https://example.com/watch/ep-4?utm_source=x&fbclid=y"), expected)
        XCTAssertEqual(key("https://EXAMPLE.com/watch/ep-4?t=120"), expected)
        XCTAssertEqual(key("https://example.com/watch/ep-4?si=abc&start=30"), expected)
    }

    /// Things that DO identify a different video survive: a real query
    /// parameter, a hash route, a port.
    func testResumeKeyKeepsWhatIdentifiesTheVideo() {
        let key = { AddressResolver.resumeKey(for: URL(string: $0)!) }
        XCTAssertNotEqual(key("https://example.com/watch?v=abc"), key("https://example.com/watch?v=def"))
        XCTAssertNotEqual(key("http://nas.local:8096/web/#/video?id=1"),
                          key("http://nas.local:8096/web/#/video?id=2"))
        XCTAssertNotEqual(key("http://nas.local:8096/"), key("http://nas.local:8920/"))
    }
}
