import CoreGraphics
import XCTest
@testable import CleanPlayer

/// A snapshot with no picture in it must not become a poster, or the library
/// shows a blank tile where the monogram belongs.
final class PosterFrameTests: XCTestCase {
    /// `fill` is called with each pixel's x and y and returns its grey level.
    private func image(_ side: Int = 64,
                       fill: (Int, Int) -> UInt8) throws -> CGImage {
        var pixels = [UInt8]()
        for y in 0..<side {
            for x in 0..<side {
                let value = fill(x, y)
                pixels.append(contentsOf: [value, value, value, 255])
            }
        }
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }

    /// What a staged video actually snapshots as.
    func testASolidBlackFrameIsNotAPoster() throws {
        XCTAssertFalse(PosterFrame.carriesPicture(try image { _, _ in 0 }))
    }

    func testASolidWhiteFrameIsNotAPosterEither() throws {
        XCTAssertFalse(PosterFrame.carriesPicture(try image { _, _ in 255 }))
    }

    func testAFrameWithContentIsAPoster() throws {
        XCTAssertTrue(PosterFrame.carriesPicture(try image { x, _ in UInt8(x * 4 % 256) }))
    }

    /// A night scene is dark and still varies across the frame. Darkness is
    /// not the test; flatness is.
    func testADarkButRealFrameIsKept() throws {
        XCTAssertTrue(PosterFrame.carriesPicture(
            try image { _, y in UInt8(2 + y / 2) }))
    }

    /// Nearly flat, within sampling noise of one colour: still not a picture.
    func testANearlyFlatFrameIsRefused() throws {
        XCTAssertFalse(PosterFrame.carriesPicture(
            try image { x, _ in x < 32 ? 10 : 13 }))
    }
}
