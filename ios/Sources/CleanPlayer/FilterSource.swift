import Foundation

/// Which web view rule list a source feeds. Kept separate so one category can
/// be switched off when it breaks a site, without losing the others.
public enum RuleGroup: String, Codable, CaseIterable, Sendable {
    case ads
    case privacy
    /// Cookie banners, social widgets and other interruptions. Separated from
    /// `ads` because it is the group most likely to hide something wanted.
    case annoyances
    /// Hand-written rules for this app, always bundled, never downloaded.
    case appSpecific

    /// Groups active at each protection level.
    ///
    /// A group only exists here once a bundled list populates it. `strict` was
    /// deleted once for selecting `popups` and `siteExceptions` groups that no
    /// list filled, which made it identical to `standard` while the UI promised
    /// more. It is back because Fanboy's Annoyance is now shipped.
    public static func groups(for level: ProtectionLevel) -> [RuleGroup] {
        switch level {
        case .off:      return []
        case .standard: return [.ads, .privacy, .appSpecific]
        case .strict:   return allCases
        }
    }
}

public enum ProtectionLevel: String, Codable, CaseIterable, Sendable {
    case off
    case standard
    case strict

    public var title: String {
        switch self {
        case .off:      return "Off"
        case .standard: return "Standard"
        case .strict:   return "Strict"
        }
    }

    public var detail: String {
        switch self {
        case .off:
            return "No filtering. Use this only if a site will not work otherwise."
        case .standard:
            return "Blocks known advertising and tracking requests, and hides "
                 + "the elements they leave behind."
        case .strict:
            return "Also blocks cookie banners, social widgets and other "
                 + "annoyances. More is hidden, so more can go missing."
        }
    }
}

/// Where a filter list comes from, and the limits it must respect. Downloaded
/// lists are untrusted input, so the ceiling travels with the source rather
/// than living in the download code.
public struct FilterSource: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let url: URL
    public let repository: URL
    public let license: String
    public let attribution: String
    public let group: RuleGroup
    /// Response Content-Type must start with this.
    public let expectedContentType: String
    public let maxBytes: Int
    public var enabled: Bool

    public init(id: String, name: String, url: URL, repository: URL,
                license: String, attribution: String, group: RuleGroup,
                expectedContentType: String = "text/plain",
                maxBytes: Int = 12 * 1024 * 1024, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.url = url
        self.repository = repository
        self.license = license
        self.attribution = attribution
        self.group = group
        self.expectedContentType = expectedContentType
        self.maxBytes = maxBytes
        self.enabled = enabled
    }
}

/// What is known about the copy currently on disk.
public struct FilterState: Codable, Equatable, Sendable {
    public var sourceID: String
    public var lastUpdated: Date?
    public var checksum: String?
    public var etag: String?
    public var lastModified: String?
    /// The `! Version:` line from the list header, when present.
    public var version: String?

    public init(sourceID: String, lastUpdated: Date? = nil, checksum: String? = nil,
                etag: String? = nil, lastModified: String? = nil, version: String? = nil) {
        self.sourceID = sourceID
        self.lastUpdated = lastUpdated
        self.checksum = checksum
        self.etag = etag
        self.lastModified = lastModified
        self.version = version
    }
}

extension FilterSource {
    /// EasyList is dual-licensed GPL / CC BY-SA 3.0. Distributing rule data
    /// derived from it carries attribution and share-alike obligations that
    /// attach to the derived files — see NOTICE.md before shipping.
    public static let easyList = FilterSource(
        id: "easylist",
        name: "EasyList",
        url: URL(string: "https://easylist.to/easylist/easylist.txt")!,
        repository: URL(string: "https://github.com/easylist/easylist")!,
        license: "GPL-3.0 OR CC-BY-SA-3.0",
        attribution: "Filter rules from EasyList (easylist.to), used under CC BY-SA 3.0.",
        group: .ads
    )

    public static let easyPrivacy = FilterSource(
        id: "easyprivacy",
        name: "EasyPrivacy",
        url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!,
        repository: URL(string: "https://github.com/easylist/easylist")!,
        license: "GPL-3.0 OR CC-BY-SA-3.0",
        attribution: "Filter rules from EasyPrivacy (easylist.to), used under CC BY-SA 3.0.",
        group: .privacy
    )

    public static let annoyances = FilterSource(
        id: "annoyances",
        name: "Fanboy's Annoyance",
        url: URL(string: "https://easylist.to/easylist/fanboy-annoyance.txt")!,
        repository: URL(string: "https://github.com/easylist/easylist")!,
        license: "GPL-3.0 OR CC-BY-SA-3.0",
        attribution: "Filter rules from Fanboy's Annoyance List (easylist.to), "
            + "which includes the Cookie and Social lists, used under "
            + "CC BY-SA 3.0.",
        group: .annoyances
    )

    /// Compatibility exceptions, folded into every generated list rather than
    /// shipped as one of its own: WebKit applies `ignore-previous-rules` only
    /// inside the compiled list holding it, so a separate unbreak list would
    /// cancel nothing. Listed here for attribution, not as a list to compile.
    public static let braveUnbreak = FilterSource(
        id: "brave-unbreak",
        name: "Brave Unbreak",
        url: URL(string: "https://raw.githubusercontent.com/brave/adblock-lists/master/brave-unbreak.txt")!,
        repository: URL(string: "https://github.com/brave/adblock-lists")!,
        license: "MPL-2.0",
        attribution: "Site-compatibility exceptions from Brave Unbreak "
            + "(github.com/brave/adblock-lists), used under MPL-2.0.",
        group: .appSpecific
    )

    public static let all: [FilterSource] = [.easyList, .easyPrivacy, .annoyances]
}
