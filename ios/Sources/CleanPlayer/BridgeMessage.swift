import Foundation

/// Versioned messages accepted from the page agent.
///
/// The page is untrusted input. Decoding therefore rejects missing fields,
/// unknown message kinds, non-finite numbers, and values outside the limits
/// below before the app mutates any state.
public enum BridgeMessage: Codable, Equatable, Sendable {
    public static let protocolVersion = 1
    public static let maximumStringLength = 2_048

    public struct MediaChoice: Codable, Equatable, Sendable {
        public let index: Int
        public let label: String
        public let active: Bool
    }

    public struct VideoInfo: Codable, Equatable, Sendable {
        public let height: Int
        public let width: Int
        public let fit: String
        public let sources: [MediaChoice]
    }

    public enum ValidationError: Error, Equatable, LocalizedError {
        case malformedPayload
        case unsupportedVersion(Int)
        case unknownType(String)
        case stringTooLong(field: String)
        case numberOutOfRange(field: String)
        case tooManyItems(field: String)

        public var errorDescription: String? {
            switch self {
            case .malformedPayload:
                "The payload is not a JSON object."
            case .unsupportedVersion(let version):
                "Unsupported bridge protocol version: \(version)."
            case .unknownType(let type):
                "Unknown bridge message type: \(type)."
            case .stringTooLong(let field):
                "Bridge field \(field) exceeds \(BridgeMessage.maximumStringLength) characters."
            case .numberOutOfRange(let field):
                "Bridge field \(field) is outside its accepted range."
            case .tooManyItems(let field):
                "Bridge field \(field) contains too many items."
            }
        }
    }

    case ready
    case frameGone
    case theater(airplay: Bool, pip: Bool)
    case theaterEnded
    case theaterFailed
    case ended
    case watchCleanTapped
    case blocked(count: Int)
    case popupBlocked
    case playback(playing: Bool, buffering: Bool, armed: Bool)
    case episodeSourceChanged(playing: Bool)
    case volume(percent: Int, boosted: Bool, available: Bool)
    case time(at: Double, duration: Double, live: Bool, buffered: Double, rate: Double)
    case video(info: VideoInfo)
    case tracks([MediaChoice])
    case airplay(available: Bool, source: String)
    case airplaySupport(picker: Bool, source: String)

    public var kind: BridgeMessageKind {
        switch self {
        case .ready: .ready
        case .frameGone: .frameGone
        case .theater: .theater
        case .theaterEnded: .theaterEnded
        case .theaterFailed: .theaterFailed
        case .ended: .ended
        case .watchCleanTapped: .watchCleanTapped
        case .blocked: .blocked
        case .popupBlocked: .popupBlocked
        case .playback: .playback
        case .episodeSourceChanged: .episodeSourceChanged
        case .volume: .volume
        case .time: .time
        case .video: .video
        case .tracks: .tracks
        case .airplay: .airplay
        case .airplaySupport: .airplaySupport
        }
    }

