import AppKit
import FirewallPolicy
import SwiftUI

extension AdsViewModel {
    /// What each rule did in the period.
    func loadRulesActivity(again: Bool = false) {
        rulesActivity.load(monitor.store.history, interval: period.interval, again: again)
    }

    /// How many rules Connections has, for the line under these (#592).
    var connectionRuleCount: Int { firewall.rules.count }

    /// How many rules Rules lists: sites, apps and networks.
    var ruleCount: Int { adRules.count + pausedNetworks.count }

    /// A rule's Show (#592): Overview for a site it blocks, the log for one
    /// it lets through or an app it leaves alone, searched for it.
    func showRule(_ rule: AdRule) {
        clearSelection()
        if rule.kind == .alwaysBlock, let site = rule.site {
            tab = .overview
            grouping = .sites
            logSearch = site
        } else {
            tab = .log
            logSearch = rule.site ?? rule.appTitle ?? (rule.appKey.map { ($0 as NSString).lastPathComponent } ?? "")
        }
    }
}

/// Ads and Trackers' Rules (#592): your say over ad blocking, laid out as
/// Connections' Rules are: sites blocked and always allowed, apps not
/// filtered and networks where it's off, each with what it did in the
/// period, a menu to change it, Show, and −. Above them, the bar to add a
/// site; below, the way to Connections' own rules.
struct AdsRulesPage: View {
    @ObservedObject var model: AdsViewModel
    @ObservedObject var activity: RulesActivity

