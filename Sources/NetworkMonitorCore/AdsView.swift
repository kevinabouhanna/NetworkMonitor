import Charts
import UniformTypeIdentifiers
import FirewallPolicy
import SwiftUI

/// The Ads and Trackers window's content (#251): what the lists blocked in
/// the period, over time, by site and by app, and pausing. The period is in
/// the window's toolbar, as in Connections.
struct AdsView: View {
    @ObservedObject var model: AdsViewModel
    /// Not `@State`; see `SettingsPaneState`.
    @StateObject private var info = RowInfoState()

    var body: some View {
        VStack(spacing: 0) {
            if model.tab == .log {
                AdsLogView(model: model)
            } else if model.tab == .rules {
                AdsRulesView(model: model)
            } else if !model.isOn {
                off
            } else {
                header
                Divider()
                if model.report.total == 0 {
                    empty
                } else {
                    chart
                        .frame(height: AdsMetrics.chartHeight)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                    Divider()
                    HStack(alignment: .top, spacing: 0) {
                        AdsList(title: "Sites", items: model.report.sites, total: model.report.total, model: model) {
                            item in
                            Button("Never Block \(item.id)") { model.setSite(.neverBlock, site: item.id, app: nil) }
                        }
                        Divider()
                        AdsList(title: "Apps", items: model.report.apps, total: model.report.total, model: model) {
                            item in
                            Button("Don't Filter Ads in \(item.title)") {
                                model.dontFilter(.init(key: item.id, name: item.title))
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: AdsMetrics.minWidth, minHeight: AdsMetrics.minHeight)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("\(model.report.total.formatted()) blocked")
                        .font(.system(size: 22, weight: .semibold))
                        .monospacedDigit()
                    RowInfoButton(help: Self.explanation, state: info) { Text(Self.explanation) }
                }
                Text(model.title).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onHover { info.isHovering = $0 }
            HStack(spacing: 14) {
                ForEach(model.report.lists, id: \.list) { entry in
                    HStack(spacing: 6) {
                        if let topic = BlocklistTopic(rawValue: entry.list) { ListTag(topic: topic) }
                        Text(AdsReport.title(ofList: entry.list)).foregroundStyle(.secondary)
                        Text(entry.count.formatted()).monospacedDigit()
                    }
                    .font(.system(size: 12))
                }
            }
            Spacer(minLength: 12)
            pause
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder private var pause: some View {
        if let until = model.pausedUntil {
            HStack(spacing: 8) {
                Text("Paused until \(until.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                Button("Resume") { model.resume() }
            }
        } else {
            Menu("Pause") {
                Button("For 1 Hour") { model.pause(for: 3600) }
                Button("Until Tomorrow") { model.pauseUntilTomorrow() }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Let ads through for a while, in every app")
        }
    }

    static let explanation = "Connections to sites on the lists you chose in Settings › Connections, stopped "
        + "before they started, in every app. NetworkMonitor reads only each connection's site name, from the "
        + "app or from the opening of a secure connection, never what's sent. Ads served from a site's own "
        + "servers, like YouTube's, can't be told apart from the site by name."

    // MARK: Chart

    private var chart: some View {
        let top = max(model.bins.map(\.count).max() ?? 0, 1)
        return Chart(model.bins) { bin in
            BarMark(x: .value("Time", bin.interval.start, unit: model.scale.binComponent),
                    y: .value("Blocked", bin.count))
                .foregroundStyle(Color.red.opacity(0.75))
                .cornerRadius(2)
        }
        .chartXScale(domain: model.period.start...model.period.end)
        .chartYScale(domain: 0...Double(top))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.18))
                AxisValueLabel {
                    if let count = value.as(Double.self) {
                        Text(Int64(count).formatted()).font(.system(size: 10)).monospacedDigit()
                    }
                }
            }
        }
    }

    // MARK: Empty and off

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "shield.lefthalf.filled").font(.system(size: 28)).foregroundStyle(.secondary)
            Text("Nothing blocked \(model.period.contains(Date()) ? "yet" : "in this period")")
                .font(.system(size: 14, weight: .medium))
            Text("Ads and trackers your apps try to reach show here as they're stopped.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var off: some View {
        VStack(spacing: 8) {
            Image(systemName: "shield.slash").font(.system(size: 28)).foregroundStyle(.secondary)
            Text("Ad blocking is off").font(.system(size: 14, weight: .medium))
            Text("Turn it on to stop ads, trackers and malware sites in every app.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Button("Turn On") { model.turnOn() }.padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Sites or apps, most blocked first, each with a bar for its share.
private struct AdsList<Menu: View>: View {
    let title: String
    let items: [AdsItem]
    let total: Int64
    let model: AdsViewModel
    @ViewBuilder let menu: (AdsItem) -> Menu

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        AdsRow(item: item, icon: model.icon(for: item),
                               fraction: Double(item.count) / Double(max(items.first?.count ?? 1, 1)))
                            .contextMenu { menu(item) }
                    }
                }
                .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct AdsRow: View {
    let item: AdsItem
    let icon: NSImage?
    let fraction: Double

    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).lineLimit(1).truncationMode(.middle)
                    ForEach(item.lists, id: \.self) { list in
                        if let topic = BlocklistTopic(rawValue: list) { ListTag(topic: topic) }
                    }
                }
                if let detail = item.detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            GeometryReader { geometry in
                Capsule().fill(Color.red.opacity(0.6))
                    .frame(width: max(2, geometry.size.width * fraction), height: 4)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: AdsMetrics.rowBarWidth, height: 20)
            Text(item.count.formatted())
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 48, alignment: .trailing)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 20)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .help(item.detail.map { "\(item.title): \($0)" } ?? item.title)
    }
}