    private static let maximumCollectionCount = 1_000
    private static let maximumMediaIndex = 100_000
    private static let maximumMediaDimension = 32_768
    private static let maximumMediaTime = 31_536_000.0

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case type
        case airplay
        case pip
        case count
        case playing
        case buffering
        case armed
        case percent
        case boosted
        case available
        case at
        case duration
        case live
        case buffered
        case rate
        case info
        case tracks
        case source
        case picker
    }

    private struct RawMediaChoice: Codable {
        let index: Int
        let label: String
        let active: Bool
    }

    private struct RawVideoInfo: Codable {
        let height: Int
        let width: Int
        let fit: String
        let sources: [RawMediaChoice]
    }

    public static func decode(body: Any) throws -> BridgeMessage {
        guard let object = body as? [String: Any],
              JSONSerialization.isValidJSONObject(object)
        else { throw ValidationError.malformedPayload }

        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(BridgeMessage.self, from: data)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        guard version == Self.protocolVersion else {
            throw ValidationError.unsupportedVersion(version)
        }

        let type = try Self.validatedString(
            try values.decode(String.self, forKey: .type), field: "type")

        switch type {
        case "ready":
            self = .ready
        case "frameGone":
            self = .frameGone
        case "theater":
            self = .theater(
                airplay: try values.decode(Bool.self, forKey: .airplay),
                pip: try values.decode(Bool.self, forKey: .pip))
        case "theaterEnded":
            self = .theaterEnded
        case "theaterFailed":
            self = .theaterFailed
        case "ended":
            self = .ended
        case "blocked":
            self = .blocked(count: try Self.validatedInteger(
                try values.decode(Int.self, forKey: .count),
                in: 0...100_000, field: "count"))
        case "popupBlocked":
            self = .popupBlocked
        case "watchCleanTapped":
            self = .watchCleanTapped
        case "playback":
            self = .playback(
                playing: try values.decode(Bool.self, forKey: .playing),
                // Absent on a source that reports no readiness; "has a
                // picture" is the safe default, since the only thing it
                // gates is a spinner and holding the chrome open.
                buffering: try values.decodeIfPresent(Bool.self, forKey: .buffering) ?? false,
                armed: try values.decodeIfPresent(Bool.self, forKey: .armed) ?? false)
        case "episodeSourceChanged":
            self = .episodeSourceChanged(
                playing: try values.decode(Bool.self, forKey: .playing))
        case "volume":
            self = .volume(
                percent: try Self.validatedInteger(
                    try values.decode(Int.self, forKey: .percent),
                    in: 0...200, field: "percent"),
                boosted: try values.decode(Bool.self, forKey: .boosted),
                available: try values.decode(Bool.self, forKey: .available))
        case "time":
            self = .time(
                at: try Self.validatedNumber(
                    try values.decode(Double.self, forKey: .at),
                    in: 0...Self.maximumMediaTime, field: "at"),
                duration: try Self.validatedNumber(
                    try values.decode(Double.self, forKey: .duration),
                    in: 0...Self.maximumMediaTime, field: "duration"),
                live: try values.decode(Bool.self, forKey: .live),
                buffered: try Self.validatedNumber(
                    try values.decode(Double.self, forKey: .buffered),
                    in: 0...Self.maximumMediaTime, field: "buffered"),
                rate: try Self.validatedNumber(
                    try values.decode(Double.self, forKey: .rate),
                    in: 0...16, field: "rate"))
        case "video":
            let raw = try values.decode(RawVideoInfo.self, forKey: .info)
            guard raw.sources.count <= Self.maximumCollectionCount else {
                throw ValidationError.tooManyItems(field: "info.sources")
            }
            self = .video(info: VideoInfo(
                height: try Self.validatedInteger(
                    raw.height, in: 0...Self.maximumMediaDimension, field: "info.height"),
                width: try Self.validatedInteger(
                    raw.width, in: 0...Self.maximumMediaDimension, field: "info.width"),
                fit: try Self.validatedString(raw.fit, field: "info.fit"),
                sources: try raw.sources.map {
                    try Self.validatedChoice($0, field: "info.sources")
                }))
        case "tracks":
            let raw = try values.decode([RawMediaChoice].self, forKey: .tracks)
            guard raw.count <= Self.maximumCollectionCount else {
                throw ValidationError.tooManyItems(field: "tracks")
            }
            self = .tracks(try raw.map {
                try Self.validatedChoice($0, field: "tracks")
            })
        case "airplay":
            self = .airplay(
                available: try values.decode(Bool.self, forKey: .available),
                source: try Self.validatedString(
                    try values.decode(String.self, forKey: .source), field: "source"))
        case "airplaySupport":
            self = .airplaySupport(
                picker: try values.decode(Bool.self, forKey: .picker),
                source: try Self.validatedString(
                    try values.decode(String.self, forKey: .source), field: "source"))
        default:
            throw ValidationError.unknownType(type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.protocolVersion, forKey: .version)

        switch self {
        case .ready:
            try values.encode("ready", forKey: .type)
        case .frameGone:
            try values.encode("frameGone", forKey: .type)
        case .theater(let airplay, let pip):
            try values.encode("theater", forKey: .type)
            try values.encode(airplay, forKey: .airplay)
            try values.encode(pip, forKey: .pip)
        case .theaterEnded:
            try values.encode("theaterEnded", forKey: .type)
        case .theaterFailed:
            try values.encode("theaterFailed", forKey: .type)
        case .ended:
            try values.encode("ended", forKey: .type)
        case .watchCleanTapped:
            try values.encode("watchCleanTapped", forKey: .type)
        case .blocked(let count):
            try values.encode("blocked", forKey: .type)
            try values.encode(count, forKey: .count)
        case .popupBlocked:
            try values.encode("popupBlocked", forKey: .type)
        case .playback(let playing, let buffering, let armed):
            try values.encode("playback", forKey: .type)
            try values.encode(playing, forKey: .playing)
            try values.encode(buffering, forKey: .buffering)
            try values.encode(armed, forKey: .armed)
        case .episodeSourceChanged(let playing):
            try values.encode("episodeSourceChanged", forKey: .type)
            try values.encode(playing, forKey: .playing)
        case .volume(let percent, let boosted, let available):
            try values.encode("volume", forKey: .type)
            try values.encode(percent, forKey: .percent)
            try values.encode(boosted, forKey: .boosted)
            try values.encode(available, forKey: .available)
        case .time(let at, let duration, let live, let buffered, let rate):
            try values.encode("time", forKey: .type)
            try values.encode(at, forKey: .at)
            try values.encode(duration, forKey: .duration)
            try values.encode(live, forKey: .live)
            try values.encode(buffered, forKey: .buffered)
            try values.encode(rate, forKey: .rate)
        case .video(let info):
            try values.encode("video", forKey: .type)
            try values.encode(info, forKey: .info)
        case .tracks(let tracks):
            try values.encode("tracks", forKey: .type)
            try values.encode(tracks, forKey: .tracks)
        case .airplay(let available, let source):
            try values.encode("airplay", forKey: .type)
            try values.encode(available, forKey: .available)
            try values.encode(source, forKey: .source)
        case .airplaySupport(let picker, let source):
            try values.encode("airplaySupport", forKey: .type)
            try values.encode(picker, forKey: .picker)
            try values.encode(source, forKey: .source)
        }
    }

    private static func validatedString(_ value: String, field: String) throws -> String {
        guard value.count <= maximumStringLength else {
            throw ValidationError.stringTooLong(field: field)
        }
        return value
    }

    private static func validatedInteger(
        _ value: Int,
        in range: ClosedRange<Int>,
        field: String
    ) throws -> Int {
        guard range.contains(value) else {
            throw ValidationError.numberOutOfRange(field: field)
        }
        return value
    }

    private static func validatedNumber(
        _ value: Double,
        in range: ClosedRange<Double>,
        field: String
    ) throws -> Double {
        guard value.isFinite, range.contains(value) else {
            throw ValidationError.numberOutOfRange(field: field)
        }
        return value
    }

    private static func validatedChoice(
        _ raw: RawMediaChoice,
        field: String
    ) throws -> MediaChoice {
        MediaChoice(
            index: try validatedInteger(
                raw.index, in: 0...maximumMediaIndex, field: "\(field).index"),
            label: try validatedString(raw.label, field: "\(field).label"),
            active: raw.active)
    }
}