    init(model: AdsViewModel) {
        self.model = model
        activity = model.rulesActivity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // When, how many, and whether they apply now, as Connections'
            // Rules say theirs.
            PeriodHeading(title: model.title, figure: String(model.ruleCount),
                          caption: model.ruleCount == 1 ? L("rule") : L("rules"), details: [stateLine])
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
            Divider()
            AddRuleBar(site: $model.newSite, app: model.newSiteApp, knownApps: model.knownApps,
                       error: model.ruleError, explanation: Self.explanation,
                       onApp: { model.newSiteApp = $0 },
                       onBlock: { model.addSite(.alwaysBlock) }, onAllow: { model.addSite(.neverBlock) },
                       onEdit: { model.clearRuleError() }) {
                Button(L("Don't Filter an App…")) {
                    if let app = AddRuleBarPicker.pickApp() { model.dontFilter(app) }
                }
                .help(L("Choose an app whose connections the lists should leave alone, such as a bank's app that breaks"))
            }
            .padding(.horizontal, 20)
            Divider()
            RulesList(sections: sections) { empty }
            Divider()
            HStack(spacing: 0) {
                OtherRulesLine(text: model.connectionRuleCount == 1 ? L("Connections has 1 rule of its own.")
                                    : L("Connections has %@ rules of its own.", String(model.connectionRuleCount)),
                               action: model.onShowConnectionRules)
                if !model.isOn {
                    Text(L("Rules apply while ad blocking is on.")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
        }
        .onAppear { model.loadRulesActivity() }
        .onChange(of: model.period) { _ in model.loadRulesActivity() }
        // As Overview does, while the period includes now.
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            if model.period.contains(Date()) { model.loadRulesActivity(again: true) }
        }
    }

    /// "Blocking ads", "Paused until 10:51 AM": whether the rules apply now.
    private var stateLine: String {
        if !model.isOn { return L("Ad blocking is off") }
        if let until = model.pausedUntil { return L("Paused until %@", until.formatted(date: .omitted, time: .shortened)) }
        if let network = model.pausedHere { return L("Off on %@", network) }
        return L("Blocking ads")
    }

    static var explanation: String { L("A rule covers the site and every name under it: example.com covers ads.example.com. Rules change only what the ad and tracker lists do. Block stops a site no list has, and Always Allow lets a listed site through. Malware and phishing lists still block whatever these rules say. A rule for one app wins over one for every app. Connections' own rules apply too: a block there still blocks, and Always Allow on a site there lets it through.") }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "list.bullet.rectangle").font(.system(size: 28)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(query.isEmpty ? L("No rules yet") : L("Nothing matches “%@”", query))
                .font(.system(size: 14, weight: .medium))
            if query.isEmpty {
                Text(L("Add a site above, or right-click one in the Overview or the Log to block it or always allow it."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
    }

    private var query: String { model.logSearch.trimmingCharacters(in: .whitespaces) }

    // MARK: Rows

    private var sections: [RuleSection] {
        let rules = model.adRules.filter(matches)
        let networks = model.pausedNetworks.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        return [
            RuleSection(id: "block", title: L("Blocked"), note: L("Blocked even when no list has them."),
                        rows: rules.filter { $0.kind == .alwaysBlock }.map(row)),
            RuleSection(id: "allow", title: L("Always allowed"), note: L("Let through even when a list has them."),
                        rows: rules.filter { $0.kind == .neverBlock && $0.site != nil }.map(row)),
            RuleSection(id: "apps", title: L("Apps not filtered"),
                        note: L("The lists leave these apps' connections alone."),
                        rows: rules.filter(\.skipsApp).map(row)),
            RuleSection(id: "networks", title: L("Networks"), note: L("Ad blocking is off whenever the Mac is on these."),
                        rows: networks.map(row)),
        ]
    }

    private func matches(_ rule: AdRule) -> Bool {
        guard !query.isEmpty else { return true }
        return [rule.site ?? "", rule.appTitle ?? "", rule.appKey ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private func appName(_ rule: AdRule) -> String {
        rule.appTitle ?? rule.appKey.map { ($0 as NSString).lastPathComponent } ?? ""
    }

    private func row(_ rule: AdRule) -> RuleRowModel {
        let title = rule.site ?? appName(rule)
        let app = rule.appKey.map { AdsViewModel.RuleApp(key: $0, name: appName(rule)) }
        let detail: String
        if rule.skipsApp {
            detail = L("App")
        } else {
            detail = rule.appKey == nil ? L("Site · in every app") : L("Site · in %@", appName(rule))
        }
        let icon: RuleRowModel.Icon = rule.skipsApp
            ? model.icon(forBundle: rule.appKey).map(RuleRowModel.Icon.image) ?? .symbol("app")
            : .symbol("link")
        return RuleRowModel(
            id: rule.id, icon: icon, title: title, detail: detail,
            activity: activity.activity(of: rule).text,
            state: rule.skipsApp ? L("Not filtered") : (rule.kind == .alwaysBlock ? L("Blocked") : L("Always allowed")),
            tone: rule.kind == .alwaysBlock ? .blocked : .allowed,
            choices: rule.site.map { site in
                [RuleChoice(title: L("Block"), isCurrent: rule.kind == .alwaysBlock) {
                    model.setSite(.alwaysBlock, site: site, app: app)
                 },
                 RuleChoice(title: L("Always Allow"), isCurrent: rule.kind == .neverBlock) {
                    model.setSite(.neverBlock, site: site, app: app)
                 }]
            } ?? [],
            show: (rule.kind == .alwaysBlock && rule.site != nil ? L("Show in Overview") : L("Show in Log"),
                   { model.showRule(rule) }),
            removeTitle: L("Remove the rule for %@", title), removeHelp: L("Remove this rule"),
            remove: { model.remove(rule) })
    }

    private func row(_ network: (id: String, name: String)) -> RuleRowModel {
        RuleRowModel(
            id: "network:" + network.id, icon: .symbol("wifi"), title: network.name,
            detail: network.id == model.currentNetwork?.id ? L("The network you're on") : L("Network"),
            activity: nil, state: L("Ad blocking off"), tone: .sometimes, choices: [], show: nil,
            removeTitle: L("Block ads on %@ again", network.name), removeHelp: L("Block ads on this network again"),
            remove: { model.resumeOnNetwork(network.id) })
    }
}

/// Bringing rules over (#253): paste or choose a file, then see what it
/// brings before anything changes. From Ads and Trackers' settings (#592).
struct AdsImportSheet: View {
    @ObservedObject var model: AdsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let preview = model.importPreview {
                summary(preview)
            } else {
                entry
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var entry: some View {
        Group {
            Text(L("Bring Rules Over")).font(.system(size: 15, weight: .semibold))
            Text(L("Choose uBlock Origin's backup (its Settings › Back up to file), AdGuard's exported settings, or a file of rules. Or paste rules below, one a line."))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $model.importText)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 160)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                .accessibilityLabel(L("Rules to bring over"))
            if let error = model.importError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
            HStack {
                Button(L("Choose File…")) { chooseFile() }
                Spacer()
                Button(L("Cancel")) { model.cancelImport() }.keyboardShortcut(.cancelAction)
                Button(L("Continue")) { model.readImportText() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func summary(_ preview: AdImport) -> some View {
        Group {
            Text(L("From %@", preview.source)).font(.system(size: 15, weight: .semibold))
            if preview.summary.isEmpty {
                Text(L("Nothing new to bring over.")).font(.system(size: 13))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(preview.summary, id: \.self) { Text("• " + $0) }
                }
                .font(.system(size: 13))
            }
            if preview.hasTrustedSites {
                Text(L("Trusted sites become always allowed: connections to the site itself go through. Ads its pages load from other sites are still blocked, since the filter can't tell which page asked."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !preview.leftOut.isEmpty {
                Text(L("Left out")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(preview.leftOut, id: \.self) { Text("• " + $0) }
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(L("Back")) { model.editImport() }
                Spacer()
                Button(L("Cancel")) { model.cancelImport() }.keyboardShortcut(.cancelAction)
                Button(L("Import")) { model.applyImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview.isEmpty)
            }
            .padding(.top, 4)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText, .text, .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        model.readImport(data)
    }
}
