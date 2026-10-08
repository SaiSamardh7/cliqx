import XCTest
@testable import CleanPlayer

/// The Add Server sheet reads one text field two ways: as a server to sign in
/// to, and as a stream to play. These assert the second reading keeps exactly
/// what the first one throws away.
final class StreamAddressTests: XCTestCase {

    // MARK: - What a stream URL must keep

    func testKeepsTheFilenameJellyfinParsingTrims() {
        // serverURL(from:) drops a trailing filename, because a server does not
        // live at a file. For a stream that filename IS the address.
        let text = "http://nas.local/media/The Thing.mkv"
        XCTAssertEqual(JellyfinAPI.serverURL(from: text)?.path, "/media")
        XCTAssertEqual(StreamAddress.url(from: text)?.path, "/media/The Thing.mkv")
    }

    func testKeepsTheQuery() {
        // A signed or tokenised link is useless with its query removed.
        let url = StreamAddress.url(from: "https://files.example.com/a.mp4?token=abc123")
        XCTAssertEqual(url?.query(), "token=abc123")
    }

    func testKeepsAPortAndAPathWithNoExtension() {
        // HLS endpoints are routinely extensionless.
        let url = StreamAddress.url(from: "http://10.0.0.5:8080/live/stream")
        XCTAssertEqual(url?.port, 8080)
        XCTAssertEqual(url?.path, "/live/stream")
    }

    func testPlainHostOnTheLanDefaultsToHTTP() {
        // Same reasoning as the browser: a LAN host almost never has a
        // publicly trusted certificate, and https-first would die on ATS.
        XCTAssertEqual(StreamAddress.url(from: "192.168.1.50/film.mkv")?.scheme, "http")
    }

    func testPublicHostKeepsTheSecureDefault() {
        XCTAssertEqual(StreamAddress.url(from: "files.example.com/a.mp4")?.scheme, "https")
    }

    // MARK: - What must not reach the player

    func testRejectsAPhrase() {
        // AddressResolver answers a search URL for text it cannot read as an
        // address. Handing that to VLC would fetch HTML and show nothing, so
        // the sheet must be able to tell that it is not a stream.
        XCTAssertNil(StreamAddress.url(from: "how to watch movies"))
    }

    func testRejectsASchemeTheAppDoesNotOpen() {
        XCTAssertNil(StreamAddress.url(from: "ratio:16"))
    }

    func testRejectsEmptyAndWhitespace() {
        XCTAssertNil(StreamAddress.url(from: ""))
        XCTAssertNil(StreamAddress.url(from: "   "))
    }

    func testRejectsTheSearchEngineItself() {
        // Not a special case for one engine: anything resolving to the search
        // host is the resolver saying "I could not read this".
        let engine = URL(string: "https://duckduckgo.com/")!
        XCTAssertNil(StreamAddress.url(from: "not an address at all", search: engine))
    }

    // MARK: - Naming

    func testDisplayNameIsTheFilenameWithoutExtension() {
        let url = URL(string: "http://nas.local/media/The%20Thing.mkv")!
        XCTAssertEqual(StreamAddress.displayName(for: url), "The Thing")
    }

    func testDisplayNameFallsBackToTheHost() {
        // An empty title in the player reads as a failed load.
        let url = URL(string: "http://live.example.com/")!
        XCTAssertEqual(StreamAddress.displayName(for: url), "live.example.com")
    }
}
