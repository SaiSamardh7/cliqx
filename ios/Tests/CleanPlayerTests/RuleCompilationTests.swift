import UIKit
import WebKit
import XCTest
@testable import CleanPlayer

/// The repository's own rule files, so what is tested is what ships.
private var repositoryRules: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CleanPlayerTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ios
        .appendingPathComponent("App/CleanPlayerApp/Resources")
}

/// Compiles the real generated lists. WebKit's practical ceiling is not
/// documented as a hard number, so it is measured here rather than assumed —
/// a list that will not compile is worse than no list, because the failure is
/// silent at runtime.
@MainActor
final class RuleCompilationTests: XCTestCase {
    private var location: RuleLocation { .directory(repositoryRules) }

    private func compile(_ json: String, identifier: String) async -> Result<WKContentRuleList, Error> {
        await withCheckedContinuation { continuation in
            WKContentRuleListStore.default()?.compileContentRuleList(
                forIdentifier: identifier, encodedContentRuleList: json
            ) { list, error in
                if let list { continuation.resume(returning: .success(list)) }
                else { continuation.resume(returning: .failure(error ?? URLError(.unknown))) }
            }
        }
    }

    private func load(_ name: String) throws -> String {
        do { return try RuleData.load(name, at: location) }
        catch { throw XCTSkip("run tools/convert-filters.sh first: \(error)") }
    }

    // MARK: The catalog

    func testCatalogDescribesEveryBundledList() throws {
        let catalog = RuleCatalog.load(at: location)
        let groups = Set(catalog.lists.map(\.group))
        XCTAssertTrue(groups.contains(.appSpecific), "hand-written fallback missing")
        XCTAssertTrue(groups.contains(.ads), "EasyList missing")
        XCTAssertTrue(groups.contains(.privacy), "EasyPrivacy missing")
        XCTAssertTrue(groups.contains(.annoyances), "annoyance list missing")
        for list in catalog.lists {
            XCTAssertGreaterThan(list.ruleCount, 0, "\(list.id) reports no rules")
            XCTAssertFalse(list.contentHash.isEmpty)
        }
    }

    /// The compiled-list cache is keyed by this hash. If the shipped payload and
    /// the manifest ever disagree, the app reuses a compile of rules it is no
    /// longer shipping — silently, and forever.
    func testShippedPayloadMatchesTheManifestHash() throws {
        let catalog = RuleCatalog.load(at: location)
        for list in catalog.generated {
            let json = try load(list.resource)
            XCTAssertEqual(RuleData.hash(json), list.contentHash,
                           "\(list.resource) does not match its manifest hash")

            let rules = try JSONSerialization.jsonObject(
                with: Data(json.utf8)) as? [Any]
            XCTAssertEqual(rules?.count, list.ruleCount,
                           "\(list.resource) rule count disagrees with the manifest")
        }
    }

    func testIdentifierTracksContent() {
        let a = BundledRuleList(id: "ads", group: .ads, resource: "ads",
                                contentHash: String(repeating: "a", count: 64),
                                ruleCount: 1)
        let b = BundledRuleList(id: "ads", group: .ads, resource: "ads",
                                contentHash: String(repeating: "b", count: 64),
                                ruleCount: 1)
        XCTAssertNotEqual(a.compiledIdentifier, b.compiledIdentifier,
                          "regenerated rules must not reuse the cached compile")
    }

    /// Rules cannot refresh at runtime, so staleness has to be visible.
    /// Silent decay behind an "Active" label is the failure being prevented.
    func testStalenessIsReportedOnceTheRulesAreOldEnough() {
        let generated = Date()
        let catalog = RuleCatalog(lists: [], convertedAt: generated)

        XCTAssertFalse(catalog.isStale(now: generated))
        XCTAssertFalse(catalog.isStale(
            now: generated.addingTimeInterval(RuleCatalog.staleAfter - 60)))
        XCTAssertTrue(catalog.isStale(
            now: generated.addingTimeInterval(RuleCatalog.staleAfter)))

        // Nothing to be stale about if the converter never recorded a date.
        XCTAssertFalse(RuleCatalog(lists: []).isStale())
    }

    // MARK: Compilation

    func testFullEasyListCompiles() async throws {
        let json = try load("ads")
        let started = Date()
        let result = await compile(json, identifier: "test-ads-full")
        let elapsed = Date().timeIntervalSince(started)

        switch result {
        case .success:
            print("ads.json compiled in \(String(format: "%.1f", elapsed))s")
        case .failure(let error):
            XCTFail("ads.json did not compile after \(String(format: "%.1f", elapsed))s: \(error)")
        }
    }

    /// The annoyance list is the newest and the one most likely to contain a
    /// rule shape WebKit rejects — and a rejected rule fails the WHOLE list.
    func testAnnoyanceListCompiles() async throws {
        let json = try load("annoyances")
        let started = Date()
        let result = await compile(json, identifier: "test-annoyances-full")
        let elapsed = Date().timeIntervalSince(started)

        switch result {
        case .success:
            print("annoyances.json compiled in \(String(format: "%.1f", elapsed))s")
        case .failure(let error):
            XCTFail("annoyances.json did not compile after "
                    + "\(String(format: "%.1f", elapsed))s: \(error)")
        }
    }

    /// Every shipped list must sit inside WebKit's per-list ceiling. The cap is
    /// per compiled list, not across them, which is the whole reason these are
    /// kept separate rather than merged into one JSON.
    func testEveryListFitsWebKitsPerListCeiling() {
        let ceiling = 150_000
        for list in RuleCatalog.load(at: location).lists {
            XCTAssertLessThan(list.ruleCount, ceiling,
                              "\(list.id) has \(list.ruleCount) rules, at or "
                              + "over WebKit's \(ceiling)-per-list limit")
        }
    }

    func testFullEasyPrivacyCompiles() async throws {
        let json = try load("privacy")
        let started = Date()
        let result = await compile(json, identifier: "test-privacy-full")
        let elapsed = Date().timeIntervalSince(started)

        switch result {
        case .success:
            print("privacy.json compiled in \(String(format: "%.1f", elapsed))s")
        case .failure(let error):
            XCTFail("privacy.json did not compile after \(String(format: "%.1f", elapsed))s: \(error)")
        }
    }

    func testFallbackCompiles() async throws {
        let json = try load("blocklist")
        let result = await compile(json, identifier: "test-blocklist")
        if case .failure(let error) = result {
            XCTFail("the instant fallback does not compile: \(error)")
        }
    }
}
