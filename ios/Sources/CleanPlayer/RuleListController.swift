import Foundation
import WebKit

/// Owns the app's content-rule lists: what is compiled, what is attached, and
/// what to do when a compile fails.
///
/// Two rules govern everything here.
///
/// 1. **Nothing is detached until its replacement is in hand.** Activation
///    computes the complete new set first, then swaps. A failed compile
///    therefore leaves the previous working lists attached rather than leaving
///    the user browsing unprotected.
/// 2. **The cheap list goes on first.** The 32 hand-written rules compile in
///    milliseconds; EasyList takes ~10s on first launch. Attaching the small
///    one immediately means the first navigation is filtered, not naked.
@MainActor
public final class RuleListController: ObservableObject {
    public enum Status: Equatable {
        case idle
        /// Big lists are still compiling. The fallback is already attached.
        case preparing
        case ready(rules: Int)
        /// Some list failed to compile. Whatever did compile is still attached.
        case degraded(failed: [String], rules: Int)
        case off

        public var isPreparing: Bool { self == .preparing }
    }

    @Published public private(set) var status: Status = .idle
    /// Rules currently in force. Drives the Settings readout.
    @Published public private(set) var activeRuleCount = 0

    /// False only in the window between launch and the first list being
    /// attached — a few milliseconds, since the smallest list goes on first.
    ///
    /// `attach(to:)` applies whatever is compiled *at that moment*, so a
    /// navigation started inside that window would load with nothing in force.
    /// The browser waits on this rather than racing it.
    @Published public private(set) var isArmed = false

    public let catalog: RuleCatalog
    private let location: RuleLocation
    private let store: WKContentRuleListStore?

    /// True while the current host has a user exception. The lists stay
    /// compiled and in memory — only their attachment is dropped.
    public private(set) var isSuspended = false

    /// Attached lists, in the order WebKit received them.
    private var active: [WKContentRuleList] = []
    private weak var userContent: WKUserContentController?

    /// Serialises activation so two overlapping calls cannot interleave their
    /// swaps and leave a mixed set attached.
    private var activation: Task<Void, Never>?

    public convenience init(bundle: Bundle = .main,
                            store: WKContentRuleListStore? = .default()) {
        self.init(location: .bundle(bundle), store: store)
    }

    public init(location: RuleLocation,
                catalog: RuleCatalog? = nil,
                store: WKContentRuleListStore? = .default()) {
        self.catalog = catalog ?? .load(at: location)
        self.location = location
        self.store = store
    }

    // MARK: Attaching

    /// Applies the current set to a newly created web view. Called from
    /// `makeUIView`, so a web view created mid-compile still gets whatever is
    /// ready at that moment and the rest when it lands.
    public func attach(to webView: WKWebView) {
        let content = webView.configuration.userContentController
        userContent = content
        content.removeAllContentRuleLists()
        guard !isSuspended else { return }
        for list in active { content.add(list) }
    }

