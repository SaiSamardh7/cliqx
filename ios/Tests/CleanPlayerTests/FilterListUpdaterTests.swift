import XCTest
@testable import CleanPlayer

/// Records outgoing requests so the conditional-request headers can be asserted.
final class RecordingProtocol: URLProtocol {
    nonisolated(unsafe) static var respond: ((URLRequest) -> (HTTPURLResponse?, Data?, Error?))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        RecordingProtocol.lastRequest = request
        guard let client, let respond = RecordingProtocol.respond else { return }
        let (response, data, error) = respond(request)
        if let error { client.urlProtocol(self, didFailWithError: error); return }
        if let response {
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        if let data { client.urlProtocol(self, didLoad: data) }
        client.urlProtocolDidFinishLoading(self)
    }
}

final class FilterListUpdaterTests: XCTestCase {
    let source = FilterSource.easyList
    var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        RecordingProtocol.respond = nil
        RecordingProtocol.lastRequest = nil
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        RecordingProtocol.respond = nil
        super.tearDown()
    }

    private func makeUpdater(now: Date = Date()) -> FilterListUpdater {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingProtocol.self]
        return FilterListUpdater(session: URLSession(configuration: config),
                                 directory: directory, now: { now })
    }

    private func reply(_ status: Int, _ body: Data,
                       headers: [String: String] = ["Content-Type": "text/plain"]) {
        RecordingProtocol.respond = { request in
            (HTTPURLResponse(url: request.url!, statusCode: status,
                             httpVersion: nil, headerFields: headers), body, nil)
        }
    }

    private var validList: Data {
        Data("""
        [Adblock Plus 2.0]
        ! Version: 202609021200
        ! Title: EasyList
        ||ads.example.com^
        """.utf8)
    }

    // MARK: Conditional requests

    func testSendsConditionalHeadersWhenKnown() async throws {
        reply(304, Data())
        let state = FilterState(sourceID: source.id, etag: "\"abc\"",
                                lastModified: "Wed, 02 Sep 2026 10:00:00 GMT")

        _ = try await makeUpdater().fetch(source, state: state)

        let sent = RecordingProtocol.lastRequest
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "If-None-Match"), "\"abc\"")
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "If-Modified-Since"),
                       "Wed, 02 Sep 2026 10:00:00 GMT")
    }

    func testNotModifiedKeepsExistingState() async throws {
        reply(304, Data())
        let state = FilterState(sourceID: source.id, lastUpdated: .distantPast,
                                checksum: "old", etag: "\"abc\"")

        let outcome = try await makeUpdater().fetch(source, state: state)

        XCTAssertFalse(outcome.wasModified)
        XCTAssertNil(outcome.data)
        XCTAssertEqual(outcome.state, state, "a 304 must not disturb what we know")
    }

    // MARK: Rejecting bad downloads

    func testRejectsNon200() async {
        reply(503, Data("service unavailable".utf8))
        await assertThrows(.httpStatus(503))
    }

    func testRejectsUnexpectedContentType() async {
        reply(200, validList, headers: ["Content-Type": "text/html; charset=utf-8"])
        await assertThrows(.unexpectedContentType("text/html; charset=utf-8"))
    }

    /// Refused from the header, before the body is trusted.
    func testRejectsDeclaredOversize() async {
        let huge = source.maxBytes + 1
        reply(200, validList, headers: ["Content-Type": "text/plain",
                                        "Content-Length": "\(huge)"])
        await assertThrows(.declaredTooLarge(huge))
    }

    func testRejectsOversizedBody() async {
        var small = source
        small = FilterSource(id: small.id, name: small.name, url: small.url,
                             repository: small.repository, license: small.license,
                             attribution: small.attribution, group: small.group,
                             maxBytes: 8)
        reply(200, validList)
        do {
            _ = try await makeUpdater().fetch(small, state: FilterState(sourceID: small.id))
            XCTFail("expected rejection")
        } catch let error as FilterUpdateError {
            guard case .bodyTooLarge = error else {
                return XCTFail("wrong error: \(error)")
            }
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testRejectsEmpty() async {
        reply(200, Data())
        await assertThrows(.empty)
    }

    /// A captive portal or error page is the realistic failure here, not a
    /// malformed rule.
    func testRejectsSomethingThatIsNotAFilterList() async {
        reply(200, Data("<!doctype html><title>Login required</title>".utf8))
        await assertThrows(.notAFilterList)
    }

    // MARK: Success

    func testCapturesValidatorsChecksumAndVersion() async throws {
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        reply(200, validList, headers: [
            "Content-Type": "text/plain",
            "ETag": "\"v2\"",
            "Last-Modified": "Wed, 02 Sep 2026 10:00:00 GMT",
        ])

        let outcome = try await makeUpdater(now: when)
            .fetch(source, state: FilterState(sourceID: source.id))

        XCTAssertTrue(outcome.wasModified)
        XCTAssertEqual(outcome.state.etag, "\"v2\"")
        XCTAssertEqual(outcome.state.lastModified, "Wed, 02 Sep 2026 10:00:00 GMT")
        XCTAssertEqual(outcome.state.version, "202609021200")
        XCTAssertEqual(outcome.state.lastUpdated, when)
        XCTAssertEqual(outcome.state.checksum,
                       FilterListUpdater.checksum(validList))
    }

    // MARK: Scheduling

    func testChecksAboutWeekly() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let updater = makeUpdater(now: now)

        XCTAssertTrue(updater.needsCheck(FilterState(sourceID: source.id)),
                      "never fetched")
        XCTAssertFalse(updater.needsCheck(
            FilterState(sourceID: source.id, lastUpdated: now.addingTimeInterval(-3600))))
        XCTAssertTrue(updater.needsCheck(
            FilterState(sourceID: source.id,
                        lastUpdated: now.addingTimeInterval(-8 * 24 * 3600))))
    }

    // MARK: Storage keeps the last known good copy

    func testStoreIsAtomicAndKeepsThePreviousListOnFailure() throws {
        let updater = makeUpdater()
        let good = Data("[Adblock Plus 2.0]\n! Version: 1\n".utf8)
        try updater.store(good, for: source)
        XCTAssertEqual(updater.loadStored(source), good)

        // A candidate whose checksum does not match must not land.
        XCTAssertThrowsError(
            try updater.store(Data("[Adblock Plus 2.0]\n! Version: 2\n".utf8),
                              for: source, expecting: "not-the-right-digest")
        )

        XCTAssertEqual(updater.loadStored(source), good,
                       "the working list must survive a failed update")
    }

    func testStoreLeavesNoPartialFilesBehind() throws {
        let updater = makeUpdater()
        try updater.store(validList, for: source)

        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".partial") }
        XCTAssertTrue(leftovers.isEmpty, "found \(leftovers)")
    }

    // MARK: Helper

    private func assertThrows(_ expected: FilterUpdateError,
                              file: StaticString = #filePath,
                              line: UInt = #line) async {
        do {
            _ = try await makeUpdater().fetch(source,
                                              state: FilterState(sourceID: source.id))
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as FilterUpdateError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("wrong error type: \(error)", file: file, line: line)
        }
    }
}