enum AdsMetrics {
    static let minWidth: CGFloat = 760
    static let minHeight: CGFloat = 480
    static let chartHeight: CGFloat = 120
    static let rowBarWidth: CGFloat = 90
    static let logTime: CGFloat = 76
    static let logApp: CGFloat = 170
    static let logDecision: CGFloat = 76
    static let logWhy: CGFloat = 210
}

// MARK: - Log (#252)

/// Every connection the filter decided, newest first, with what decided it,
/// and a rule from any row.
struct AdsLogView: View {
    @ObservedObject var model: AdsViewModel

    var body: some View {
        let entries = model.logEntries
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Show", selection: $model.logShow) {
                    ForEach(AdsLog.Show.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                TextField("Search apps, sites and addresses", text: $model.logSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer(minLength: 8)
                Button(model.logIsPaused ? "Resume" : "Pause") { model.toggleLogPause() }
                    .help(model.logIsPaused ? "Show new connections again" : "Stop the list moving while you read it")
                Button("Clear") { model.clearLog() }
                Button("Export…") { export() }
                    .help("Save what's shown as a text file")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            AdsLogHeader()
            Divider()
            if entries.isEmpty {
                VStack(spacing: 6) {
                    Text(model.logIsPaused ? "Paused" : "Nothing yet")
                        .font(.system(size: 14, weight: .medium))
                    Text("Each connection your apps open shows here as it's decided, while NetworkMonitor runs.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            AdsLogRow(entry: entry, reason: model.reason(for: entry),
                                      icon: model.icon(forBundle: entry.bundlePath))
                                .contextMenu { menu(for: entry) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func menu(for entry: AdsLogEntry) -> some View {
        let app = entry.appKey.map { AdsViewModel.RuleApp(key: $0, name: entry.appName) }
        if let name = entry.name {
            ForEach(FirewallRules.siteScopes(for: name), id: \.self) { site in
                Section(site == name ? site : "\(site) and every name under it") {
                    Button("Never Block \(site)") { model.setSite(.neverBlock, site: site, app: nil) }
                    Button("Always Block \(site)") { model.setSite(.alwaysBlock, site: site, app: nil) }
                    if let app {
                        Button("Never Block \(site) in \(app.name)") { model.setSite(.neverBlock, site: site, app: app) }
                        Button("Always Block \(site) in \(app.name)") {
                            model.setSite(.alwaysBlock, site: site, app: app)
                        }
                    }
                }
            }
        }
        if let app {
            Divider()
            Button("Don't Filter Ads in \(app.name)") { model.dontFilter(app) }
        }
        let adRules = model.adRules(for: entry)
        let firewallRules = (entry.name.map(FirewallRules.siteScopes(for:)) ?? []).flatMap { domain in
            [nil, entry.appKey].compactMap { model.rule(forDomain: domain, appKey: $0) }
        }
        if !adRules.isEmpty || !firewallRules.isEmpty {
            Divider()
            ForEach(adRules) { rule in
                Button("Remove Your Rule: \(rule.summary)") { model.remove(rule) }
            }
            ForEach(firewallRules) { rule in
                Button("Remove Your Rule: \(rule.action == .allow ? "Allow" : "Block") \(rule.title)"
                       + (rule.appTitle.map { " in \($0)" } ?? "")) { model.remove(rule) }
            }
        }
        Divider()
        if let name = entry.name { Button("Copy Name") { copy(name) } }
        Button("Copy Address") { copy(entry.address) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "NetworkMonitor log.txt"
        panel.allowedContentTypes = [.plainText]
        let text = model.logText()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(text.utf8).write(to: url, options: .atomic)
    }
}

private struct AdsLogHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("Time").frame(width: AdsMetrics.logTime, alignment: .leading)
            Text("App").frame(width: AdsMetrics.logApp, alignment: .leading)
            Text("Site").frame(maxWidth: .infinity, alignment: .leading)
            Text("Decision").frame(width: AdsMetrics.logDecision, alignment: .leading)
            Text("Why").frame(width: AdsMetrics.logWhy, alignment: .leading)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }
}

private struct AdsLogRow: View {
    let entry: AdsLogEntry
    let reason: String
    let icon: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Text(entry.time.formatted(date: .omitted, time: .standard))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: AdsMetrics.logTime, alignment: .leading)
            HStack(spacing: 6) {
                if let icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                Text(entry.appName).lineLimit(1).truncationMode(.tail)
            }
            .frame(width: AdsMetrics.logApp, alignment: .leading)
            HStack(spacing: 6) {
                if let name = entry.name {
                    Text(name).lineLimit(1).truncationMode(.middle)
                } else {
                    Text(entry.address).lineLimit(1).foregroundStyle(.secondary)
                    Text("NO NAME")
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.18), in: Capsule())
                        .foregroundStyle(.secondary)
                        .help("Its site couldn't be read, so no list can match it. The app connected by address, "
                              + "and the start of the connection didn't name the site, or named only the "
                              + "service in front of it.")
                }
                ForEach(entry.lists, id: \.self) { list in
                    if let topic = BlocklistTopic(rawValue: list) { ListTag(topic: topic) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.isBlocked ? "Blocked" : "Let through")
                .foregroundStyle(entry.isBlocked ? Color.red : Color.secondary)
                .frame(width: AdsMetrics.logDecision, alignment: .leading)
            Text(reason).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
                .frame(width: AdsMetrics.logWhy, alignment: .leading)
                .help(reason)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help(entry.name.map { "\($0) · \(entry.address):\(entry.port)" } ?? "\(entry.address):\(entry.port)")
    }
}

// MARK: - Rules (#253)

/// Your own say over ad blocking: sites never blocked, sites always blocked,
/// and apps the lists leave alone.
struct AdsRulesView: View {
    @ObservedObject var model: AdsViewModel
    /// Not `@State`; see `SettingsPaneState`.
    @StateObject private var info = RowInfoState()

    var body: some View {
        VStack(spacing: 0) {
            form
            Divider()
            if model.adRules.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "list.bullet.rectangle").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("No rules yet").font(.system(size: 14, weight: .medium))
                    Text("Add a site above, or right-click one in the Overview or the Log.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        section("Never blocked", rules: model.neverBlocked,
                                note: "Let through even when a list has them.")
                        section("Always blocked", rules: model.alwaysBlocked,
                                note: "Blocked even when no list has them.")
                        section("Apps not filtered", rules: model.unfilteredApps,
                                note: "The lists leave these apps' connections alone.")
                    }
                    .padding(20)
                }
            }
            Divider()
            HStack(spacing: 12) {
                Button("Don't Filter an App…") { chooseApp() }
                    .help("Choose an app whose connections the lists should leave alone, such as a bank's app that breaks")
                Spacer()
                Button("Import…") { model.beginImport() }
                    .help("Bring rules over from uBlock Origin, AdGuard, or a list of rules")
                Button("Export…") { export() }
                    .disabled(model.adRules.isEmpty)
                    .help("Save your rules in the format uBlock Origin and AdGuard read")
                if !model.isOn {
                    Text("Rules apply while ad blocking is on.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                TextField("A site, like example.com", text: $model.newSite)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 220)
                    .onSubmit { model.addSite(.neverBlock) }
                Menu(model.newSiteApp.map { "In \($0.name)" } ?? "In Every App") {
                    Button("Every App") { model.newSiteApp = nil }
                    let apps = model.knownApps
                    if !apps.isEmpty { Divider() }
                    ForEach(apps) { app in Button(app.name) { model.newSiteApp = app } }
                    Divider()
                    Button("Choose an App…") {
                        if let app = Self.pickApp() { model.newSiteApp = app }
                    }
                }
                .fixedSize()
                Button("Never Block") { model.addSite(.neverBlock) }
                Button("Always Block") { model.addSite(.alwaysBlock) }
                RowInfoButton(help: Self.explanation, state: info) { Text(Self.explanation) }
                Spacer(minLength: 0)
            }
            if let error = model.ruleError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onHover { info.isHovering = $0 }
        .onChange(of: model.newSite) { _ in model.clearRuleError() }
        .sheet(isPresented: $model.isImporting) { AdsImportSheet(model: model) }
    }

    static let explanation = "A rule covers the site and every name under it: example.com covers ads.example.com. "
        + "Rules change only what the ad and tracker lists do. Never block lets a listed site through, and "
        + "always block stops one no list has. A rule for one app wins over one for every app. Your firewall "
        + "rules in Connections still come first."

    @ViewBuilder private func section(_ title: String, rules: [AdRule], note: String) -> some View {
        if !rules.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Text(note).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .padding(.bottom, 2)
                ForEach(rules) { rule in row(rule) }
            }
        }
    }

