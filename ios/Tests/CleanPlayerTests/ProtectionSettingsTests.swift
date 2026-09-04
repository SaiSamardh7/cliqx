import XCTest
@testable import CleanPlayer

@MainActor
final class ProtectionSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "cleanplayer.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: Canonicalisation

    /// An exception added on one spelling has to be found again on another, or
    /// the user turns protection off and it silently comes back.
    func testCanonicalFormCollapsesTheSpellingsOfOneHost() {
        let expected = "example.com"
        for spelling in ["example.com", "EXAMPLE.com", "www.example.com",
                         "WWW.Example.Com", "example.com.", ".example.com",
                         "https://www.example.com/watch?v=1"] {
            XCTAssertEqual(HostKey.canonical(spelling), expected, spelling)
        }
    }

    func testCanonicalRejectsThingsThatAreNotHosts() {
        for junk in ["", "   ", "localhost", "not a host", "example",
                     "example.com/path"] {
            XCTAssertNil(HostKey.canonical(junk), junk)
        }
    }

    func testExceptionCoversSubdomainsButNotSuffixNeighbours() {
        XCTAssertTrue(HostKey.matches(stored: "example.com", host: "example.com"))
        XCTAssertTrue(HostKey.matches(stored: "example.com", host: "cdn.example.com"))
        XCTAssertTrue(HostKey.matches(stored: "example.com", host: "www.example.com"))
        XCTAssertTrue(HostKey.matches(stored: "example.com", host: "a.b.example.com"))
        // The one that a naive hasSuffix gets wrong.
        XCTAssertFalse(HostKey.matches(stored: "example.com", host: "notexample.com"))
        XCTAssertFalse(HostKey.matches(stored: "example.com", host: "example.com.evil.test"))
        XCTAssertFalse(HostKey.matches(stored: "example.com", host: "example.org"))
    }

    // MARK: Popup destinations

    /// The rule that decides whether a page may replace what the user is
    /// watching. Getting the "false" cases wrong hands the video page to an ad.
    func testOnlySameSiteWindowsMayReplaceThePage() {
        let watching = URL(string: "https://player.example.com/watch/1")!

        for allowed in ["https://player.example.com/watch/2",
                        "https://example.com/other",
                        "https://cdn.example.com/x",
                        "https://www.example.com/x"] {
            XCTAssertTrue(HostKey.isSameSite(URL(string: allowed)!, as: watching),
                          allowed)
        }
        for blocked in ["https://ads.doubleclick.net/x",
                        "https://example.org/x",
                        "https://notexample.com/x",
                        // The suffix trick: a naive hasSuffix lets this through.
                        "https://example.com.ads.test/x"] {
            XCTAssertFalse(HostKey.isSameSite(URL(string: blocked)!, as: watching),
                           blocked)
        }
    }

    /// The security case. A hardcoded list of 21 suffixes omitted most ccTLD
    /// second levels, so two unrelated sites under any of them reduced to the
    /// same registrable domain, compared equal, and a cross-site redirect was
    /// let through — the exact thing isSameSite exists to stop.
    func testUnrelatedSitesUnderACcTLDSuffixAreNeverSameSite() {
        for suffix in ["com.pl", "co.il", "com.ua", "com.pk", "co.th",
                       "com.vn", "com.ar", "com.ng", "co.uk", "com.au"] {
            let victim = URL(string: "https://victim.\(suffix)/watch")!
            let evil = URL(string: "https://evil.\(suffix)/ad")!
            XCTAssertFalse(HostKey.isSameSite(evil, as: victim),
                           "evil.\(suffix) counted as the same site as victim.\(suffix)")
            XCTAssertEqual(HostKey.registrableDomain("evil.\(suffix)"),
                           "evil.\(suffix)")
        }
    }

    /// And the same suffixes still resolve subdomains of ONE site together, or
    /// the fix would just break every per-site exception.
    func testSubdomainsUnderACcTLDSuffixStillMatch() {
        for suffix in ["com.pl", "co.uk", "com.au", "co.jp"] {
            let watching = URL(string: "https://www.site.\(suffix)/watch")!
            XCTAssertTrue(HostKey.isSameSite(
                URL(string: "https://cdn.site.\(suffix)/x")!, as: watching),
                "cdn.site.\(suffix) should be the same site as www.site.\(suffix)")
        }
    }

    func testRegistrableDomainKeepsMultiPartSuffixesIntact() {
        XCTAssertEqual(HostKey.registrableDomain("cdn.player.example.com"), "example.com")
        XCTAssertEqual(HostKey.registrableDomain("www.example.com"), "example.com")
        // Without this, every .co.uk site would count as the same site.
        XCTAssertEqual(HostKey.registrableDomain("www.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(HostKey.registrableDomain("bbc.co.uk"), "bbc.co.uk")
        XCTAssertNil(HostKey.registrableDomain("localhost"))
    }

    func testDifferentSitesUnderAMultiPartSuffixAreNotSameSite() {
        let watching = URL(string: "https://www.bbc.co.uk/iplayer")!
        XCTAssertTrue(HostKey.isSameSite(
            URL(string: "https://bbc.co.uk/x")!, as: watching))
        XCTAssertFalse(HostKey.isSameSite(
            URL(string: "https://ads.co.uk/x")!, as: watching))
    }

    func testNothingIsSameSiteWhenThereIsNoCurrentPage() {
        XCTAssertFalse(HostKey.isSameSite(
            URL(string: "https://example.com/x")!, as: nil))
    }

    // MARK: Persistence

    func testEverySettingSurvivesARestart() {
        let first = ProtectionSettings(store: defaults)
        first.level = .off
        first.privateBrowsing = true
        first.hasOnboarded = true
        first.addExemption("WWW.Example.com")

        // A fresh instance over the same storage is what a relaunch looks like.
        let second = ProtectionSettings(store: defaults)
        XCTAssertEqual(second.level, .off)
        XCTAssertTrue(second.privateBrowsing)
        XCTAssertTrue(second.hasOnboarded)
        XCTAssertEqual(second.exemptHosts, ["example.com"])
        XCTAssertTrue(second.isExempt("cdn.example.com"))
    }

    func testDefaultsAreProtectiveAndNotPrivate() {
        let settings = ProtectionSettings(store: defaults)
        XCTAssertEqual(settings.level, .standard)
        XCTAssertFalse(settings.privateBrowsing)
        XCTAssertFalse(settings.hasOnboarded)
        XCTAssertTrue(settings.exemptHosts.isEmpty)
    }

    // MARK: Exceptions

    func testExemptionsDoNotDuplicateAcrossSpellings() {
        let settings = ProtectionSettings(store: defaults)
        XCTAssertTrue(settings.addExemption("example.com"))
        XCTAssertFalse(settings.addExemption("WWW.Example.com."))
        XCTAssertEqual(settings.exemptHosts, ["example.com"])
    }

    func testRemovingAnExemptionAcceptsAnySpelling() {
        let settings = ProtectionSettings(store: defaults)
        settings.addExemption("example.com")
        settings.removeExemption("https://www.example.com/")
        XCTAssertTrue(settings.exemptHosts.isEmpty)
    }

    // MARK: Rule groups

    func testProtectionLevelsSelectTheirGroups() {
        XCTAssertTrue(RuleGroup.groups(for: .off).isEmpty)
        XCTAssertEqual(Set(RuleGroup.groups(for: .standard)),
                       [.ads, .privacy, .appSpecific])
        XCTAssertEqual(Set(RuleGroup.groups(for: .strict)),
                       Set(RuleGroup.allCases))
    }

    /// Strict has to add something. It was deleted once for selecting groups no
    /// bundled list filled, which made it a promise the app did not keep.
    func testStrictIsAStrictSupersetOfStandard() {
        let standard = Set(RuleGroup.groups(for: .standard))
        let strict = Set(RuleGroup.groups(for: .strict))
        XCTAssertTrue(standard.isSubset(of: strict))
        XCTAssertFalse(strict.subtracting(standard).isEmpty,
                       "strict adds no rule group over standard")
    }

    /// Every level must select a different set of lists. A level that silently
    /// behaves like its neighbour is worse than not offering it at all — which
    /// is exactly what `strict` did.
    func testEveryLevelDiffersFromTheOthers() {
        let selections = ProtectionLevel.allCases.map { Set(RuleGroup.groups(for: $0)) }
        XCTAssertEqual(Set(selections).count, ProtectionLevel.allCases.count,
                       "two protection levels select identical rule groups")
    }
}
