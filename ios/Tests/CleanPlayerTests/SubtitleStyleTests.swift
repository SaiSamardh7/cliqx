import XCTest
@testable import CleanPlayer

/// VLCKit has no subtitle-styling API — there is nothing in its headers about
/// size or colour — so this is a mapping onto libVLC option strings, and a
/// mapping is the kind of thing that is wrong in ways nothing catches until
/// someone looks at a screen.
final class SubtitleStyleTests: XCTestCase {
    private func value(_ style: SubtitleStyle, _ name: String) -> String? {
        style.mediaOptions
            .first { $0.hasPrefix(":\(name)=") }?
            .split(separator: "=", maxSplits: 1).last
            .map(String.init)
    }

    /// The inversion that makes this worth testing: libVLC divides the video
    /// height by this number, so BIGGER text is a SMALLER value. Getting it
    /// backwards produces a working control that does the opposite.
    func testLargerTextIsASmallerRelativeFontSize() {
        let sizes = SubtitleStyle.Size.allCases
            .map { SubtitleStyle(size: $0).mediaOptions }
            .compactMap { options in
                options.first { $0.hasPrefix(":freetype-rel-fontsize=") }
                    .flatMap { Int($0.split(separator: "=").last!) }
            }
        XCTAssertEqual(sizes.count, 4)
        XCTAssertEqual(sizes, sizes.sorted(by: >),
                       "rel-fontsize must fall as the named size grows")
    }

    /// libVLC takes a decimal number, not "#FFFF00" and not "yellow".
    func testColourIsTheDecimalOfAnRGBTriple() {
        XCTAssertEqual(value(SubtitleStyle(colour: .white), "freetype-color"),
                       String(16_777_215))
        XCTAssertEqual(value(SubtitleStyle(colour: .yellow), "freetype-color"),
                       String(16_776_960))
    }

    func testOutlineIsOffWhenNotWanted() {
        let plain = SubtitleStyle(outline: false)
        XCTAssertEqual(value(plain, "freetype-outline-thickness"), "0")
        XCTAssertNil(value(plain, "freetype-outline-color"))

        let outlined = SubtitleStyle(outline: true)
        XCTAssertNotEqual(value(outlined, "freetype-outline-thickness"), "0")
        XCTAssertEqual(value(outlined, "freetype-outline-color"), "0")
    }

    /// Opacity 0 is what "no band" means; leaving the option out entirely
    /// would let whatever the renderer last used stand.
    func testTheBackgroundBandIsExplicitlyOffByDefault() {
        XCTAssertEqual(value(SubtitleStyle(), "freetype-background-opacity"), "0")
        XCTAssertEqual(value(SubtitleStyle(background: true), "freetype-background-opacity"),
                       "170")
    }

    /// Media options carry a leading colon; player options a double dash.
    /// Using the wrong prefix is silently ignored rather than rejected.
    func testTheTwoFormsCarryTheirOwnPrefixes() {
        let style = SubtitleStyle(background: true)
        for option in style.mediaOptions {
            XCTAssertTrue(option.hasPrefix(":"), option)
            XCTAssertFalse(option.hasPrefix("::"), option)
            XCTAssertTrue(option.contains("="), option)
        }
        for option in style.playerOptions {
            XCTAssertTrue(option.hasPrefix("--"), option)
            XCTAssertTrue(option.contains("="), option)
        }
    }

    /// The colour and the band only take effect when given to the PLAYER —
    /// measured, after a build where they were on the media and did nothing.
    /// So they must be in that list, whatever else changes.
    func testThePlayerFormCarriesColourAndBackground() {
        let style = SubtitleStyle(colour: .yellow, background: true)
        XCTAssertTrue(style.playerOptions.contains("--freetype-color=16776960"))
        XCTAssertTrue(style.playerOptions.contains("--freetype-background-opacity=170"))
        XCTAssertTrue(style.playerOptions.contains { $0.hasPrefix("--freetype-rel-fontsize=") })
    }

    /// Both forms describe the same settings; only the prefix differs.
    func testTheFormsAgree() {
        let style = SubtitleStyle(size: .large, colour: .cyan, outline: false, background: true)
        let media = Set(style.mediaOptions.map { String($0.dropFirst(1)) })
        let player = Set(style.playerOptions.map { String($0.dropFirst(2)) })
        XCTAssertEqual(media, player)
    }

    func testItSurvivesARoundTrip() throws {
        let style = SubtitleStyle(size: .extraLarge, colour: .cyan,
                                  outline: false, background: true)
        let data = try JSONEncoder().encode(style)
        XCTAssertEqual(try JSONDecoder().decode(SubtitleStyle.self, from: data), style)
    }
}
