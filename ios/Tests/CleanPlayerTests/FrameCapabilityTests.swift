import XCTest
@testable import CleanPlayer

final class FrameCapabilityTests: XCTestCase {
    private let mainOrigin = BridgeOrigin(scheme: "https", host: "watch.example", port: 443)

    func testSameOriginFrameCanClaimPlayerCapability() {
        var model = FrameCapabilityModel()
        model.register(frame(
            id: "player", origin: mainOrigin, width: 320, height: 180))

        XCTAssertTrue(model.authorize(.theater, from: "player", mainOrigin: mainOrigin))
        XCTAssertEqual(model.playerFrameID, "player")
    }

    func testLargestVisibleCrossOriginFrameCanClaimPlayerCapability() {
        var model = FrameCapabilityModel()
        model.register(BridgeFrame(
            id: "main",
            origin: mainOrigin,
            width: 1920,
            height: 1080,
            isVisible: true,
            isMainFrame: true))
        model.register(frame(
            id: "ad", host: "ads.example", width: 300, height: 250))
        model.register(frame(
            id: "player", host: "embed.example", width: 1280, height: 720))

        XCTAssertTrue(model.authorize(.theater, from: "player", mainOrigin: mainOrigin))
        XCTAssertEqual(model.playerFrameID, "player")
    }

    func testSmallerCrossOriginFrameCannotClaimPlayerCapability() {
        var model = FrameCapabilityModel()
        model.register(frame(
            id: "ad", host: "ads.example", width: 300, height: 250))
        model.register(frame(
            id: "player", host: "embed.example", width: 1280, height: 720))

        XCTAssertFalse(model.authorize(.theater, from: "ad", mainOrigin: mainOrigin))
        XCTAssertNil(model.playerFrameID)
    }

    func testAdvertisementCannotReplaceActivePlayer() {
        var model = FrameCapabilityModel()
        model.register(frame(
            id: "player", origin: mainOrigin, width: 640, height: 360))
        model.register(frame(
            id: "ad", host: "ads.example", width: 1920, height: 1080))
        XCTAssertTrue(model.authorize(.theater, from: "player", mainOrigin: mainOrigin))

        XCTAssertFalse(model.authorize(.theater, from: "ad", mainOrigin: mainOrigin))
        XCTAssertEqual(model.playerFrameID, "player")
    }

    func testSpectatorMayOnlySendReadyAndBlocked() {
        var model = FrameCapabilityModel()
        model.register(frame(
            id: "player", origin: mainOrigin, width: 640, height: 360))
        model.register(frame(
            id: "spectator", host: "ads.example", width: 300, height: 250))
        XCTAssertTrue(model.authorize(.theater, from: "player", mainOrigin: mainOrigin))

        XCTAssertTrue(model.authorize(.ready, from: "spectator", mainOrigin: mainOrigin))
        XCTAssertTrue(model.authorize(.blocked, from: "spectator", mainOrigin: mainOrigin))
        XCTAssertFalse(model.authorize(.ended, from: "spectator", mainOrigin: mainOrigin))
        XCTAssertFalse(model.authorize(.playback, from: "spectator", mainOrigin: mainOrigin))
        XCTAssertTrue(model.authorize(.ended, from: "player", mainOrigin: mainOrigin))
    }

    func testResetClearsKnownFramesAndCapability() {
        var model = FrameCapabilityModel()
        model.register(frame(
            id: "player", origin: mainOrigin, width: 640, height: 360))
        XCTAssertTrue(model.authorize(.theater, from: "player", mainOrigin: mainOrigin))

        model.reset()

        XCTAssertNil(model.playerFrameID)
        XCTAssertTrue(model.knownFrames.isEmpty)
        XCTAssertFalse(model.authorize(.ended, from: "player", mainOrigin: mainOrigin))
    }

    private func frame(
        id: String,
        origin: BridgeOrigin? = nil,
        host: String = "watch.example",
        width: Int,
        height: Int
    ) -> BridgeFrame {
        BridgeFrame(
            id: id,
            origin: origin ?? BridgeOrigin(scheme: "https", host: host, port: 443),
            width: width,
            height: height,
            isVisible: true)
    }

    /// The warm standby runs its own bridge off screen, so the frame holding
    /// its video is unknown here. On promotion it IS the page: without an
    /// explicit handover every message from it is refused as a spectator and
    /// the chrome goes dead the moment an episode cuts over.
    func testPromotedStandbyFrameKeepsThePlayerCapability() {
        var model = FrameCapabilityModel()
        let promoted = BridgeFrame(
            id: "11111111-1111-4111-8111-111111111111",
            origin: BridgeOrigin(scheme: "https", host: "player.example"),
            width: 0, height: 0, isVisible: true, isMainFrame: false)

        model.adoptPlayer(promoted)

        XCTAssertTrue(model.authorize(.time, from: promoted.id, mainOrigin: nil))
        XCTAssertTrue(model.authorize(.playback, from: promoted.id, mainOrigin: nil))
        XCTAssertFalse(model.authorize(
            .time, from: "22222222-2222-4222-8222-222222222222", mainOrigin: nil))
    }
}
