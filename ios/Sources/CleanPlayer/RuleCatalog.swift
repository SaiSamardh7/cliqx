import CryptoKit
import Foundation

public enum RuleCatalogError: Error, Equatable {
    case resourceMissing(String)
    case decompressionFailed(String)
    case notUTF8(String)
}

/// One compilable content-rule list that ships inside the app bundle.
public struct BundledRuleList: Sendable, Identifiable, Hashable {
    public let id: String
    public let group: RuleGroup
    /// Bundle resource name, without extension.
    public let resource: String
    /// SHA-256 of the *uncompressed* JSON.
    ///
    /// This is the whole reason a stale compile cannot survive a rule update:
    /// the hash is part of `compiledIdentifier`, so regenerating the rules
    /// produces a new identifier and WebKit compiles afresh instead of
    /// returning the cached list forever.
    public let contentHash: String
    public let ruleCount: Int
    /// Human-facing name and provenance, for the Settings readout and the
    /// attribution screen. `nil` for the hand-written list, which has neither
    /// an upstream version nor an upstream author.
    public let name: String
    public let version: String?
    public let attribution: String?

    public init(id: String, group: RuleGroup, resource: String,
                contentHash: String, ruleCount: Int,
                name: String? = nil, version: String? = nil,
                attribution: String? = nil) {
        self.id = id
        self.group = group
        self.resource = resource
        self.contentHash = contentHash
        self.ruleCount = ruleCount
        self.name = name ?? id
        self.version = version
        self.attribution = attribution
    }

    /// The key WebKit caches the compiled list under.
    public var compiledIdentifier: String { "cp.\(id).\(contentHash.prefix(16))" }
}

/// Where the rule files are.
///
/// The app reads them out of its bundle, which flattens `Resources/rules/` into
/// the `.app` root. Tests read the same files straight from the repository, so
/// what is tested is what ships rather than a copy that can drift.
public enum RuleLocation {
    case bundle(Bundle)
    /// The directory and its immediate subdirectories.
    case directory(URL)

    func url(for resource: String, extension ext: String) -> URL? {
        switch self {
        case .bundle(let bundle):
            return bundle.url(forResource: resource, withExtension: ext)
        case .directory(let root):
            let manager = FileManager.default
            let direct = root.appendingPathComponent("\(resource).\(ext)")
            if manager.fileExists(atPath: direct.path) { return direct }
            let children = (try? manager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for child in children {
                let nested = child.appendingPathComponent("\(resource).\(ext)")
                if manager.fileExists(atPath: nested.path) { return nested }
            }
            return nil
        }
    }
}

/// Loads rule JSON.
///
/// The generated lists ship raw-DEFLATE compressed — 14MB of JSON becomes
/// ~1.3MB of bundle. Decompression only happens on a cache miss (first launch,
/// or after the rules are regenerated), because `compiledIdentifier` comes from
/// the manifest and can be looked up without touching the payload.
public enum RuleData {
    public static let compressedExtension = "json.deflate"

    public static func load(_ resource: String,
                            at location: RuleLocation) throws -> String {
        if let url = location.url(for: resource, extension: compressedExtension) {
            let raw = try Data(contentsOf: url)
            guard let inflated = try? (raw as NSData).decompressed(using: .zlib)
            else { throw RuleCatalogError.decompressionFailed(resource) }
            guard let text = String(data: inflated as Data, encoding: .utf8)
            else { throw RuleCatalogError.notUTF8(resource) }
            return text
        }
        // Uncompressed fallback, so a build that skipped the compression step
        // still runs rather than silently shipping no rules.
        if let url = location.url(for: resource, extension: "json") {
            return try String(contentsOf: url, encoding: .utf8)
        }
        throw RuleCatalogError.resourceMissing(resource)
    }

    public static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// What the app knows about its bundled rules before it reads any of them.
///
/// Built from `rules/manifest.json`, which the converter writes alongside the
/// generated JSON. Reading a 700-byte manifest instead of 14MB of rules is what
/// makes the cached-compile fast path actually fast.
public struct RuleCatalog: Sendable {
    public let lists: [BundledRuleList]
    /// When the converter last ran. Drives the "rules are N weeks old" readout,
    /// which is the only honest signal available while refresh is a build-time
    /// step rather than a runtime one.
    public let convertedAt: Date?

    public init(lists: [BundledRuleList], convertedAt: Date? = nil) {
        self.lists = lists
        self.convertedAt = convertedAt
    }

    /// EasyList publishes several times a week. Rules cannot refresh at
    /// runtime here — the converter is a build-time tool — so the only honest
    /// thing to do is say when they have gone stale rather than let protection
    /// quietly decay behind an "Active" label.
    public static let staleAfter: TimeInterval = 30 * 24 * 60 * 60

    public func isStale(now: Date = Date()) -> Bool {
        guard let convertedAt else { return false }
        return now.timeIntervalSince(convertedAt) >= Self.staleAfter
    }

    public func lists(for level: ProtectionLevel) -> [BundledRuleList] {
        let groups = Set(RuleGroup.groups(for: level))
        return lists.filter { groups.contains($0.group) }
    }

    public var generated: [BundledRuleList] {
        lists.filter { $0.group != .appSpecific }
    }

    // MARK: Loading

    private struct Manifest: Decodable {
        struct Source: Decodable {
            let generated: String
            let ruleCount: Int
            let generatedSha256: String
            let version: String?
        }
        let sources: [String: Source]
        let convertedAt: String?
    }

    /// Group for each converter output. A source that is not listed here is
    /// ignored rather than guessed at.
    private static let groupsByFile: [String: RuleGroup] = [
        "ads.json": .ads,
        "privacy.json": .privacy,
        "annoyances.json": .annoyances,
    ]

    public static func bundled(in bundle: Bundle = .main) -> RuleCatalog {
        load(at: .bundle(bundle))
    }

    public static func load(at location: RuleLocation) -> RuleCatalog {
        var lists: [BundledRuleList] = []

        // The hand-written list is small enough to hash on the spot, and it has
        // no manifest entry because it is not generated.
        if let text = try? RuleData.load("blocklist", at: location) {
            lists.append(BundledRuleList(
                id: "appSpecific", group: .appSpecific, resource: "blocklist",
                contentHash: RuleData.hash(text),
                ruleCount: ruleCount(in: text),
                name: "Cliqx rules"))
        }

        var convertedAt: Date?
        if let url = location.url(for: "manifest", extension: "json"),
           let data = try? Data(contentsOf: url),
           let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
            convertedAt = manifest.convertedAt.flatMap {
                ISO8601DateFormatter().date(from: $0)
                    ?? ISO8601DateFormatter.withFractionalSeconds.date(from: $0)
            }
            for (id, source) in manifest.sources.sorted(by: { $0.key < $1.key }) {
                guard let group = groupsByFile[source.generated] else { continue }
                let resource = (source.generated as NSString).deletingPathExtension
                let upstream = FilterSource.all.first { $0.id == id }
                lists.append(BundledRuleList(
                    id: id, group: group, resource: resource,
                    contentHash: source.generatedSha256,
                    ruleCount: source.ruleCount,
                    name: upstream?.name ?? id,
                    version: source.version,
                    attribution: upstream?.attribution))
            }
        }
        return RuleCatalog(lists: lists, convertedAt: convertedAt)
    }

    private static func ruleCount(in json: String) -> Int {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return 0 }
        return array.count
    }
}

extension ISO8601DateFormatter {
    /// The converter writes fractional seconds; the default parser rejects them.
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
