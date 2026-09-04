import CleanPlayer
import SwiftUI

struct HomeView: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var rules: RuleListController
    @ObservedObject var settings: ProtectionSettings
    @FocusState private var searchFocused: Bool
    @State private var showingSettings = false

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    searchField
                    if rules.status.isPreparing { preparingNote }
                    tiles(title: "Shortcuts", sites: model.shortcuts)
                    if !model.recents.isEmpty { recentsSection }
                }
                .padding(20)
                // iPad: a full-width list of one-line rows is unreadable and
                // the tile grid sprawls. Cap the measure and centre it.
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Cliqx")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(model: model, rules: rules, settings: settings)
            }
        }
    }

    /// The one-time first-launch state. Saying "basic blocking is already on"
    /// matters: the alternative reading is that nothing is protecting you yet.
    private var preparingNote: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Preparing full protection\u{2026} basic blocking is already on.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search or enter address", text: $model.address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.webSearch)
                .submitLabel(.go)
                .focused($searchFocused)
                .onSubmit { model.submitAddress() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    private func tiles(title: String, sites: [Site]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(sites) { site in
                    Button { model.open(site.url) } label: { tile(site) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(site.title), \(site.host)")
                }
            }
        }
    }

    private func tile(_ site: Site) -> some View {
        VStack(spacing: 6) {
            Text(site.initials)
                .font(.title2.weight(.semibold))
                .frame(width: 60, height: 60)
                .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 16))
            Text(site.title)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent").font(.headline)
                Spacer()
                Button("Clear", role: .destructive) { model.clearRecents() }
                    .font(.subheadline)
            }
            VStack(spacing: 0) {
                ForEach(model.recents) { site in
                    Button { model.open(site.url) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(site.title).lineLimit(1)
                                Text(site.host).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 10)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if site != model.recents.last { Divider() }
                }
            }
            .padding(.horizontal, 14)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
        }
    }
}
