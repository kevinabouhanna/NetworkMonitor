import AppKit
import FirewallPolicy
import SwiftUI

/// What Connections' Show switch shows (#592): Traffic and Blocked read the
/// record; Rules lists what you decided.
enum ConnectionsShow: Hashable {
    case traffic, blocked, rules
}

extension ConnectionsViewModel {
    /// The switch's choice, from `measure` and `showsRules`.
    var show: ConnectionsShow {
        get { showsRules ? .rules : (measure == .bytes ? .traffic : .blocked) }
        set {
            showsRules = newValue == .rules
            switch newValue {
            case .traffic: measure = .bytes
            case .blocked: measure = .blocked
            case .rules:   loadRulesActivity()
            }
        }
    }

    /// What each rule did in the period, for the networks chosen.
    func loadRulesActivity(again: Bool = false) {
        rulesActivity.load(history, interval: period.interval, filter: HistoryFilter(kind: kind), again: again)
    }

    /// A rule's Show (#592): Traffic for what it lets through, Blocked for
    /// what it stops, narrowed to what it covers.
    func showRule(_ rule: FirewallRule) {
        for dimension in ConnectionsDimension.allCases { clear(dimension) }
        search = ""
        showsRules = false
        measure = rule.action == .allow ? .bytes : .blocked
        func item(_ dimension: ConnectionsDimension, _ key: String, _ title: String) -> ConnectionsItem {
            ConnectionsItem(dimension: dimension, key: key, title: title, subtitle: nil, isHost: false,
                            symbol: nil, bundlePath: nil)
        }
        if let app = rule.appKey { narrow(to: item(.app, app, rule.appTitle ?? app)) }
        switch rule.subject {
        case .company:
            grouping = .companies
            narrow(to: item(.company, rule.key, rule.shownTitle))
        case .app:
            grouping = .apps
            narrow(to: item(.app, rule.key, rule.shownTitle))
        case .country:
            grouping = .countries
            narrow(to: item(.country, rule.key, rule.shownTitle))
        case .server:
            narrow(to: item(.server, rule.key, rule.shownTitle))
        case .site:
            // Every name under it, as the rule covers them.
            search = rule.key
        }
    }

    /// A rule typed into the bar above Rules: a site, for every app or one.
    /// Like any rule, it needs the filter, and starts turning it on.
    func addSiteRule(_ action: RuleAction, site: String, app: AdsViewModel.RuleApp?) {
        if let app {
            firewall.add(FirewallRule(subject: .site, key: site, title: site, action: action,
                                      appKey: app.key, appTitle: app.name))
            switch filter.state {
            case .off, .failed:
                offersWebsiteNames = true
                filter.turnOn()
            default:
                break
            }
        } else {
            setSiteRule(action, domain: site, forName: site)
        }
    }

