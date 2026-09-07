import UIKit
import WebKit
import XCTest
@testable import CleanPlayer

/// Proves that a rule list is not merely compiled but actually *in force* in a
/// web view.
///
/// The probe is a `css-display-none` rule rather than a `block` rule on purpose:
/// it needs no network, so the test cannot pass or fail for reasons that have
/// nothing to do with rule activation. If the list is attached the element is
/// hidden by WebKit itself; if it is not, the element is visible.
@MainActor
final class RuleActivationTests: XCTestCase {
    private var directory: URL!
    private var store: WKContentRuleListStore!

    // `nonisolated` because it is a default argument on probeHidden, which is
    // evaluated in a nonisolated context. CI warned that referencing it there
    // is an error under the Swift 6 language mode.
    private nonisolated static let probeSelector = "cp-probe-ad"

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        // An isolated store, so these tests neither see nor poison the compiles
        // the app and the other tests share.
        store = WKContentRuleListStore(url: directory
            .appendingPathComponent("store", isDirectory: true))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    // MARK: Fixtures

    private func write(_ json: String, as name: String) throws {
        try Data(json.utf8).write(
            to: directory.appendingPathComponent("\(name).json"))
    }

    private func probeRules(selector: String) -> String {
        """
        [{"trigger":{"url-filter":".*"},
          "action":{"type":"css-display-none","selector":".\(selector)"}}]
        """
    }

    private func spec(_ id: String, group: RuleGroup, resource: String,
                      hash: String, rules: Int) -> BundledRuleList {
        BundledRuleList(id: id, group: group, resource: resource,
                        contentHash: hash, ruleCount: rules)
    }

    private func controller(_ lists: [BundledRuleList]) -> RuleListController {
        RuleListController(location: .directory(directory),
                           catalog: RuleCatalog(lists: lists), store: store)
    }

    /// Loads a page on a real origin and reports whether the probe element was
    /// hidden by a content rule.
    ///
    /// Retried, and the retry is not padding. CI fails here with
    /// `InvalidTransition { phase: idle, targetPhase: failed(deinit) }` — a
    /// navigation torn down having never started, because the web content
    /// process did not come up. It has never reproduced on a developer machine.
    ///
    /// Retrying any *thrown* error is sound because a thrown error is never
    /// this helper's answer. A rule list that failed to attach returns `false`
    /// from a load that succeeded; it does not throw. So a retry can rescue a
    /// content process that died on the way up without being able to hide a
    /// rule that is genuinely not in force.
    private func probeHidden(with rules: RuleListController,
                             selector: String = probeSelector,
                             attempts: Int = 3) async throws -> Bool {
        var failure: Error?
        for attempt in 1...attempts {
            do {
                return try await loadProbe(with: rules, selector: selector)
            } catch {
                failure = error
                // Each attempt builds a fresh web view: one whose content
                // process died is not reliably reusable.
                if attempt < attempts {
                    try? await Task.sleep(nanoseconds: 750_000_000)
                }
            }
        }
        throw failure!
    }

    private func loadProbe(with rules: RuleListController,
                           selector: String) async throws -> Bool {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        let webView = WKWebView(frame: frame)

        // In a real window, not detached. WebKit will not grant a web view that
        // is in no window a visibility assertion for its content process, and a
        // loaded machine then suspends that process mid-navigation — which
        // arrives here as the navigation failing, never as a timeout. The
        // `WebProcess NearSuspended Assertion` lines in the CI log are that.
        //
        // The `defer` is what keeps the window alive. Nothing else refers to it
        // once the web view is added, so ARC may release it immediately — which
        // takes the web view straight back out of the window and undoes the
        // point of having one.
        let window = UIWindow(frame: frame)
        window.isHidden = false
        window.addSubview(webView)
        defer {
            webView.removeFromSuperview()
            window.isHidden = true
        }

        rules.attach(to: webView)

        let delegate = LoadWaiter()
        webView.navigationDelegate = delegate
        webView.loadHTMLString(
            "<html><body><div class=\"\(selector)\">ad</div></body></html>",
            baseURL: URL(string: "https://probe.invalid/"))
        try await delegate.wait()

        let display = try await webView.evaluateJavaScript(
            "getComputedStyle(document.querySelector('.\(selector)')).display"
        ) as? String
        return display == "none"
    }

    // MARK: Activation

    func testActivationPutsTheRulesInForce() async throws {
        let json = probeRules(selector: Self.probeSelector)
        try write(json, as: "probe")
        let rules = controller([spec("probe", group: .appSpecific,
                                     resource: "probe",
                                     hash: RuleData.hash(json), rules: 1)])

        await rules.activate(.standard)

        XCTAssertEqual(rules.status, .ready(rules: 1))
        XCTAssertEqual(rules.activeRuleCount, 1)
        let hidden = try await probeHidden(with: rules)
        XCTAssertTrue(hidden, "the compiled list was never attached to the web view")
    }