    /// Turns blocking off for a host the user has excepted, and back on when
    /// leaving it.
    ///
    /// Synchronous on purpose. The lists are already compiled and resident, so
    /// this can run inside a navigation decision — no recompile, no round trip,
    /// and the very load being decided already sees the right set.
    ///
    /// Note this detaches *every* list rather than layering an allow rule on
    /// top: `ignore-previous-rules` only cancels earlier rules within the same
    /// compiled list, so it cannot exempt a site from a different one.
    public func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        guard let userContent else { return }
        userContent.removeAllContentRuleLists()
        guard !suspended else { return }
        for list in active { userContent.add(list) }
    }

    // MARK: Activation

    /// Brings the attached set in line with `level`.
    ///
    /// Safe to call repeatedly; the previous activation is cancelled first so a
    /// rapid settings change does not race.
    public func activate(_ level: ProtectionLevel) async {
        activation?.cancel()
        let task = Task { await self.performActivation(level) }
        activation = task
        await task.value
    }

    /// Fire-and-forget entry point for app launch.
    public func begin(_ level: ProtectionLevel) {
        activation?.cancel()
        activation = Task { await self.performActivation(level) }
    }

    private func performActivation(_ level: ProtectionLevel) async {
        guard level != .off else {
            apply([], rules: 0, status: .off, allowEmpty: true)
            return
        }

        // Cheapest list first: it is the one that makes the difference between
        // "filtered in 20ms" and "unfiltered for 10 seconds".
        let wanted = catalog.lists(for: level)
            .sorted { lhs, rhs in lhs.ruleCount < rhs.ruleCount }
        guard !wanted.isEmpty else {
            apply([], rules: 0,
                  status: .degraded(failed: ["no rules bundled"], rules: 0),
                  allowEmpty: true)
            return
        }
        let total = wanted.reduce(0) { $0 + $1.ruleCount }

        // Fast path. Everything compiled on a previous launch is in the store,
        // keyed by content hash, so this costs a few milliseconds and never
        // reads the 14MB payload.
        let cached = await lookUpAll(wanted)
        // After the await, and outside the `if let`: a cache miss suspends just
        // as a hit does, and the miss path goes on to publish `.preparing`.
        if Task.isCancelled { return }
        if let cached {
            apply(cached, rules: total, status: .ready(rules: total))
            await purgeStaleCompilations(keeping: catalog.lists)
            return
        }

        status = .preparing

        var compiled: [WKContentRuleList] = []
        var rules = 0
        var failed: [String] = []

        // Sequential on purpose: each generated list needs its JSON resident to
        // compile, and two at once doubles peak memory for no wall-clock gain.
        for spec in wanted {
            let list = await obtain(spec)
            // Checked AFTER the await, not just before it. A compile takes
            // seconds, and a newer activation may have replaced the attached
            // set while this one was waiting — applying now would put the old
            // set back. Turning protection off mid-compile used to switch
            // itself on again this way.
            if Task.isCancelled { return }
            guard let list else { failed.append(spec.id); continue }

            compiled.append(list)
            rules += spec.ruleCount
            // Publish as we go. The fallback lands almost immediately, so
            // protection starts long before EasyList finishes.
            apply(compiled, rules: rules, status: .preparing)
        }

        status = failed.isEmpty ? .ready(rules: rules)
                                : .degraded(failed: failed, rules: rules)
        // Even if every list failed, stop holding navigation: the user is then
        // told protection is unavailable rather than left staring at a spinner.
        isArmed = true
        // A cancelled activation must not purge: its set can differ from the
        // live one, and it would delete compiles the current activation uses.
        guard !Task.isCancelled else { return }
        await purgeStaleCompilations(keeping: catalog.lists)
    }

    /// The atomic swap. `removeAllContentRuleLists` and the re-add happen back
    /// to back with no `await` between them, so there is no window in which the
    /// web view has nothing attached.
    private func apply(_ lists: [WKContentRuleList], rules: Int,
                       status newStatus: Status, allowEmpty: Bool = false) {
        guard allowEmpty || !lists.isEmpty else { return }
        active = lists
        activeRuleCount = rules
        status = newStatus
        isArmed = true
        guard let userContent, !isSuspended else { return }
        userContent.removeAllContentRuleLists()
        for list in lists { userContent.add(list) }
    }

    // MARK: Store plumbing

    private func lookUpAll(_ specs: [BundledRuleList]) async -> [WKContentRuleList]? {
        var found: [WKContentRuleList] = []
        for spec in specs {
            guard let list = await lookUp(spec.compiledIdentifier) else { return nil }
            found.append(list)
        }
        return found
    }

    private func lookUp(_ identifier: String) async -> WKContentRuleList? {
        guard let store else { return nil }
        return await withCheckedContinuation { continuation in
            store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    /// Cached compile if there is one, otherwise read, decompress and compile.
    private func obtain(_ spec: BundledRuleList) async -> WKContentRuleList? {
        if let cached = await lookUp(spec.compiledIdentifier) { return cached }
        guard let store else { return nil }
        guard let json = await Self.loadJSON(spec, at: location) else { return nil }
        return await withCheckedContinuation { continuation in
            store.compileContentRuleList(forIdentifier: spec.compiledIdentifier,
                                         encodedContentRuleList: json) { list, error in
                if list == nil {
                    NSLog("rule list %@ failed to compile: %@", spec.id,
                          String(describing: error))
                }
                continuation.resume(returning: list)
            }
        }
    }

    /// Off the main actor: reading and inflating 8MB would otherwise stall the
    /// UI for the length of the decompression.
    private static func loadJSON(_ spec: BundledRuleList,
                                 at location: RuleLocation) async -> String? {
        await Task.detached(priority: .utility) {
            try? RuleData.load(spec.resource, at: location)
        }.value
    }

    /// Compiled lists are keyed by content hash, so regenerating the rules
    /// leaves the previous compile behind — tens of megabytes per generation.
    /// Drop anything of ours that is no longer wanted.
    ///
    /// Keyed on the whole catalog, never one level's selection. Passing the
    /// active level's lists meant Standard purged the annoyance compile and
    /// Strict purged nothing back, so switching levels round-trip threw away
    /// 49,553 rules and re-inflated and recompiled them — precisely the work
    /// the content-hash cache exists to skip.
    private func purgeStaleCompilations(keeping specs: [BundledRuleList]) async {
        guard let store else { return }
        let keep = Set(specs.map(\.compiledIdentifier))
        let existing: [String] = await withCheckedContinuation { continuation in
            store.getAvailableContentRuleListIdentifiers { ids in
                continuation.resume(returning: ids ?? [])
            }
        }
        for identifier in existing
        where identifier.hasPrefix("cp.") && !keep.contains(identifier) {
            await withCheckedContinuation { continuation in
                store.removeContentRuleList(forIdentifier: identifier) { _ in
                    continuation.resume()
                }
            }
        }
    }
}