    private func row(_ rule: AdRule) -> some View {
        HStack(spacing: 10) {
            if let icon = model.icon(forBundle: rule.appKey) {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            } else {
                Image(systemName: rule.kind == .neverBlock ? "checkmark.shield" : "xmark.shield")
                    .foregroundStyle(rule.kind == .neverBlock ? Color.green : Color.red)
                    .frame(width: 18, height: 18)
            }
            Text(rule.site ?? rule.appTitle ?? rule.appKey ?? "")
                .lineLimit(1).truncationMode(.middle)
            if rule.site != nil {
                Text(rule.appTitle.map { "in \($0)" } ?? "in every app")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                model.remove(rule)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this rule")
        }
        .font(.system(size: 13))
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Remove") { model.remove(rule) }
            if let site = rule.site {
                Button(rule.kind == .neverBlock ? "Always Block Instead" : "Never Block Instead") {
                    model.setSite(rule.kind == .neverBlock ? .alwaysBlock : .neverBlock, site: site,
                                  app: rule.appKey.map { .init(key: $0, name: rule.appTitle ?? $0) })
                }
            }
        }
    }

    private func chooseApp() {
        if let app = Self.pickApp() { model.dontFilter(app) }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "NetworkMonitor ad rules.txt"
        panel.allowedContentTypes = [.plainText]
        let text = model.exportText()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    static func pickApp() -> AdsViewModel.RuleApp? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return AdsViewModel.ruleApp(at: url)
    }
}

