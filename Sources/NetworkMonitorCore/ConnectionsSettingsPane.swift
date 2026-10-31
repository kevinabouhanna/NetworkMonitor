import AppKit
import FirewallPolicy
import ServerDirectory
import SwiftUI

/// Settings › Connections (#126): where Connections is found, like every other
/// feature. What it is, website names while they're off, the rules, which
/// layout the window opens with, and where the names come from. The window
/// itself is where it's read, so today's companies are there, not here (#189).
struct ConnectionsSettingsPane: View {
    @ObservedObject var model: ConnectionsViewModel
    @ObservedObject var filter: FilterController
    @ObservedObject var firewall: FirewallRules
    @ObservedObject var geoData: GeoDataUpdater
    @ObservedObject var blocklists: BlocklistUpdater
    @ObservedObject var listBlocks: ListBlockCount
    let onOpen: () -> Void

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 12) {
                    Text("Which companies, countries and servers your apps talk to, on a list and a world map.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button("Open Connections…", action: onOpen)
                        .help("Also ⌘K, and the globe in the popover")
                }
            }

            // Where anyone who said "not now" in the welcome window finds it
            // again (#134). Once on, it runs with nothing to manage (#181).
            if filter.state != .unavailable {
                if filter.state.isOffered {
                    Section {
                        WebsiteNamesRow(filter: filter)
                    }
                }
                rulesSection
                listsSection
            }

            Section {
                LabeledContent("Opens with") {
                    Picker("Opens with", selection: Binding(get: { model.layout }, set: { model.layout = $0 })) {
                        ForEach(ConnectionsViewModel.Layout.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            Section {
                LabeledContent("Countries and networks") {
                    Text(GeoDataUpdater.dataSource(month: geoData.month)).foregroundStyle(.secondary)
                }
                // The app's one network access of its own (#121): on, and in
                // plain view, so it can be turned off.
                Toggle("Update them monthly", isOn: $geoData.isEnabled)
                    .toggleStyle(.switch)
                LabeledContent("Kept") {
                    Text("As long as Usage History").foregroundStyle(.secondary)
                }
            } footer: {
                SettingsFootnote("Everything is named on this Mac: nothing is looked up online. Once a month, "
                                 + "NetworkMonitor downloads DB-IP's new data from GitHub, the same file for "
                                 + "everyone, never on a hotspot. \(ServerDirectory.credit), CC BY 4.0.")
            }
        }
        .formStyle(.grouped)
    }

    /// Ads, trackers and malware, blocked by name in every app (#176).
    private var listsSection: some View {
        Section {
            ExplainedRow("Block ads and trackers", Self.listsExplanation) {
                Toggle("Block ads and trackers", isOn: Binding(
                    get: { !firewall.lists.isEmpty },
                    set: { model.setLists($0 ? Set(BlocklistTopic.allCases) : []) }))
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
                                    model.setLists(lists)
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
            Text("Ads and trackers")
        } footer: {
            SettingsFootnote(listsFootnote)
        }
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
        + "rules: Always Allow on a site in Connections lets it through. Ads served from a site's own servers, "
        + "like YouTube's, can't be told apart from the site, so they aren't blocked."
    static let updatesExplanation = "Once a week, NetworkMonitor downloads the lists from GitHub, the same signed "
        + "file for everyone, never on a hotspot."

    /// What's blocked and what's always allowed (#114), made by right-clicking
    /// a row in Connections, and taken back here.
    private var rulesSection: some View {
        Section {
            LabeledContent("Let apps connect") {
                Picker("Let apps connect", selection: Binding(get: { firewall.mode }, set: setMode)) {
                    Text("Anywhere").tag(FirewallMode.anywhere)
                    Text("Ask Me").tag(FirewallMode.ask)
                    Text("Only Where I Allow").tag(FirewallMode.onlyAllowed)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if firewall.rules.isEmpty {
                Text("Right-click a company, app, country or server in Connections to block it, or to "
                     + "always allow it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(firewall.rules) { rule in
                    LabeledContent {
                        HStack(spacing: 10) {
                            RuleBadge(action: rule.action, networkTitle: rule.networkTitle)
                            Button { firewall.remove(rule) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove this rule")
                        }
                    } label: {
                        Label {
                            Text(rule.title)
                            Text(Self.subjectName(rule.subject) + (rule.appTitle.map { " · for \($0)" } ?? "")
                                 + (rule.lastsUntilQuit ? ", until it quits" : ""))
                        } icon: {
                            Image(systemName: Self.symbol(rule.subject)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Blocking")
        } footer: {
            SettingsFootnote(footnote)
        }
    }

    private var footnote: String {
        let mode: String
        switch firewall.mode {
        case .anywhere:
            mode = "Everything connects except what you block."
        case .ask:
            mode = "The first time an app connects to a company, NetworkMonitor asks. With no answer in 30 "
                + "seconds, it's allowed. macOS and Apple's apps aren't asked about."
        case .onlyAllowed:
            mode = "Only what you allow connects, and macOS and Apple's apps. Allow an app under Blocked in "
                + "Connections."
        }
        guard filter.state == .on else { return mode + " This applies once “\(SetupCopy.websitesTitle)” is on." }
        return mode + " A rule applies from an app's next connection: one already open carries on until it closes."
    }

    /// Only Where I Allow cuts off every app not yet allowed, the browser
    /// included, so it asks first.
    private func setMode(_ mode: FirewallMode) {
        guard mode == .onlyAllowed, firewall.mode != .onlyAllowed else {
            firewall.mode = mode
            return
        }
        let alert = NSAlert()
        alert.messageText = "Only let apps connect where you allow?"
        alert.informativeText = "Every other app is blocked, your browser included, until you allow it: "
            + "choose Blocked in Connections and right-click it. macOS and Apple's apps can always connect, "
            + "and you can switch back here at any time."
        alert.addButton(withTitle: "Only Where I Allow")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { firewall.mode = mode }
    }

    static func subjectName(_ subject: RuleSubject) -> String {
        switch subject {
        case .company: return "Company"
        case .app:     return "App"
        case .country: return "Country"
        case .server:  return "Server"
        case .site:    return "Site"
        }
    }

    static func symbol(_ subject: RuleSubject) -> String {
        switch subject {
        case .company: return "building.2"
        case .app:     return "app"
        case .country: return "globe"
        case .server:  return "point.3.connected.trianglepath.dotted"
        case .site:    return "link"
        }
    }
}