    /// Apps seen in the period, for the bar's menu.
    var ruleApps: [AdsViewModel.RuleApp] {
        var seen: [String: String] = [:]
        for connection in rulesActivity.traffic + rulesActivity.blocked where seen[connection.usage.appKey] == nil {
            seen[connection.usage.appKey] = connection.usage.appName
        }
        return seen.map { AdsViewModel.RuleApp(key: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// The site typed into a Rules bar, and the app it's for, until it's added.
final class RuleForm: ObservableObject {
    @Published var site = ""
    @Published var app: AdsViewModel.RuleApp?
    @Published var error: String?

    /// The site in it, or nil with a reason shown.
    func takeSite() -> String? {
        guard let site = AdRule.site(from: site) else {
            error = self.site.trimmingCharacters(in: .whitespaces).isEmpty
                ? L("Type a site first, like example.com.")
                : L("\"%@\" isn't a site name. Type one like example.com.", self.site)
            return nil
        }
        self.site = ""
        error = nil
        return site
    }
}

/// Connections' Rules (#592): every rule made in Connections, by what it
/// does, each with what it did in the period, a menu to change it, Show,
/// and −. Above them, a bar to add a site; below, the way to Ads and
/// Trackers' own rules.
struct ConnectionsRulesView: View {
    @ObservedObject var model: ConnectionsViewModel
    @ObservedObject var firewall: FirewallRules
    @ObservedObject var activity: RulesActivity
    /// Not `@State`; see `SettingsPaneState`.
    @StateObject private var form = RuleForm()

    init(model: ConnectionsViewModel) {
        self.model = model
        firewall = model.firewall
        activity = model.rulesActivity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PeriodHeading(title: model.title, figure: String(firewall.rules.count),
                          caption: firewall.rules.count == 1 ? L("rule") : L("rules"),
                          details: [modeLine])
                .padding(.bottom, 4)
            Divider()
            // In every build, as Ads and Trackers' add bar is (#638).
            AddRuleBar(site: $form.site, app: form.app, knownApps: model.ruleApps, error: form.error,
                       explanation: Self.explanation, onApp: { form.app = $0 },
                       onBlock: { add(.block) }, onAllow: { add(.allow) }, onEdit: { form.error = nil }) {
                EmptyView()
            }
            Divider()
            RulesList(sections: sections, inset: 0) { empty }
            Divider()
            OtherRulesLine(text: model.adRuleCount == 1 ? L("Ads and Trackers has 1 rule of its own.")
                                : L("Ads and Trackers has %@ rules of its own.", String(model.adRuleCount)),
                           action: model.onShowAdRules)
        }
        .onAppear { model.loadRulesActivity() }
        .onChange(of: model.period) { _ in model.loadRulesActivity() }
        .onChange(of: model.kind) { _ in model.loadRulesActivity() }
        // As Traffic does, while the period includes now.
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            if model.isCurrent { model.loadRulesActivity(again: true) }
        }
    }

    /// "Let apps connect: Anywhere", as Settings sets it.
    private var modeLine: String {
        switch firewall.mode {
        case .anywhere:    return L("Let apps connect: %@", L("Anywhere"))
        case .ask:         return L("Let apps connect: %@", L("Ask Me"))
        case .onlyAllowed: return L("Let apps connect: %@", L("Only Where I Allow"))
        }
    }

    private func add(_ action: RuleAction) {
        guard let site = form.takeSite() else { return }
        model.addSiteRule(action, site: site, app: form.app)
    }

    static var explanation: String { L("A rule for a site covers it and every name under it: example.com covers ads.example.com. Block stops every connection to it; Always Allow lets it through, even past the ad and tracker lists and Only Where I Allow. Rules for a company, an app, a country or a server are made by right-clicking one under Traffic or Blocked. A rule for one app wins over one for every app.") }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "list.bullet.rectangle").font(.system(size: 28)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(query.isEmpty ? L("No rules yet") : L("Nothing matches “%@”", query))
                .font(.system(size: 14, weight: .medium))
            if query.isEmpty {
                Text(L("Add a site above, or right-click a company, app, country or server under Traffic or Blocked to block it or always allow it."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
    }

    private var query: String { model.search.trimmingCharacters(in: .whitespaces) }

    // MARK: Rows

    private var sections: [RuleSection] {
        let rules = firewall.rules.filter(matches)
        return [
            RuleSection(id: "block", title: L("Blocked"), note: L("Never let through."),
                        rows: rules.filter { $0.action == .block }.map(row)),
            RuleSection(id: "hotspots", title: L("Blocked on hotspots"),
                        note: L("Stopped only while the Mac is on a hotspot."),
                        rows: rules.filter { $0.action == .blockOnHotspots }.map(row)),
            RuleSection(id: "allow", title: L("Always allowed"),
                        note: L("Let through, even past the lists and Only Where I Allow."),
                        rows: rules.filter { $0.action == .allow }.map(row)),
        ]
    }

    /// The toolbar's search, on Rules: what a rule is about, for, or on.
    private func matches(_ rule: FirewallRule) -> Bool {
        guard !query.isEmpty else { return true }
        return [rule.shownTitle, rule.key, rule.appTitle ?? "", rule.networkTitle ?? "",
                ConnectionsSettingsPane.subjectName(rule.subject)]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private func row(_ rule: FirewallRule) -> RuleRowModel {
        let title = rule.shownTitle
        var detail = ConnectionsSettingsPane.detail(rule)
        if let network = rule.networkTitle { detail = L("%@ · only on %@", detail, network) }
        return RuleRowModel(
            id: rule.id, icon: icon(rule), title: title, detail: detail,
            activity: activity.activity(of: rule).text,
            state: rule.networkTitle.map { L("%@ on %@", rule.action.badge, $0) } ?? rule.action.badge,
            tone: rule.networkTitle != nil ? .sometimes : Self.tone(rule.action),
            choices: RuleAction.allCases.map { action in
                RuleChoice(title: ConnectionsView.menuTitle(action), isCurrent: action == rule.action) {
                    var changed = rule
                    changed.action = action
                    firewall.add(changed)
                }
            },
            show: (rule.action == .allow ? L("Show in Traffic") : L("Show in Blocked"), { model.showRule(rule) }),
            removeTitle: L("Remove the rule for %@", title), removeHelp: L("Remove this rule"),
            remove: { firewall.remove(rule) })
    }

    static func tone(_ action: RuleAction) -> RuleRowModel.Tone {
        switch action {
        case .block:           return .blocked
        case .blockOnHotspots: return .sometimes
        case .allow:           return .allowed
        }
    }

    /// An app's own icon, where it's an app on this Mac; the subject's
    /// symbol otherwise.
    private func icon(_ rule: FirewallRule) -> RuleRowModel.Icon {
        if rule.subject == .app, rule.key.hasSuffix(".app"), FileManager.default.fileExists(atPath: rule.key) {
            return .image(NSWorkspace.shared.icon(forFile: rule.key))
        }
        return .symbol(ConnectionsSettingsPane.symbol(rule.subject))
    }
}
