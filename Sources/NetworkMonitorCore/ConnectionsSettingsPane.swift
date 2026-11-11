import AppKit
import FilterProtocol
import FirewallPolicy
import ServerDirectory
import SwiftUI
import UniformTypeIdentifiers

/// Connections' settings (#126): its setup only (#436). A line with today's
/// companies and the way to the window heads it; then website names while
/// they're off, the rules, encrypted lookups, which layout the window opens
/// with, and where the names come from. The window is where it's read (#189).
struct ConnectionsSettingsPane: View {
    @ObservedObject var model: ConnectionsViewModel
    @ObservedObject var filter: FilterController
    @ObservedObject var firewall: FirewallRules
    @ObservedObject var geoData: GeoDataUpdater
    @ObservedObject var lookups: EncryptedLookups
    @ObservedObject var glance: TodayGlance
    let onOpen: () -> Void

    var body: some View {
        Form {
            Section {
                SettingsStatusLine(title: statusTitle,
                                   detail: L("Which companies, countries and servers your apps talk to, on a list and a world map"),
                                   action: L("Open Connections…"), help: L("Also ⌘K, and Companies in the popover"),
                                   onAction: onOpen)
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
                lookupsSection
            }

            Section {
                LabeledContent(L("Opens with")) {
                    Picker(L("Opens with"), selection: Binding(get: { model.layout }, set: { model.layout = $0 })) {
                        ForEach(ConnectionsViewModel.Layout.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            Section {
                LabeledContent(L("Countries and networks")) {
                    Text(GeoDataUpdater.dataSource(month: geoData.month)).foregroundStyle(.secondary)
                }
                // The app's one network access of its own (#121): on, and in
                // plain view, so it can be turned off.
                Toggle(L("Update them monthly"), isOn: $geoData.isEnabled)
                    .toggleStyle(.switch)
                LabeledContent(L("Kept")) {
                    Text(L("As long as Usage History")).foregroundStyle(.secondary)
                }
            } footer: {
                SettingsFootnote(L("Everything is named on this Mac: nothing is looked up online. Once a month, NetworkMonitor downloads DB-IP's new data from GitHub, the same file for everyone, never on a hotspot. %@, CC BY 4.0.", GeoDataUpdater.credit))
            }
        }
        .formStyle(.grouped)
    }

    private var statusTitle: String {
        let count = glance.summary.companies
        return count == 1 ? L("1 company today") : L("%@ companies today", String(count))
    }

    /// Encrypted lookups (#291): the system extension that filters also
    /// sends the Mac's lookups on encrypted, to a resolver picked here.
    private var lookupsSection: some View {
        Section {
            ExplainedRow(L("Encrypt lookups"), Self.lookupsExplanation) {
                Toggle(L("Encrypt lookups"), isOn: Binding(get: { lookups.isOn }, set: { lookups.setOn($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(filter.state != .on || lookups.state == .starting)
            }
            LabeledContent(L("Sent to")) {
                Picker(L("Sent to"), selection: $lookups.resolverID) {
                    ForEach(EncryptedDNS.resolvers) { Text($0.title).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
                .help(Self.about(lookups.resolver))
            }
        } header: {
            Text(L("Lookups"))
        } footer: {
            SettingsFootnote(lookupsFootnote)
        }
    }

    private var lookupsFootnote: String {
        switch lookups.state {
        case .failed(let reason): return reason
        case .starting:           return L("Waiting for macOS, which asks you once to allow it.")
        case .checking:           return L("Checking names still resolve…")
        case .on:                 return L("On. %@", Self.about(lookups.resolver))
        case .off:
            return filter.state == .on
                ? L("Off: lookups go to your network's DNS server unencrypted, as on any Mac.")
                : L("Needs the content filter on, which comes with it.")
        }
    }

    static var lookupsExplanation: String { L("Before an app connects to a site, your Mac looks its name up. Those lookups normally travel unencrypted, so your internet provider and anyone on the Wi-Fi can read every name. Switched on, NetworkMonitor sends each lookup encrypted to the resolver you pick, over DNS over HTTPS, and gives the answer back unchanged. Names only your network knows, like the router's, still go to it. If the resolver doesn't answer, lookups go to your network as before, so names keep working. Apps that encrypt their own lookups, like Chrome with Secure DNS, aren't affected.") }

    /// A resolver's policy line, in the language shown. `EncryptedDNS` is in
    /// FilterProtocol, which can't call `L` (#433).
    static func about(_ resolver: EncryptedDNS.Resolver) -> String {
        switch resolver.id {
        case "cloudflare": return L("1.1.1.1. Keeps no record of your address, and deletes its logs within a day.")
        case "quad9":      return L("9.9.9.9. A Swiss non-profit; keeps no record of your address, and refuses known malware sites.")
        case "google":     return L("8.8.8.8. Deletes your address from its logs within two days.")
        default:           return resolver.about
        }
    }

    /// What's blocked and what's always allowed (#114), made by right-clicking
    /// a row in Connections, and taken back here.
    private var rulesSection: some View {
        Section {
            LabeledContent(L("Let apps connect")) {
                Picker(L("Let apps connect"), selection: Binding(get: { firewall.mode }, set: setMode)) {
                    Text(L("Anywhere")).tag(FirewallMode.anywhere)
                    Text(L("Ask Me")).tag(FirewallMode.ask)
                    Text(L("Only Where I Allow")).tag(FirewallMode.onlyAllowed)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if firewall.rules.isEmpty {
                Text(L("Right-click a company, app, country or server in Connections to block it, or to always allow it."))
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
                            .help(L("Remove this rule"))
                            // Which rule, as Tab goes down them (#455).
                            .accessibilityLabel(L("Remove the rule for %@", rule.shownTitle))
                        }
                    } label: {
                        Label {
                            Text(rule.shownTitle)
                            Text(Self.detail(rule))
                        } icon: {
                            Image(systemName: Self.symbol(rule.subject)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            // To another Mac, or a backup (#201).
            LabeledContent(L("Rules")) {
                HStack(spacing: 8) {
                    Button(L("Export…"), action: exportRules).disabled(firewall.rules.isEmpty)
                    Button(L("Import…"), action: importRules)
                }
            }
        } header: {
            Text(L("Blocking"))
        } footer: {
            SettingsFootnote(footnote)
        }
    }

    private func exportRules() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "NetworkMonitor Rules.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try firewall.exportData().write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func importRules() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        do {
            let result = try firewall.importRules(from: Data(contentsOf: url))
            alert.messageText = FirewallRules.importSummary(added: result.added, alreadyHere: result.alreadyHere)
            if result.added > 0, filter.state == .off { filter.turnOn() }
        } catch {
            alert.messageText = L("That file has no NetworkMonitor rules in it.")
            alert.informativeText = L("Choose a file made with Export… in Connections' settings.")
        }
        alert.runModal()
    }


    private var footnote: String {
        let mode: String
        switch firewall.mode {
        case .anywhere:
            mode = L("Everything connects except what you block.")
        case .ask:
            mode = L("The first time an app connects to a company, NetworkMonitor asks. With no answer in 30 seconds, it's allowed. macOS and Apple's apps aren't asked about.")
        case .onlyAllowed:
            mode = L("Only what you allow connects, and macOS and Apple's apps. Allow an app under Blocked in Connections.")
        }
        guard filter.state == .on else { return L("%@ This applies once “%@” is on.", mode, SetupCopy.websitesTitle) }
        return L("%@ A rule applies from an app's next connection: one already open carries on until it closes.", mode)
    }

    /// Only Where I Allow cuts off every app not yet allowed, the browser
    /// included, so it asks first.
    private func setMode(_ mode: FirewallMode) {
        guard mode == .onlyAllowed, firewall.mode != .onlyAllowed else {
            firewall.mode = mode
            return
        }
        let alert = NSAlert()
        alert.messageText = L("Only let apps connect where you allow?")
        alert.informativeText = L("Every other app is blocked, your browser included, until you allow it: choose Blocked in Connections and right-click it. macOS and Apple's apps can always connect, and you can switch back here at any time.")
        alert.addButton(withTitle: L("Only Where I Allow"))
        alert.addButton(withTitle: L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { firewall.mode = mode }
    }

    static func subjectName(_ subject: RuleSubject) -> String {
        switch subject {
        case .company: return L("Company")
        case .app:     return L("App")
        case .country: return L("Country")
        case .server:  return L("Server")
        case .site:    return L("Site")
        }
    }

    /// "Company · for Safari, until it quits".
    static func detail(_ rule: FirewallRule) -> String {
        let subject = subjectName(rule.subject)
        let forApp = rule.appTitle.map { L("%@ · for %@", subject, $0) } ?? subject
        return rule.lastsUntilQuit ? L("%@, until it quits", forApp) : forApp
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
