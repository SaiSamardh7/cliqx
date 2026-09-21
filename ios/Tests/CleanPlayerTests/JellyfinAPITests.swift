import XCTest
@testable import CleanPlayer

final class JellyfinAPITests: XCTestCase {
    let server = URL(string: "http://192.168.1.170:8096")!

    /// The header grammar is what the server parses first; a stray quote in
    /// a device name must not break it.
    func testAuthorizationHeaderShape() {
        let anonymous = JellyfinAPI.authorization(deviceID: "abc", deviceName: "Sai's \"iPhone\"")
        XCTAssertEqual(anonymous,
            "MediaBrowser Client=\"Cliqx\", Device=\"Sai's 'iPhone'\", DeviceId=\"abc\", Version=\"0.1\"")
        let signedIn = JellyfinAPI.authorization(deviceID: "abc", deviceName: "iPhone", token: "tok")
        XCTAssertTrue(signedIn.hasSuffix(", Token=\"tok\""))
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
