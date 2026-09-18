import XCTest
@testable import CleanPlayer

/// Page titles as real sites actually write them.
final class PlayerFormattingTests: XCTestCase {
    // The first version took everything before the first separator. On the page
    // it was written against that returned "Aniwave" — the site's own name.
    func testPullsTheShowNameOutOfARealTitle() {
        XCTAssertEqual(
            PlayerFormatting.showTitle(
                "Aniwave - Hunter x Hunter (2011) — Episode 112: Monster × A…",
                host: "aniwaves.ru"),
            "Hunter x Hunter (2011)")

        XCTAssertEqual(
            PlayerFormatting.showTitle(
                "Big Buck Bunny : Free Download, Borrow, and Streaming : Internet Archive",
                host: "archive.org"),
            "Big Buck Bunny")
    }

    /// The site name sits on the left as often as the right, and "aniwaves.ru"
    /// brands itself "Aniwave" while "Internet Archive" contains "archive" —
    /// so neither direction of containment alone is enough.
    func testDropsTheSiteNameFromEitherEnd() {
        XCTAssertEqual(
            PlayerFormatting.showTitle("Watch Free HD | ExampleSite",
                                       host: "examplesite.com"),
            "Watch Free HD")
        XCTAssertEqual(
            PlayerFormatting.showTitle("ExampleSite | Watch Free HD",
                                       host: "examplesite.com"),
            "Watch Free HD")
    }

    /// "Episode 112: Monster" is one segment. Splitting on a bare colon would
    /// cut the episode name in half.
    func testUnspacedColonIsNotASeparator() {
        XCTAssertEqual(
            PlayerFormatting.showTitle("Episode 112: Monster", host: "example.com"),
            "Episode 112: Monster")
    }

    func testFallsBackRatherThanShowingNothing() {
        XCTAssertEqual(PlayerFormatting.showTitle("", host: "example.com"), "")
        // Every segment looks like the site name: better the raw title than a
        // blank title bar.
        XCTAssertEqual(
            PlayerFormatting.showTitle("Example | Example", host: "example.com"),
            "Example")
        XCTAssertEqual(PlayerFormatting.showTitle("Plain Title", host: ""),
                       "Plain Title")
    }

    func testEpisodeNumberIsReadOutOfTheTitle() {
        XCTAssertEqual(PlayerFormatting.episodeLabel("… — Episode 112: Monster"),
                       "Episode 112")
        XCTAssertEqual(PlayerFormatting.episodeLabel("Show Ep.5 sub"), "Episode 5")
        XCTAssertNil(PlayerFormatting.episodeLabel("A film with no episodes"))
    }

    func testSeriesTitleRemovesTheEpisodeButKeepsTheShow() {
        XCTAssertEqual(PlayerFormatting.seriesTitle("Naruto — Episode 10", host: "watch.test"),
                       "Naruto")
        XCTAssertEqual(PlayerFormatting.seriesTitle("Naruto Ep.5 English Sub", host: "watch.test"),
                       "Naruto")
        XCTAssertEqual(PlayerFormatting.seriesTitle("Episode 8 - Naruto", host: "watch.test"),
                       "Naruto")
        XCTAssertNil(PlayerFormatting.seriesTitle("Episode 8", host: "watch.test"))
    }

    func testEpisodesOfOneSeriesShareARecentIdentity() {
        let five = URL(string: "https://watch.test/naruto/episode-5")!
        let ten = URL(string: "https://watch.test/naruto/episode-10")!
        XCTAssertEqual(
            PlayerFormatting.seriesIdentity(title: "Naruto Episode 5", url: five),
            PlayerFormatting.seriesIdentity(title: "Naruto Episode 10", url: ten))
        XCTAssertNotEqual(
            PlayerFormatting.seriesIdentity(title: "Naruto Episode 10", url: ten),
            PlayerFormatting.seriesIdentity(
                title: "One Piece Episode 10",
                url: URL(string: "https://watch.test/one-piece/episode-10")!))
    }

    /// Episode links on real sites are commonly labelled with a bare number.
    func testBareNumbersReadAsEpisodes() {
        XCTAssertEqual(PlayerFormatting.episodeRowLabel("112"), "Episode 112")
        XCTAssertEqual(PlayerFormatting.episodeRowLabel(" 7 "), "Episode 7")
        XCTAssertEqual(PlayerFormatting.episodeRowLabel("Episode 3 - Trouble"),
                       "Episode 3 - Trouble")
    }

    func testTimecodeOnlyShowsHoursWhenThereAreSome() {
        XCTAssertEqual(PlayerFormatting.timecode(0), "0:00")
        XCTAssertEqual(PlayerFormatting.timecode(65), "1:05")
        XCTAssertEqual(PlayerFormatting.timecode(596), "9:56")
        XCTAssertEqual(PlayerFormatting.timecode(3661), "1:01:01")
        XCTAssertEqual(PlayerFormatting.timecode(.nan), "0:00")
        XCTAssertEqual(PlayerFormatting.timecode(-5), "0:00")
    }

    func testSpeedLabelsReadCleanly() {
        XCTAssertEqual(PlayerFormatting.rateText(1), "1")
        XCTAssertEqual(PlayerFormatting.rateText(2), "2")
        XCTAssertEqual(PlayerFormatting.rateText(1.5), "1.5")
        XCTAssertEqual(PlayerFormatting.rateText(0.75), "0.75")
    }
}
