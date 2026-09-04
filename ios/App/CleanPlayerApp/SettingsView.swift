import CleanPlayer
import SwiftUI

/// Everything `ProtectionLevel`, `RuleGroup` and `ProtectionSettings` describe,
/// made reachable. Until this existed the protection model was real but
/// invisible, which is the same as not existing.
struct SettingsView: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var rules: RuleListController
    @ObservedObject var settings: ProtectionSettings

    /// The site the user was on when they opened Settings, if any. Per-site
    /// controls only make sense with one.
    var currentHost: String?

    /// Called after a change that only takes effect on the next load. Rules
    /// apply at navigation time, so without this the user changes a setting,
    /// sees the page in front of them keep its ads, and concludes it is broken.
    var onProtectionChanged: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var clearedData = false

    var body: some View {
        NavigationStack {
            Form {
                protectionSection
                if !settings.exemptHosts.isEmpty { exceptionsSection }
                privacySection
                listsSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: Protection

    private var protectionSection: some View {
        Section {
            Picker("Protection", selection: $settings.level) {
                ForEach(ProtectionLevel.allCases, id: \.self) { level in
                    Text(level.title).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: settings.level) { _, level in
                Task {
                    await rules.activate(level)
                    onProtectionChanged?()
                }
            }

            Text(settings.level.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)

            statusRow
        } header: {
            Text("Protection")
        } footer: {
            Text("Rules apply when a page loads, so the current page reloads "
                 + "when you change this.")
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch rules.status {
        case .ready(let count):
            label("checkmark.shield.fill", .green, "Active",
                  "\(count.formatted()) rules")
        case .preparing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Preparing full protection\u{2026}")
                Spacer()
            }
            .accessibilityElement(children: .combine)
        case .degraded(let failed, let count):
            label("exclamationmark.shield.fill", .orange, "Limited",
                  "\(count.formatted()) rules \u{2022} "
                  + "\(failed.joined(separator: ", ")) unavailable")
        case .off:
            label("shield.slash", .secondary, "Off", "No filtering")
        case .idle:
            label("shield", .secondary, "Starting\u{2026}", "")
        }
    }

    private func label(_ symbol: String, _ tint: Color,
                       _ title: String, _ detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(title)
            Spacer()
            if !detail.isEmpty {
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Protection \(title). \(detail)")
    }

    // MARK: Per-site

    private var exceptionsSection: some View {
        Section {
            ForEach(settings.exemptHosts, id: \.self) { host in
                Text(host)
            }
            .onDelete { offsets in
                for index in offsets {
                    settings.removeExemption(settings.exemptHosts[index])
                }
                if let host = currentHost {
                    rules.setSuspended(settings.isExempt(host))
                    onProtectionChanged?()
                }
            }
        } header: {
            Text("Sites without protection")
        } footer: {
            Text("An exception also covers subdomains. Swipe to remove.")
        }
    }

    // MARK: Privacy

    private var privacySection: some View {
        Section {
            Toggle("Private browsing", isOn: $settings.privateBrowsing)
            Button("Clear recent sites", role: .destructive) {
                model.clearRecents()
            }
            .disabled(model.recents.isEmpty)
            Button(clearedData ? "Website data cleared" : "Clear website data",
                   role: .destructive) {
                Task {
                    await BrowserModel.clearWebsiteData()
                    clearedData = true
                }
            }
            .disabled(clearedData)
        } header: {
            Text("Privacy")
        } footer: {
            Text("Private browsing keeps cookies, cache and site storage in "
                 + "memory only. Turning it on or off reloads the page you "
                 + "are on.")
        }
    }

    // MARK: Filter lists

    private var listsSection: some View {
        Section {
            if rules.catalog.isStale() {
                Label {
                    Text("These rules are out of date. Update the app to get "
                         + "current ones.")
                        .font(.footnote)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .accessibilityElement(children: .combine)
            }
            ForEach(rules.catalog.lists) { list in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(list.name)
                        Spacer()
                        Text("\(list.ruleCount.formatted()) rules")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let version = list.version {
                        Text("Version \(version)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Filter lists")
        } footer: {
            Text(listsFooter)
        }
    }

    private var listsFooter: String {
        guard let converted = rules.catalog.convertedAt else {
            return "Rules are bundled with the app."
        }
        let age = RelativeDateTimeFormatter()
        age.unitsStyle = .full
        return "Rules are bundled with the app and were generated "
            + "\(age.localizedString(for: converted, relativeTo: Date())). "
            + "They update when the app updates."
    }

    // MARK: About

    private var aboutSection: some View {
        Section("About") {
            NavigationLink("Attribution and licences") { AttributionView(rules: rules) }
            NavigationLink("Privacy policy") { PrivacyPolicyView() }
            HStack {
                Text("Version")
                Spacer()
                Text(Self.appVersion).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
