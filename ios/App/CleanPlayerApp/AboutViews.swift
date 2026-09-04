import CleanPlayer
import SwiftUI

/// Reachable attribution is a licence obligation, not a courtesy: the shipped
/// rule data is a derived work of EasyList under CC BY-SA 3.0, and that licence
/// requires the credit to travel with it.
struct AttributionView: View {
    @ObservedObject var rules: RuleListController

    private static let ccBySA = URL(
        string: "https://creativecommons.org/licenses/by-sa/3.0/")!

    var body: some View {
        List {
            Section {
                Text("Cliqx's blocking rules are generated from "
                     + "EasyList and EasyPrivacy. Those lists are the work of "
                     + "the EasyList authors, not of this app.")
                .font(.footnote)
            }

            ForEach(rules.catalog.lists.filter { $0.attribution != nil }) { list in
                Section(list.name) {
                    Text(list.attribution ?? "")
                        .font(.footnote)
                    if let version = list.version {
                        row("Version", version)
                    }
                    row("Rules", list.ruleCount.formatted())
                    Link("easylist.to", destination: URL(string: "https://easylist.to")!)
                    Link("Licence: CC BY-SA 3.0", destination: Self.ccBySA)
                }
            }

            Section("Share-alike") {
                Text("The generated rule data in this app is a derived work of "
                     + "EasyList and EasyPrivacy and is redistributed under "
                     + "CC BY-SA 3.0. The obligation attaches to the rule data, "
                     + "not to the rest of the app.")
                .font(.footnote)
                Link("Source lists on GitHub",
                     destination: URL(string: "https://github.com/easylist/easylist")!)
            }

            Section("Build tools") {
                Text("Rules are converted to WebKit content-blocker format by "
                     + "Brave's adblock-rust (MPL-2.0). It runs at build time "
                     + "and is not part of the app.")
                .font(.footnote)
                Link("brave/adblock-rust",
                     destination: URL(string: "https://github.com/brave/adblock-rust")!)
            }

            Section("Cliqx rules") {
                Text("The hand-written list bundled with the app was written "
                     + "for this project and carries no third-party obligation.")
                .font(.footnote)
            }
        }
        .navigationTitle("Attribution")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Shown in-app because the app has no server to host a page on. The same text
/// lives in PRIVACY.md, which is what gets published to give the App Store
/// listing the URL it requires.
struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                paragraph("The short version",
                          "Cliqx has no account, no server and no "
                          + "analytics. Nothing you do in the app is sent "
                          + "anywhere by the app.")

                paragraph("What stays on your device",
                          "Your recent sites, your protection level and your "
                          + "per-site exceptions are stored on this device "
                          + "only. Clearing them in Settings removes them.")

                paragraph("What the app sends",
                          "Only the web requests you cause by visiting a page. "
                          + "Those go to the sites you open, exactly as they "
                          + "would in any browser — minus the advertising and "
                          + "tracking requests the filter lists block.")

                paragraph("What is not collected",
                          "No browsing history leaves the device. No "
                          + "identifiers, no advertising ID, no location, no "
                          + "contacts. There are no third-party SDKs in the "
                          + "app, so nothing is collected on anyone else's "
                          + "behalf either.")

                paragraph("Filter lists",
                          "The blocking rules are bundled with the app and "
                          + "update when the app updates. The app does not "
                          + "phone home to fetch them.")

                paragraph("Private browsing",
                          "With private browsing on, cookies, cache and site "
                          + "storage are kept in memory and discarded rather "
                          + "than written to disk.")

                paragraph("Children",
                          "The app opens whatever the web address you enter "
                          + "points to. It does not filter content for age.")
            }
            .padding(20)
        }
        .navigationTitle("Privacy policy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func paragraph(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(body).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
