import XCTest
@testable import CleanPlayer

final class HostileFrameTests: XCTestCase {
    private let mainOrigin = BridgeOrigin(
        scheme: "https", host: "watch.example", port: 443)

    func testAdvertisementCannotClaimTheaterWhilePlayerHoldsCapability() {
        var capabilities = FrameCapabilityModel()
        capabilities.register(frame(
            id: "player", host: "watch.example", width: 1280, height: 720))
        capabilities.register(frame(
            id: "advertisement", host: "ads.example", width: 300, height: 250))

        XCTAssertTrue(capabilities.authorize(
            .theater, from: "player", mainOrigin: mainOrigin))
        XCTAssertFalse(capabilities.authorize(
            .theater, from: "advertisement", mainOrigin: mainOrigin))
        XCTAssertEqual(capabilities.playerFrameID, "player")
    }

    func testSpectatorEndedMessageCannotChangePlaybackState() {
        var capabilities = FrameCapabilityModel()
        capabilities.register(frame(
            id: "player", host: "watch.example", width: 1280, height: 720))
        capabilities.register(frame(
            id: "spectator", host: "ads.example", width: 300, height: 250))
        XCTAssertTrue(capabilities.authorize(
            .theater, from: "player", mainOrigin: mainOrigin))
        var isPlaying = true

        if capabilities.authorize(
            .ended, from: "spectator", mainOrigin: mainOrigin) {
            isPlaying = false
        }

        XCTAssertTrue(isPlaying)
    }

    func testTenThousandBlockedMessagesAreRateLimited() {
        var limiter = BridgeRateLimiter(blockedLimit: 60, interval: 1)
        var accepted = 0

        for _ in 0..<10_000 {
            if limiter.allow(.blocked, from: "advertisement", at: 10) {
                accepted += 1
            }
        }

        XCTAssertEqual(accepted, 60)
    }

    func testOneMegabyteStringIsRejectedDuringDecode() throws {
        let payload = envelope(
            type: "airplay",
            fields: ["available": true, "source": String(repeating: "x", count: 1_048_576)])

        XCTAssertThrowsError(try BridgeEnvelope.decode(body: payload)) { error in
            XCTAssertEqual(
                error as? BridgeMessage.ValidationError,
                .stringTooLong(field: "source"))
        }
    }

    func testNavigatingFrameRemovesOnlyItsBlockedCount() {
        var registry = BlockedFrameRegistry()
        registry.update(frameID: "player", count: 2)
        registry.update(frameID: "advertisement", count: 4)

        registry.remove(frameID: "advertisement")

        XCTAssertEqual(registry.total, 2)
        XCTAssertEqual(registry.frameIDs, ["player"])
    }

    func testMissingAndUnknownProtocolVersionsAreRejected() throws {
        var missing = envelope(type: "ready")
        missing.removeValue(forKey: "v")
        XCTAssertThrowsError(try BridgeEnvelope.decode(body: missing))

        let unknown = envelope(type: "ready", version: 99)
        XCTAssertThrowsError(try BridgeEnvelope.decode(body: unknown)) { error in
            XCTAssertEqual(
                error as? BridgeMessage.ValidationError,
                .unsupportedVersion(99))
        }
    }

    private func envelope(
        type: String,
        version: Int = 1,
        fields: [String: Any] = [:]
    ) -> [String: Any] {
        var body = fields
        body["v"] = version
        body["fid"] = "01234567-89ab-4def-8123-456789abcdef"
        body["type"] = type
        return body
    }

    private func frame(
        id: String,
        host: String,
        width: Int,
        height: Int
    ) -> BridgeFrame {
        BridgeFrame(
            id: id,
            origin: BridgeOrigin(scheme: "https", host: host, port: 443),
            width: width,
            height: height,
            isVisible: true)
    }
}