/// Bringing rules over (#253): paste or choose a file, then see what it
/// brings before anything changes.
private struct AdsImportSheet: View {
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
            Text("Bring Rules Over").font(.system(size: 15, weight: .semibold))
            Text("Choose uBlock Origin's backup (its Settings › Back up to file), AdGuard's exported settings, "
                 + "or a file of rules. Or paste rules below, one a line.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $model.importText)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 160)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            if let error = model.importError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
            HStack {
                Button("Choose File…") { chooseFile() }
                Spacer()
                Button("Cancel") { model.cancelImport() }.keyboardShortcut(.cancelAction)
                Button("Continue") { model.readImportText() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func summary(_ preview: AdImport) -> some View {
        Group {
            Text("From \(preview.source)").font(.system(size: 15, weight: .semibold))
            if preview.summary.isEmpty {
                Text("Nothing new to bring over.").font(.system(size: 13))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(preview.summary, id: \.self) { Text("• " + $0) }
                }
                .font(.system(size: 13))
            }
            if preview.hasTrustedSites {
                Text("Trusted sites become never blocked: connections to the site itself go through. Ads its pages "
                     + "load from other sites are still blocked, since the filter can't tell which page asked.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !preview.leftOut.isEmpty {
                Text("Left out").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(preview.leftOut, id: \.self) { Text("• " + $0) }
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Back") { model.editImport() }
                Spacer()
                Button("Cancel") { model.cancelImport() }.keyboardShortcut(.cancelAction)
                Button("Import") { model.applyImport() }
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
