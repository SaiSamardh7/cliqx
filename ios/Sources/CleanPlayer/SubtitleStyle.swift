import Foundation

/// How subtitles are drawn by the VLC text renderer.
///
/// VLCKit exposes no API for this — there is nothing in its headers about
/// subtitle size or colour. What it does expose is libVLC's option system, and
/// the renderer reads `freetype-*` options from there. So this type's whole
/// job is to turn choices a person makes into those option strings, which is
/// exactly the kind of mapping that is easy to get subtly wrong and easy to
/// test.
public struct SubtitleStyle: Codable, Equatable, Sendable {
    /// Relative to the video's height, and INVERTED: libVLC divides the video
    /// height by this, so a smaller number means bigger text. Naming the cases
    /// rather than exposing the number keeps that inversion in one place.
    public enum Size: String, Codable, CaseIterable, Sendable {
        case small, medium, large, extraLarge

        public var title: String {
            switch self {
            case .small: "Small"
            case .medium: "Medium"
            case .large: "Large"
            case .extraLarge: "Extra Large"
            }
        }

        /// `freetype-rel-fontsize`. libVLC's own default is 16.
        var relativeFontSize: Int {
            switch self {
            case .small: 20
            case .medium: 16
            case .large: 12
            case .extraLarge: 8
            }
        }
    }

    /// The colours worth offering. White and yellow are what people actually
    /// use; the rest are for legibility against particular footage.
    public enum Colour: String, Codable, CaseIterable, Sendable {
        case white, yellow, cyan, green, magenta

        public var title: String {
            switch self {
            case .white: "White"
            case .yellow: "Yellow"
            case .cyan: "Cyan"
            case .green: "Green"
            case .magenta: "Magenta"
            }
        }

        /// `freetype-color`, as the decimal of an RGB triple — which is how
        /// libVLC takes it, not as hex and not as a name.
        var rgb: Int {
            switch self {
            case .white: 0xFFFFFF
            case .yellow: 0xFFFF00
            case .cyan: 0x00FFFF
            case .green: 0x00FF00
            case .magenta: 0xFF00FF
            }
        }
    }

    public var size: Size
    public var colour: Colour
    /// A dark outline is what makes white text readable over a bright scene.
    public var outline: Bool
    /// A translucent band behind the text, for footage an outline cannot save.
    public var background: Bool

    public init(size: Size = .medium, colour: Colour = .white,
                outline: Bool = true, background: Bool = false) {
        self.size = size
        self.colour = colour
        self.outline = outline
        self.background = background
    }

    /// The settings, without the prefix that decides where they apply.
    private var settings: [(String, Int)] {
        var values: [(String, Int)] = [
            ("freetype-rel-fontsize", size.relativeFontSize),
            ("freetype-color", colour.rgb),
            ("freetype-opacity", 255),
            // Thickness is in pixels, 0 being none. The outline colour is set
            // explicitly rather than left to whatever was there before.
            ("freetype-outline-thickness", outline ? 4 : 0),
            // 0 is transparent, so the band is off unless it is asked for.
            ("freetype-background-opacity", background ? 170 : 0),
        ]
        if outline {
            values.append(("freetype-outline-color", 0))
            values.append(("freetype-outline-opacity", 255))
        }
        if background { values.append(("freetype-background-color", 0)) }
        return values
    }

    /// Options for the PLAYER, which is where these have to go.
    ///
    /// Measured, not assumed: attached to the media, `freetype-rel-fontsize`
    /// takes effect and `freetype-color` and `freetype-background-opacity`
    /// silently do not — the text resizes and stays white. Given to the player
    /// at construction, all of them apply. A build that set them on the media
    /// would have shipped a working size control and two dead ones.
    ///
    /// The consequence is that a change takes effect on the next video rather
    /// than the one playing, because a player's options are fixed when it is
    /// made. Both players here are built per playback, so that is one video,
    /// not a relaunch — and the settings screen says so.
    public var playerOptions: [String] {
        settings.map { "--\($0.0)=\($0.1)" }
    }

    /// The same values in the form libVLC wants on a single item. Only the
    /// size is known to work here; kept because it costs nothing and means a
    /// media built before the player's options are read still gets it right.
    public var mediaOptions: [String] {
        settings.map { ":\($0.0)=\($0.1)" }
    }
}
