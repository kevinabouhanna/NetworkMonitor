import AppKit
import FirewallPolicy
import ServerDirectory
import SwiftUI

/// Settings › Connections (#126): where Connections is found, like every other
/// feature. What it is, today's top companies at a glance, website names,
/// which layout the window opens with, and where the names come from. The
/// window itself is where it's read.
struct ConnectionsSettingsPane: View {
    @ObservedObject var model: ConnectionsViewModel
    @ObservedObject var glance: ConnectionsGlance
    @ObservedObject var filter: FilterController
    @ObservedObject var firewall: FirewallRules
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

            Section {
                if glance.companies.isEmpty {
                    Text(glance.hasLoaded ? "Nothing recorded yet today." : "Loading…")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(glance.companies) { company in
                        LabeledContent {
                            Text(ByteFormat.bytes(company.total)).monospacedDigit()
                        } label: {
                            HStack(spacing: 6) {
                                Text(company.title)
                                if company.isHost {
                                    Text("HOST")
                                        .font(.system(size: 8, weight: .bold))
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(Color.secondary.opacity(0.18), in: Capsule())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Today")
            } footer: {
                SettingsFootnote("The companies your apps sent the most data to today, as far as the network's "
                                 + "owner can tell.")
            }

            // Where anyone who said "not now" in the welcome window finds it
            // again (#134).
            if filter.state != .unavailable {
                Section {
                    WebsiteNamesRow(filter: filter, offersTurnOff: true)
                }
                rulesSection
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
                    Text(glance.dataSource).foregroundStyle(.secondary)
                }
                LabeledContent("Map") {
                    Text("Natural Earth").foregroundStyle(.secondary)
                }
                LabeledContent("Kept") {
                    Text("As long as Usage History").foregroundStyle(.secondary)
                }
            } footer: {
                SettingsFootnote("Everything is named on this Mac: nothing is looked up online. "
                                 + "\(ServerDirectory.credit), CC BY 4.0. Map outlines in the public domain.")
            }
        }
        .formStyle(.grouped)
        .onAppear { glance.reload() }
    }

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
                            RuleBadge(action: rule.action)
                            Button { firewall.remove(rule) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove this rule")
                        }
                    } label: {
                        Label {
                            Text(rule.title)
                            Text(Self.subjectName(rule.subject) + (rule.appTitle.map { " · for \($0)" } ?? ""))
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
        }
    }

    static func symbol(_ subject: RuleSubject) -> String {
        switch subject {
        case .company: return "building.2"
        case .app:     return "app"
        case .country: return "globe"
        case .server:  return "point.3.connected.trianglepath.dotted"
        }
    }
}

/// Today's top companies for the pane, loaded each time it's shown.
final class ConnectionsGlance: ObservableObject {
    @Published private(set) var companies: [ConnectionsItem] = []
    @Published private(set) var hasLoaded = false

    private let monitor: MonitorViewModel
    private let naming = DispatchQueue(label: "com.kevinabouhanna.NetworkMonitor.connections-glance",
                                       qos: .utility)
    private var directory: ServerDirectory?

    static let shown = 5

    init(monitor: MonitorViewModel) {
        self.monitor = monitor
    }

    /// "DB-IP Lite, October 2026", from the month the bundled data was built.
    var dataSource: String {
        guard let url = Bundle.main.url(forResource: "Geo", withExtension: nil)?.appendingPathComponent("MONTH"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "DB-IP Lite" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        guard let month = formatter.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return "DB-IP Lite"
        }
        return "DB-IP Lite, " + month.formatted(.dateTime.month(.wide).year())
    }

    func reload() {
        guard let history = monitor.store.history else {
            hasLoaded = true
            return
        }
        let today = HistoryPeriod(scale: .day, containing: Date())
        history.loadServers(in: today.interval, hoursOf: today.interval, filter: HistoryFilter()) { [weak self] report in
            guard let self else { return }
            self.naming.async {
                if self.directory == nil { self.directory = ServerDirectory.bundled() }
                let named = report.servers.map { Connection($0, directory: self.directory) }
                let top = ConnectionsReport.groups(named, by: .companies)
                    .map(\.item)
                    .filter { $0.key != ConnectionsReport.otherKey }
                    .prefix(Self.shown)
                DispatchQueue.main.async {
                    self.companies = Array(top)
                    self.hasLoaded = true
                }
            }
        }
    }
}