    func testOffDetachesEverything() async throws {
        let json = probeRules(selector: Self.probeSelector)
        try write(json, as: "probe")
        let rules = controller([spec("probe", group: .appSpecific,
                                     resource: "probe",
                                     hash: RuleData.hash(json), rules: 1)])

        await rules.activate(.standard)
        let hiddenWhileOn = try await probeHidden(with: rules)
        XCTAssertTrue(hiddenWhileOn)

        await rules.activate(.off)
        XCTAssertEqual(rules.status, .off)
        XCTAssertEqual(rules.activeRuleCount, 0)
        let hidden = try await probeHidden(with: rules)
        XCTAssertFalse(hidden, "protection off must mean no rules attached")
    }

    /// The rollback requirement. A list that will not compile must not take the
    /// working ones down with it.
    func testFailedCompileLeavesTheWorkingListsAttached() async throws {
        let good = probeRules(selector: Self.probeSelector)
        try write(good, as: "probe")
        // Valid JSON, invalid as a content rule list: WebKit rejects it at
        // compile time, which is exactly the failure being guarded against.
        try write("[{\"trigger\":{\"url-filter\":\"[\"},\"action\":{}}]", as: "broken")

        let rules = controller([
            spec("probe", group: .appSpecific, resource: "probe",
                 hash: RuleData.hash(good), rules: 1),
            // Sorted last by rule count, so it compiles after the good one and
            // can only fail by tearing down something already attached.
            spec("broken", group: .ads, resource: "broken",
                 hash: "broken", rules: 99_999),
        ])

        await rules.activate(.standard)

        XCTAssertEqual(rules.status, .degraded(failed: ["broken"], rules: 1))
        XCTAssertEqual(rules.activeRuleCount, 1, "the working list was dropped")
        let hidden = try await probeHidden(with: rules)
        XCTAssertTrue(hidden, "a failed compile left the user with no protection")
    }

    /// A list that is missing from the bundle behaves like one that fails to
    /// compile: degraded, never unprotected.
    func testMissingResourceDegradesRatherThanDetaching() async throws {
        let good = probeRules(selector: Self.probeSelector)
        try write(good, as: "probe")

        let rules = controller([
            spec("probe", group: .appSpecific, resource: "probe",
                 hash: RuleData.hash(good), rules: 1),
            spec("absent", group: .ads, resource: "absent",
                 hash: "absent", rules: 99_999),
        ])

        await rules.activate(.standard)

        XCTAssertEqual(rules.status, .degraded(failed: ["absent"], rules: 1))
        let hidden = try await probeHidden(with: rules)
        XCTAssertTrue(hidden)
    }

    func testEmptyCatalogReportsDegradedAndNotReady() async throws {
        let rules = controller([])
        await rules.activate(.standard)
        XCTAssertEqual(rules.activeRuleCount, 0)
        guard case .degraded = rules.status else {
            return XCTFail("expected degraded, got \(rules.status)")
        }
    }

    /// The browser holds its first navigation on this. If it were true before
    /// anything is attached, that page would be fetched with no filtering.
    func testNotArmedUntilSomethingIsActuallyAttached() async throws {
        let json = probeRules(selector: Self.probeSelector)
        try write(json, as: "probe")
        let rules = controller([spec("probe", group: .appSpecific,
                                     resource: "probe",
                                     hash: RuleData.hash(json), rules: 1)])

        XCTAssertFalse(rules.isArmed, "armed before any list was compiled")
        await rules.activate(.standard)
        XCTAssertTrue(rules.isArmed)
        XCTAssertEqual(rules.activeRuleCount, 1)
    }

    /// Protection deliberately off still has to release the navigation, and so
    /// does a catalog where nothing compiles — otherwise the browser waits for
    /// a list that is never coming.
    func testArmsEvenWhenThereIsNothingToAttach() async throws {
        let off = controller([])
        await off.activate(.off)
        XCTAssertTrue(off.isArmed, "protection off must not hold navigation")

        try write("[{\"trigger\":{\"url-filter\":\"[\"},\"action\":{}}]", as: "broken")
        let broken = controller([spec("broken", group: .ads, resource: "broken",
                                      hash: "broken", rules: 1)])
        await broken.activate(.standard)
        XCTAssertTrue(broken.isArmed,
                      "a total compile failure must not hold navigation forever")
    }

