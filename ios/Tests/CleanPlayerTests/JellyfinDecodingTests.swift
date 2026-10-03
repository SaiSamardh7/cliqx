import XCTest
@testable import CleanPlayer

/// One decoder serves every response, so a value it refuses takes the whole
/// page with it — a shelf, a library listing, or the episode list that Next
/// and Previous are built from.
final class JellyfinDecodingTests: XCTestCase {
    private struct Item: Decodable, Equatable {
        var Id: String
        var Name: String
        var EndDate: Date?
    }
    private struct Page: Decodable { var Items: [Item] }

    private func decode(_ json: String) throws -> [Item] {
        try JellyfinAPI.makeDecoder().decode(Page.self, from: Data(json.utf8)).Items
    }

    func testSevenDigitFractionalSecondsDecode() throws {
        let items = try decode("""
        {"Items":[{"Id":"1","Name":"A","EndDate":"2013-09-29T00:00:00.0000000Z"}]}
        """)
        XCTAssertEqual(items.first?.EndDate?.timeIntervalSince1970,
                       Date(timeIntervalSince1970: 1380412800).timeIntervalSince1970)
    }

    func testPlainInternetDateTimeDecodes() throws {
        let items = try decode("""
        {"Items":[{"Id":"1","Name":"A","EndDate":"2013-09-29T00:00:00Z"}]}
        """)
        XCTAssertNotEqual(items.first?.EndDate, JellyfinAPI.unparseableDate)
        XCTAssertNotNil(items.first?.EndDate)
    }

    /// The failure this tolerance exists for: a timestamp with no zone. It is
    /// accepted by neither ISO 8601 formatter, and throwing lost every item in
    /// the response rather than one field of one of them.
    func testATimestampWithNoZoneDoesNotLoseThePage() throws {
        let items = try decode("""
        {"Items":[
          {"Id":"1","Name":"A","EndDate":"2019-05-16T15:00:00.0000000"},
          {"Id":"2","Name":"B"}
        ]}
        """)
        XCTAssertEqual(items.count, 2, "one odd timestamp emptied the page")
        XCTAssertNotEqual(items[0].EndDate, JellyfinAPI.unparseableDate)
    }

    func testADateOnlyValueDecodes() throws {
        let items = try decode("""
        {"Items":[{"Id":"1","Name":"A","EndDate":"2013-09-29"}]}
        """)
        XCTAssertNotNil(items.first?.EndDate)
        XCTAssertNotEqual(items.first?.EndDate, JellyfinAPI.unparseableDate)
    }

    /// Nonsense still costs only that field.
    func testAnUnparseableDateKeepsTheRestOfTheItem() throws {
        let items = try decode("""
        {"Items":[{"Id":"1","Name":"Kept","EndDate":"not a date at all"}]}
        """)
        XCTAssertEqual(items.first?.Name, "Kept")
        XCTAssertEqual(items.first?.EndDate, JellyfinAPI.unparseableDate)
    }

    func testAMissingDateIsStillNil() throws {
        let items = try decode("""
        {"Items":[{"Id":"1","Name":"A"}]}
        """)
        XCTAssertNil(items.first?.EndDate)
    }
}
