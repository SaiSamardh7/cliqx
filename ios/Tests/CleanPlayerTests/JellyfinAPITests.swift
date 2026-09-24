import XCTest
@testable import CleanPlayer

final class JellyfinAPITests: XCTestCase {
    let server = URL(string: "http://192.168.1.170:8096")!

    /// The header grammar is what the server parses first; a stray quote in
    /// a device name must not break it.
    ///
    /// The version is NOT asserted as a literal. It used to be hard-coded to
    /// "0.1" in both the source and this test, so the server's device
    /// dashboard named that build forever; it now comes from the bundle, and a
    /// test that pins a literal is the thing that let the two drift.
    func testAuthorizationHeaderShape() {
        let anonymous = JellyfinAPI.authorization(deviceID: "abc", deviceName: "Sai's \"iPhone\"")
        XCTAssertEqual(anonymous,
            "MediaBrowser Client=\"Cliqx\", Device=\"Sai's 'iPhone'\", DeviceId=\"abc\", "
            + "Version=\"\(JellyfinAPI.version)\"")
        let signedIn = JellyfinAPI.authorization(deviceID: "abc", deviceName: "iPhone", token: "tok")
        XCTAssertTrue(signedIn.hasSuffix(", Token=\"tok\""))
    }

    /// Whatever the bundle reports, it has to be a usable header value: the
    /// grammar has no escape for a quote in the version.
    func testVersionIsAPlausibleHeaderValue() {
        XCTAssertFalse(JellyfinAPI.version.isEmpty)
        XCTAssertFalse(JellyfinAPI.version.contains("\""))
        XCTAssertFalse(JellyfinAPI.version.contains(","))
    }

    func testStreamURLCarriesTokenAndAsksForNoTranscode() {
        let url = JellyfinAPI.streamURL(server: server, itemID: "item1", token: "tok")!
        XCTAssertEqual(url.absoluteString,
                       "http://192.168.1.170:8096/Videos/item1/stream?static=true&api_key=tok")
    }

    func testImageURLIsNilWithoutATag() {
        XCTAssertNil(JellyfinAPI.imageURL(server: server, itemID: "x", tag: nil))
        XCTAssertEqual(JellyfinAPI.imageURL(server: server, itemID: "x", tag: "t")?.path,
                       "/Items/x/Images/Primary")
    }

    func testEndsAtCountsOnlyWhatIsLeft() {
        let now = Date(timeIntervalSince1970: 0)
        // 100 min film, 40 min in: ends 60 min from now.
        let ends = JellyfinAPI.endsAt(runtimeTicks: 100 * 60 * 10_000_000, positionMs: 40 * 60_000, now: now)
        XCTAssertEqual(ends, now.addingTimeInterval(60 * 60))
        XCTAssertNil(JellyfinAPI.endsAt(runtimeTicks: nil, positionMs: 0, now: now))
    }

    func testImageKindPicksThePath() {
        XCTAssertEqual(JellyfinAPI.imageURL(server: server, itemID: "x", tag: "t", kind: .backdrop)?.path,
                       "/Items/x/Images/Backdrop")
    }

    func testTicksRoundTrip() {
        XCTAssertEqual(JellyfinAPI.ticks(fromMilliseconds: 1500), 15_000_000)
        XCTAssertEqual(JellyfinAPI.milliseconds(fromTicks: 15_000_000), 1500)
    }

    /// What people type versus what the API wants.
    func testServerURLFromTypedText() {
        XCTAssertEqual(JellyfinAPI.serverURL(from: "192.168.1.170:8096")?.absoluteString,
                       "http://192.168.1.170:8096/")
        XCTAssertEqual(JellyfinAPI.serverURL(from: "https://jelly.example.com/web/index.html#/home")?.absoluteString,
                       "https://jelly.example.com/")
        XCTAssertNil(JellyfinAPI.serverURL(from: "my movies"))   // a search, not a server
    }
}

// MARK: - Where the server actually lives

extension JellyfinAPITests {
    /// The bug: the path was dropped, so a server behind a reverse proxy —
    /// `example.com/jellyfin`, the usual way to expose one — could not be
    /// added at all. Every request went to the proxy's root.
    func testAServerUnderASubpathKeepsIt() {
        XCTAssertEqual(JellyfinAPI.serverURL(from: "https://example.com/jellyfin")?.absoluteString,
                       "https://example.com/jellyfin")
        XCTAssertEqual(JellyfinAPI.serverURL(from: "demo.jellyfin.org/stable")?.absoluteString,
                       "https://demo.jellyfin.org/stable")
    }

    /// The web client's own route is not the server. Someone copying an
    /// address out of a browser has all of this in it.
    func testTheWebClientsRouteIsDropped() {
        for typed in ["http://nas.local:8096/web/index.html",
                      "http://nas.local:8096/web/",
                      "http://nas.local:8096/web/index.html#/home.html"] {
            // A root-mounted server keeps its slash; appending a path to
            // either form gives the same request URL.
            XCTAssertEqual(JellyfinAPI.serverURL(from: typed)?.absoluteString,
                           "http://nas.local:8096/", "\(typed)")
        }
    }

    /// ...including when the server is under a subpath as well.
    func testASubpathServerKeepsItsPathButLosesTheWebRoute() {
        XCTAssertEqual(
            JellyfinAPI.serverURL(from: "https://example.com/jellyfin/web/index.html")?.absoluteString,
            "https://example.com/jellyfin")
    }

    /// Whichever form the root takes, the request URL is the same.
    func testBothRootFormsBuildTheSameRequestURL() {
        let root = JellyfinAPI.serverURL(from: "nas.local:8096")!
        let sub = JellyfinAPI.serverURL(from: "example.com/jellyfin")!
        XCTAssertEqual(root.appendingPathComponent("Items").absoluteString,
                       "http://nas.local:8096/Items")
        XCTAssertEqual(sub.appendingPathComponent("Items").absoluteString,
                       "https://example.com/jellyfin/Items")
    }

    func testAPlainHostIsUnchanged() {
        XCTAssertEqual(JellyfinAPI.serverURL(from: "192.168.1.170:8096")?.absoluteString,
                       "http://192.168.1.170:8096/")
    }

    func testSomethingThatIsNotAnAddressIsRefused() {
        XCTAssertNil(JellyfinAPI.serverURL(from: "not a server at all"))
    }
}
