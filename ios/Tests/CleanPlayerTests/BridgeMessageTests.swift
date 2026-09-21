import Foundation
import XCTest
@testable import CleanPlayer

final class BridgeMessageTests: XCTestCase {
    func testDecodesCurrentProtocolMessage() throws {
        let message = try decode(#"{"v":1,"type":"theater","airplay":true,"pip":false}"#)

        XCTAssertEqual(message, .theater(airplay: true, pip: false))
    }

    func testDecodesEveryMessageCurrentlyEmittedByTheAgent() {
        let payloads = [
            #"{"v":1,"type":"ready"}"#,
            #"{"v":1,"type":"frameGone"}"#,
            #"{"v":1,"type":"popupBlocked"}"#,
            #"{"v":1,"type":"theater","airplay":false,"pip":true}"#,
            #"{"v":1,"type":"theaterEnded"}"#,
            #"{"v":1,"type":"theaterFailed"}"#,
            #"{"v":1,"type":"ended"}"#,
            #"{"v":1,"type":"blocked","count":2}"#,
            #"{"v":1,"type":"playback","playing":true,"armed":true}"#,
            #"{"v":1,"type":"episodeSourceChanged","playing":false}"#,
            #"{"v":1,"type":"volume","percent":125,"boosted":true}"#,
            #"{"v":1,"type":"time","at":12.5,"duration":24,"live":false,"buffered":18,"rate":1.25}"#,
            #"{"v":1,"type":"video","info":{"height":1080,"width":1920,"fit":"contain","sources":[{"index":0,"label":"1080p","active":true}]}}"#,
            #"{"v":1,"type":"tracks","tracks":[{"index":0,"label":"English","active":true}]}"#,
            #"{"v":1,"type":"airplay","available":true,"source":"file"}"#,
            #"{"v":1,"type":"airplaySupport","picker":true,"source":"mse"}"#,
        ]

        for payload in payloads {
            XCTAssertNoThrow(try decode(payload), payload)
        }
    }

    func testRejectsMalformedMessage() {
        XCTAssertThrowsError(try decode(#"{"v":1,"type":"blocked","count":"six"}"#))
    }

    func testRejectsOversizedString() throws {
        let label = String(repeating: "x", count: BridgeMessage.maximumStringLength + 1)
        let data = try JSONSerialization.data(withJSONObject: [
            "v": 1,
            "type": "tracks",
            "tracks": [["index": 0, "label": label, "active": false]],
        ])

        XCTAssertThrowsError(try JSONDecoder().decode(BridgeMessage.self, from: data)) { error in
            XCTAssertEqual(error as? BridgeMessage.ValidationError,
                           .stringTooLong(field: "tracks.label"))
        }
    }

    func testRejectsBlockedCountAboveLimit() {
        XCTAssertThrowsError(
            try decode(#"{"v":1,"type":"blocked","count":100001}"#)
        ) { error in
            XCTAssertEqual(error as? BridgeMessage.ValidationError,
                           .numberOutOfRange(field: "count"))
        }
    }

    func testRejectsNegativeBlockedCount() {
        XCTAssertThrowsError(
            try decode(#"{"v":1,"type":"blocked","count":-1}"#)
        )
    }

    func testRejectsMissingVersion() {
        XCTAssertThrowsError(try decode(#"{"type":"ready"}"#))
    }

    func testRejectsWrongVersion() {
        XCTAssertThrowsError(try decode(#"{"v":99,"type":"ready"}"#)) { error in
            XCTAssertEqual(error as? BridgeMessage.ValidationError,
                           .unsupportedVersion(99))
        }
    }

    func testEnvelopeRequiresUUIDFrameIdentity() throws {
        let valid = try BridgeEnvelope.decode(body: [
            "v": 1,
            "fid": "5D95A57B-FADB-45A6-9513-627E3894CFE7",
            "type": "blocked",
            "count": 2,
        ])

        XCTAssertEqual(valid.frameID, "5D95A57B-FADB-45A6-9513-627E3894CFE7")
        XCTAssertEqual(valid.message, .blocked(count: 2))
        XCTAssertThrowsError(try BridgeEnvelope.decode(body: [
            "v": 1,
            "fid": "not-a-frame-id",
            "type": "ready",
            "width": 320,
            "height": 180,
            "visible": true,
        ]))
    }

    func testRejectsUnknownMessageType() {
        XCTAssertThrowsError(try decode(#"{"v":1,"type":"surprise"}"#)) { error in
            XCTAssertEqual(error as? BridgeMessage.ValidationError,
                           .unknownType("surprise"))
        }
    }

    func testRejectsNonFinitePlaybackNumber() throws {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN")

        XCTAssertThrowsError(try decoder.decode(
            BridgeMessage.self,
            from: Data(#"{"v":1,"type":"time","at":"NaN","duration":0,"live":false,"buffered":0,"rate":1}"#.utf8)
        ))
    }

    private func decode(_ json: String) throws -> BridgeMessage {
        try JSONDecoder().decode(BridgeMessage.self, from: Data(json.utf8))
    }
}
