import XCTest
@testable import CleanPlayer

/// The page-world popup guard is forgeable by construction: it replaces
/// `window.open`, so it has to run in the page's own world, and any channel it
/// reports through is one the page can use too. What native CAN do is refuse a
/// total, count increments, rate-limit them, and bound what one document may
/// claim — which is what these assert.
final class PopupCountTests: XCTestCase {
    func testPopupBlockedCarriesNoCountToForge() throws {
        let message = try BridgeMessage.decode(
            body: ["v": 1, "type": "popupBlocked", "count": 9_999_999])
        // The payload is an event, not a total: the count is not part of it.
        XCTAssertEqual(message, .popupBlocked)
    }

    func testBlockedCountIsRangeChecked() {
        XCTAssertThrowsError(
            try BridgeMessage.decode(body: ["v": 1, "type": "blocked", "count": -40]))
        XCTAssertThrowsError(
            try BridgeMessage.decode(body: ["v": 1, "type": "blocked", "count": 100_001]))
    }

    /// A flood from one frame is dropped rather than turned into either a
    /// badge number or an equally expensive log.
    func testPopupFloodIsRateLimited() {
        var limiter = BridgeRateLimiter(blockedLimit: 60, interval: 1)
        let frame = "11111111-1111-4111-8111-111111111111"
        var accepted = 0
        for _ in 0..<500 where limiter.allow(.popupBlocked, from: frame, at: 10) {
            accepted += 1
        }
        XCTAssertEqual(accepted, 60)
    }

    /// One frame's flood must not silence another frame's real reports.
    func testRateLimitIsPerFrame() {
        var limiter = BridgeRateLimiter(blockedLimit: 2, interval: 1)
        let noisy = "11111111-1111-4111-8111-111111111111"
        let quiet = "22222222-2222-4222-8222-222222222222"
        for _ in 0..<10 { _ = limiter.allow(.popupBlocked, from: noisy, at: 10) }
        XCTAssertTrue(limiter.allow(.popupBlocked, from: quiet, at: 10))
    }

    /// Player state is never spectator-safe, however loud a frame is.
    func testAFrameWithoutTheaterCannotDrivePlayerState() {
        var model = FrameCapabilityModel()
        let advert = BridgeFrame(
            id: "33333333-3333-4333-8333-333333333333",
            origin: BridgeOrigin(scheme: "https", host: "ads.example"),
            width: 1, height: 1, isVisible: true)
        model.register(advert)

        XCTAssertTrue(model.authorize(.popupBlocked, from: advert.id, mainOrigin: nil))
        XCTAssertFalse(model.authorize(.time, from: advert.id, mainOrigin: nil))
        XCTAssertFalse(model.authorize(.volume, from: advert.id, mainOrigin: nil))
    }
}
