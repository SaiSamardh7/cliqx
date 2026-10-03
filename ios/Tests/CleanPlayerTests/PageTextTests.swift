import XCTest
@testable import CleanPlayer

final class PageTextTests: XCTestCase {
    func testOrdinaryLabelIsUnchanged() {
        XCTAssertEqual(PageText.sanitized("1080p"), "1080p")
        XCTAssertEqual(PageText.sanitized("English (CC)"), "English (CC)")
    }

    /// A label is a row in a native menu, not a paragraph.
    func testLongStringIsTruncated() {
        let long = String(repeating: "a", count: 4_000)
        let result = PageText.sanitized(long, limit: 40)
        XCTAssertEqual(result.count, 41)          // 40 + ellipsis
        XCTAssertTrue(result.hasSuffix("\u{2026}"))
    }

    /// The reason this exists: a site can make a row render as something other
    /// than what it says.
    func testBidiOverridesAreStripped() {
        let spoof = "Quality\u{202E}gnittes ngis"
        let result = PageText.sanitized(spoof)
        XCTAssertFalse(result.unicodeScalars.contains { $0.value == 0x202E })
        XCTAssertEqual(result, "Qualitygnittes ngis")
    }

    func testIsolatesAndMarksAreStripped() {
        for scalar in [0x2066, 0x2067, 0x2068, 0x2069, 0x200E, 0x200F, 0x061C] {
            let value = "a\(String(UnicodeScalar(scalar)!))b"
            XCTAssertEqual(PageText.sanitized(value), "ab",
                           "U+\(String(scalar, radix: 16)) survived")
        }
    }

    /// A realm with newlines made a three-line alert title.
    func testWhitespaceIsCollapsed() {
        XCTAssertEqual(PageText.sanitized("Media\n\n  server\tlogin"),
                       "Media server login")
        XCTAssertEqual(PageText.sanitized("   "), "")
    }

    func testTruncationDoesNotLeaveATrailingSpace() {
        XCTAssertEqual(PageText.sanitized("abcde fghij", limit: 6), "abcde\u{2026}")
    }
}
