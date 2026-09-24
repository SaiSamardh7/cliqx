import XCTest
@testable import CleanPlayer

/// A protected stream used to give a black rectangle with a full set of
/// working-looking controls and no explanation. The reason is a closed set, so
/// the sentence the user reads is written in the app and never taken from the
/// page.
final class MediaErrorTests: XCTestCase {
    func testDRMDecodes() throws {
        let message = try BridgeMessage.decode(
            body: ["v": 1, "type": "mediaError", "reason": "drm"])
        XCTAssertEqual(message, .mediaError(reason: .drm))
    }

    func testEveryReasonHasASentenceWorthReading() {
        for reason in [BridgeMessage.MediaErrorReason.drm, .unsupported, .network] {
            XCTAssertFalse(reason.message.isEmpty)
            XCTAssertGreaterThan(reason.message.count, 20, "\(reason)")
        }
    }

    /// The page picks from the set; it does not supply the words.
    func testAnUnknownReasonIsRejected() {
        XCTAssertThrowsError(try BridgeMessage.decode(
            body: ["v": 1, "type": "mediaError", "reason": "Tap here to sign in"]))
    }

    /// Only the frame holding the video may say the video failed.
    func testMediaErrorIsPlayerOnly() {
        var model = FrameCapabilityModel()
        let advert = BridgeFrame(
            id: "44444444-4444-4444-8444-444444444444",
            origin: BridgeOrigin(scheme: "https", host: "ads.example"),
            width: 1, height: 1, isVisible: true)
        model.register(advert)
        XCTAssertFalse(model.authorize(.mediaError, from: advert.id, mainOrigin: nil))
    }

    func testRoundTrip() throws {
        for reason in [BridgeMessage.MediaErrorReason.drm, .unsupported, .network] {
            let original = BridgeMessage.mediaError(reason: reason)
            let data = try JSONEncoder().encode(original)
            let object = try JSONSerialization.jsonObject(with: data)
            XCTAssertEqual(try BridgeMessage.decode(body: object), original)
        }
    }
}
