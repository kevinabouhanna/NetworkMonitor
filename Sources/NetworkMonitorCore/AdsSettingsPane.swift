import AppKit
import FirewallPolicy
import SwiftUI

/// Settings › Ads: ad blocking, a feature of its own, with a pane of its own
/// rather than a section of Connections. The switch, the built-in lists, how
/// many were blocked today, the lists and rules kept in Ads and Trackers, and
/// the lists' weekly update.
struct AdsSettingsPane: View {
    @ObservedObject var connections: ConnectionsViewModel
    @ObservedObject var filter: FilterController
    @ObservedObject var firewall: FirewallRules
    @ObservedObject var blocklists: BlocklistUpdater
    @ObservedObject var listBlocks: ListBlockCount
    @ObservedObject var library: ListLibrary
    let onOpenAds: (AdsViewModel.Tab) -> Void

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 12) {
                    Text("Ads, trackers and malware sites stopped in every app, and what was stopped, when and where.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button("Open Ads and Trackers…") { onOpenAds(.overview) }
                        .help("Also ⌘B, and the blocked-today line in the popover")
                }
            }

            if filter.state == .unavailable {
                Section {
                    Text("Ad blocking needs the content filter, which this build of NetworkMonitor doesn't have.")
                        .foregroundStyle(.secondary)
                }
            } else {
                listsSection
                if !firewall.lists.isEmpty { yoursSection }
            }
        }
        .formStyle(.grouped)
    }

    /// The switch and the built-in lists (#176).
    private var listsSection: some View {
        Section {
            ExplainedRow("Block ads and trackers", Self.listsExplanation) {
                Toggle("Block ads and trackers", isOn: Binding(
                    get: { !firewall.lists.isEmpty },
                    set: { connections.setLists($0 ? Set(BlocklistTopic.allCases) : []) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            if !firewall.lists.isEmpty {
                ForEach(BlocklistTopic.allCases, id: \.self) { topic in
                    LabeledContent {
                        HStack(spacing: 10) {
                            Text(siteCount(topic)).foregroundStyle(.secondary).monospacedDigit()
                            Toggle(topic.title, isOn: Binding(
                                get: { firewall.lists.contains(topic) },
                                set: { isOn in
                                    var lists = firewall.lists
                                    if isOn { lists.insert(topic) } else { lists.remove(topic) }
                                    connections.setLists(lists)
                                }))
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            ListTag(topic: topic)
                            Text(topic.title)
                        }
                    }
                }
                LabeledContent("Blocked today") {
                    Text(listBlocks.today.formatted()).foregroundStyle(.secondary).monospacedDigit()
                }
                ExplainedRow("Update them weekly", Self.updatesExplanation) {
                    Toggle("Update them weekly", isOn: $blocklists.isEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
        } header: {
            Text("Lists")
        } footer: {
            SettingsFootnote(listsFootnote)
        }
    }

    /// More lists (#254) and your rules (#253), kept in Ads and Trackers.
    private var yoursSection: some View {
        Section {
            LabeledContent("More lists") {
                HStack(spacing: 10) {
                    Text(moreLists).foregroundStyle(.secondary)
                    Button("Choose…") { onOpenAds(.lists) }
                        .help("HaGeZi, OISD, AdGuard's and others, or any list by its address")
                }
            }
            LabeledContent("Your rules") {
                HStack(spacing: 10) {
                    Text(rules).foregroundStyle(.secondary)
                    Button("Edit…") { onOpenAds(.rules) }
                        .help("Never block a site, always block one, or leave an app alone; import from uBlock Origin or AdGuard")
                }
            }
        } header: {
            Text("Yours")
        }
    }

    private var moreLists: String {
        if library.usesRecommended { return "Recommended" }
        let count = library.enabled.count
        return count == 0 ? "None" : "\(count) chosen by you"
    }

    private var rules: String {
        let count = firewall.adRules.count + firewall.listsPausedNetworks.count
        return count == 0 ? "None" : "\(count) rule\(count == 1 ? "" : "s")"
    }

    private func siteCount(_ topic: BlocklistTopic) -> String {
        let count = blocklists.lists?.tables[topic]?.count ?? 0
        return "\(topic.source) · \(count.formatted()) sites"
    }

    private var listsFootnote: String {
        let date = BlocklistUpdater.displayDate(blocklists.lists?.version).map { "Lists from \($0): " } ?? "Lists: "
        return date + "StevenBlack's hosts (MIT) and URLhaus by malware-filter (CC0)."
    }

    static let listsExplanation = "Connections to sites on these lists are blocked in every app, after your own "
        + "rules: Always Allow on a site in Connections lets it through. Allowing an app or a company lets it "
        + "connect, and its ads are still blocked. Ads served from a site's own servers, "
        + "like YouTube's, can't be told apart from the site, so they aren't blocked."
    static let updatesExplanation = "Once a week, NetworkMonitor downloads the lists from GitHub, the same signed "
        + "file for everyone, never on a hotspot."
}
