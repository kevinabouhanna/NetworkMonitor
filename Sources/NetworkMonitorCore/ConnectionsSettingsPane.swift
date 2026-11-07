import AppKit
import FilterProtocol
import FirewallPolicy
import ServerDirectory
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Connections (#126): where Connections is found, like every other
/// feature. What it is, website names while they're off, the rules, which
/// layout the window opens with, and where the names come from. The window
/// itself is where it's read, so today's companies are there, not here (#189).
struct ConnectionsSettingsPane: View {
    @ObservedObject var model: ConnectionsViewModel
    @ObservedObject var filter: FilterController
    @ObservedObject var firewall: FirewallRules
    @ObservedObject var geoData: GeoDataUpdater
    @ObservedObject var lookups: EncryptedLookups
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
                lookupsSection
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

    /// Encrypted lookups (#291): the system extension that filters also
    /// sends the Mac's lookups on encrypted, to a resolver picked here.
    private var lookupsSection: some View {
        Section {
            ExplainedRow("Encrypt lookups", Self.lookupsExplanation) {
                Toggle("Encrypt lookups", isOn: Binding(get: { lookups.isOn }, set: { lookups.setOn($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(filter.state != .on || lookups.state == .starting)
            }
            LabeledContent("Sent to") {
                Picker("Sent to", selection: $lookups.resolverID) {
                    ForEach(EncryptedDNS.resolvers) { Text($0.title).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
                .help(lookups.resolver.about)
            }
        } header: {
            Text("Lookups")
        } footer: {
            SettingsFootnote(lookupsFootnote)
        }
    }

    private var lookupsFootnote: String {
        switch lookups.state {
        case .failed(let reason): return reason
        case .starting:           return "Waiting for macOS, which asks you once to allow it."
        case .checking:           return "Checking names still resolve…"
        case .on:                 return "On. \(lookups.resolver.about)"
        case .off:
            return filter.state == .on
                ? "Off: lookups go to your network's DNS server unencrypted, as on any Mac."
                : "Needs the content filter on, which comes with it."
        }
    }

    static let lookupsExplanation = "Before an app connects to a site, your Mac looks its name up. Those lookups "
        + "normally travel unencrypted, so your internet provider and anyone on the Wi-Fi can read every name. "
        + "Switched on, NetworkMonitor sends each lookup encrypted to the resolver you pick, over DNS over HTTPS, "
        + "and gives the answer back unchanged. Names only your network knows, like the router's, still go to it. "
        + "If the resolver doesn't answer, lookups go to your network as before, so names keep working. Apps "
        + "that encrypt their own lookups, like Chrome with Secure DNS, aren't affected."

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
            // To another Mac, or a backup (#201).
            LabeledContent("Rules") {
                HStack(spacing: 8) {
                    Button("Export…", action: exportRules).disabled(firewall.rules.isEmpty)
                    Button("Import…", action: importRules)
                }
            }
        } header: {
            Text("Blocking")
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
            alert.messageText = "That file has no NetworkMonitor rules in it."
            alert.informativeText = "Choose a file made with Export… in Settings › Connections."
        }
        alert.runModal()
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
