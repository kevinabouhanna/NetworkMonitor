import AppKit
import FirewallPolicy
import SwiftUI

/// Ads and Trackers' settings: every switch, list and rule for ad blocking, in one place
/// (#436). Today's number and a way to the Ads and Trackers window head it;
/// below are the switch, the weekly update, and the lists and your rules that
/// were tabs in the window, so nothing about ad blocking lives in two places.
struct AdsSettingsPane: View {
    @ObservedObject var ads: AdsViewModel
    @ObservedObject var connections: ConnectionsViewModel
    @ObservedObject var filter: FilterController
    @ObservedObject var firewall: FirewallRules
    @ObservedObject var blocklists: BlocklistUpdater
    @ObservedObject var listBlocks: ListBlockCount
    let onOpenAds: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    SettingsStatusLine(title: status, detail: statusDetail,
                                       action: L("Open Ads and Trackers…"), help: L("Also ⌘B"), onAction: onOpenAds)
                }
                // A build without the filter still shows and keeps every setting,
                // for the signed app to apply, and says so.
                if filter.state == .unavailable {
                    Section {
                        Text(L("This build has no content filter: the lists and rules here are kept, and apply when the signed app runs."))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                    Section {
                        ExplainedRow(L("Block ads and trackers"), Self.listsExplanation) {
                            Toggle(L("Block ads and trackers"), isOn: Binding(
                                get: { !firewall.lists.isEmpty },
                                set: { connections.setLists($0 ? Set(BlocklistTopic.allCases) : []) }))
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                        ExplainedRow(L("Update the lists weekly"), Self.updatesExplanation) {
                            Toggle(L("Update the lists weekly"), isOn: $blocklists.isEnabled)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                    } footer: {
                        SettingsFootnote(listsFootnote)
                    }
                    Section {
                        Picker(L("Show"), selection: $ads.setupTab) {
                            ForEach(AdsViewModel.SetupTab.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                    }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            do {
                // The window's own views, as they were: they scroll inside a
                // fixed height, so the pane is the same size every time.
                Group {
                    if ads.setupTab == .lists { AdsListsView(model: ads) } else { AdsRulesView(model: ads) }
                }
                .frame(height: SettingsMetrics.adsSetupHeight)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }

    private var status: String {
        guard !firewall.lists.isEmpty else { return L("Ad blocking is off") }
        return L("%@ blocked today", listBlocks.today.formatted())
    }

    private var statusDetail: String {
        guard !firewall.lists.isEmpty else { return L("Switch it on below to stop ads, trackers and malware sites in every app.") }
        return L("Ads, trackers and malware sites stopped in every app")
    }

    private var listsFootnote: String {
        guard let date = BlocklistUpdater.displayDate(blocklists.lists?.version) else {
            return L("Lists: StevenBlack's hosts (MIT) and URLhaus by malware-filter (CC0).")
        }
        return L("Lists from %@: StevenBlack's hosts (MIT) and URLhaus by malware-filter (CC0).", date)
    }

    static var listsExplanation: String { L("Connections to sites on these lists are blocked in every app, after your own rules: Always Allow on a site in Connections lets it through. Allowing an app or a company lets it connect, and its ads are still blocked. Ads served from a site's own servers, like YouTube's, can't be told apart from the site, so they aren't blocked.") }
    static var updatesExplanation: String { L("Once a week, NetworkMonitor downloads the lists from GitHub, the same signed file for everyone, never on a hotspot.") }
}

/// The line that heads a feature's pane of Settings (#436): the number that
/// matters today, a sentence, and the way to the feature's window. Settings
/// itself holds only setup; the numbers live in the popover and the windows.
struct SettingsStatusLine: View {
    let title: String
    let detail: String
    let action: String
    let help: String
    let onAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            Button(action, action: onAction).help(help)
        }
    }
}