    /// Switching level must not throw away the other level's compile.
    ///
    /// The purge exists to drop compiles orphaned when rules are REGENERATED.
    /// Keyed on the active level's selection instead, Standard deleted the
    /// annoyance compile every time, so Strict -> Standard -> Strict paid a
    /// full inflate and recompile for 49,553 rules — exactly the work the
    /// content-hash cache exists to skip.
    func testSwitchingLevelKeepsTheOtherLevelsCompile() async throws {
        let base = probeRules(selector: Self.probeSelector)
        let extra = probeRules(selector: "cp-probe-annoyance")
        try write(base, as: "base")
        try write(extra, as: "extra")

        let annoyance = spec("extra", group: .annoyances, resource: "extra",
                             hash: RuleData.hash(extra), rules: 2)
        let rules = controller([
            spec("base", group: .appSpecific, resource: "base",
                 hash: RuleData.hash(base), rules: 1),
            annoyance,
        ])

        await rules.activate(.strict)
        XCTAssertEqual(rules.status, .ready(rules: 3))

        await rules.activate(.standard)   // annoyances not selected here

        let kept = await withCheckedContinuation { continuation in
            store.lookUpContentRuleList(
                forIdentifier: annoyance.compiledIdentifier
            ) { list, _ in continuation.resume(returning: list) }
        }
        XCTAssertNotNil(kept, "dropping to Standard purged the Strict compile")
    }

    /// Decides whether an "unbreak" list can be a list of its own.
    ///
    /// WebKit evaluates each compiled list independently, so the open question
    /// is whether `ignore-previous-rules` in one list can cancel an action from
    /// another. If it cannot, compatibility fixes have to be appended to the
    /// list they are undoing rather than shipped separately.
    func testWhetherIgnorePreviousRulesReachesAcrossLists() async throws {
        let hide = """
        [{"trigger":{"url-filter":".*"},
          "action":{"type":"css-display-none","selector":".\(Self.probeSelector)"}}]
        """
        let allow = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"ignore-previous-rules"}}]
        """
        try write(hide, as: "hide")
        try write(allow, as: "allow")

        let rules = controller([
            // Sorted by rule count, so "allow" is attached after "hide".
            spec("hide", group: .appSpecific, resource: "hide",
                 hash: RuleData.hash(hide), rules: 1),
            spec("allow", group: .ads, resource: "allow",
                 hash: RuleData.hash(allow), rules: 2),
        ])
        await rules.activate(.standard)
        XCTAssertEqual(rules.status, .ready(rules: 3))

        let stillHidden = try await probeHidden(with: rules)
        // Whichever way this lands, it is a fact the architecture depends on,
        // so it is asserted rather than assumed. Documented in ARCHITECTURE.md.
        XCTAssertTrue(stillHidden,
                      "ignore-previous-rules DID cross compiled lists — an "
                      + "unbreak list can ship separately after all, and "
                      + "ARCHITECTURE.md needs correcting")
    }

    /// A compile takes seconds. If the user turns protection off while one is
    /// running, the superseded activation must not finish and put its lists
    /// back — which is exactly what it did when cancellation was only checked
    /// before the await rather than after it.
    func testActivationSupersededMidCompileDoesNotReattach() async throws {
        let json = probeRules(selector: Self.probeSelector)
        try write(json, as: "probe")
        let rules = controller([spec("probe", group: .appSpecific,
                                     resource: "probe",
                                     hash: RuleData.hash(json), rules: 1)])

        rules.begin(.standard)
        await Task.yield()          // let it reach its first compile
        await rules.activate(.off)

        // Every chance for the superseded activation to resume and apply.
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(rules.status, .off)
        XCTAssertEqual(rules.activeRuleCount, 0)
        let hidden = try await probeHidden(with: rules)
        XCTAssertFalse(hidden, "a superseded activation re-attached its rules")
    }

    /// Second launch: the compile is cached, so activation must not read the
    /// payload again. Deleting it after the first activation makes any re-read
    /// fail loudly.
    func testCachedCompileIsReusedWithoutReadingThePayload() async throws {
        let json = probeRules(selector: Self.probeSelector)
        try write(json, as: "probe")
        let list = spec("probe", group: .appSpecific, resource: "probe",
                        hash: RuleData.hash(json), rules: 1)

        await controller([list]).activate(.standard)

        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("probe.json"))

        let second = controller([list])
        await second.activate(.standard)

        XCTAssertEqual(second.status, .ready(rules: 1))
        let hidden = try await probeHidden(with: second)
        XCTAssertTrue(hidden, "the cached compile was not reused")
    }
}

/// Waits for a single navigation to finish. Shared with AdBlockingTests.
final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var settled = false
    private var pending: Result<Void, Error>?

    struct TimedOut: Error {}

    /// The timeout is enforced, not decorative. A blocked subresource can hold
    /// `didFinish` back indefinitely, and an un-enforced wait turns that into a
    /// hung suite rather than a failed test.
    func wait(timeout: TimeInterval = 10) async throws {
        if let pending { return try pending.get() }
        let timer = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self.settle(.failure(TimedOut()))
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    private func settle(_ result: Result<Void, Error>) {
        guard !settled else { return }
        settled = true
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        } else {
            pending = result
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        settle(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                 withError error: Error) {
        settle(.failure(error))
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        settle(.failure(error))
    }
}