public struct BridgeEnvelope: Equatable, Sendable {
    public struct FrameMetrics: Equatable, Sendable {
        public let width: Int
        public let height: Int
        public let isVisible: Bool
    }

    public let frameID: String
    public let metrics: FrameMetrics?
    public let message: BridgeMessage

    private struct Header: Decodable {
        let fid: String
        let width: Int?
        let height: Int?
        let visible: Bool?
    }

    public static func decode(body: Any) throws -> BridgeEnvelope {
        guard let object = body as? [String: Any],
              JSONSerialization.isValidJSONObject(object)
        else { throw BridgeMessage.ValidationError.malformedPayload }

        let data = try JSONSerialization.data(withJSONObject: object)
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.fid.count <= BridgeMessage.maximumStringLength,
              UUID(uuidString: header.fid) != nil
        else { throw BridgeMessage.ValidationError.malformedPayload }

        let metrics: FrameMetrics?
        switch (header.width, header.height, header.visible) {
        case (nil, nil, nil):
            metrics = nil
        case (.some(let width), .some(let height), .some(let visible))
        where (0...32_768).contains(width) && (0...32_768).contains(height):
            metrics = FrameMetrics(width: width, height: height, isVisible: visible)
        default:
            throw BridgeMessage.ValidationError.numberOutOfRange(field: "frame")
        }

        return BridgeEnvelope(
            frameID: header.fid,
            metrics: metrics,
            message: try JSONDecoder().decode(BridgeMessage.self, from: data))
    }
}
