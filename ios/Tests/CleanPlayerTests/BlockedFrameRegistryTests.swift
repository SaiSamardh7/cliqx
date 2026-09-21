import XCTest
@testable import CleanPlayer

final class BlockedFrameRegistryTests: XCTestCase {
    func testTotalsCountsAcrossFrames() {
        var registry = BlockedFrameRegistry()

        registry.update(frameID: "one", count: 2)
        registry.update(frameID: "two", count: 2)
        registry.update(frameID: "three", count: 2)

        XCTAssertEqual(registry.total, 6)
    }

    func testZeroFromAnotherFrameDoesNotEraseTheTotal() {
        var registry = BlockedFrameRegistry()
        registry.update(frameID: "one", count: 2)
        registry.update(frameID: "two", count: 2)
        registry.update(frameID: "three", count: 2)

        registry.update(frameID: "four", count: 0)

        XCTAssertEqual(registry.total, 6)
    }

    func testRemovingFrameRemovesItsCount() {
        var registry = BlockedFrameRegistry()
        registry.update(frameID: "one", count: 2)
        registry.update(frameID: "two", count: 2)
        registry.update(frameID: "three", count: 2)

        registry.remove(frameID: "two")

        XCTAssertEqual(registry.total, 4)
        XCTAssertEqual(registry.frameIDs, ["one", "three"])
    }

    func testZeroAllPreservesFrameAddresses() {
        var registry = BlockedFrameRegistry()
        registry.update(frameID: "one", count: 3)
        registry.update(frameID: "two", count: 4)

        registry.zeroAll()

        XCTAssertEqual(registry.total, 0)
        XCTAssertEqual(registry.frameIDs, ["one", "two"])
    }
}
