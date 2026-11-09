import Charts
import UniformTypeIdentifiers
import FirewallPolicy
import SwiftUI

/// The Ads and Trackers window's content (#251): what the lists blocked in
/// the period, over time, by site and by app, and pausing. The period is in
/// the window's toolbar, as in Connections; the tabs head the content (#358),
/// so the toolbar fits a narrower window.
struct AdsView: View {
    @ObservedObject var model: AdsViewModel
    /// Not `@State`; see `SettingsPaneState`.
    @StateObject private var info = RowInfoState()

    var body: some View {
        VStack(spacing: 0) {
            scopeBar
                .padding(.horizontal, ScopeMetrics.inset)
                .padding(.top, ScopeMetrics.top)
            if model.tab == .log { Spacer().frame(height: ScopeMetrics.below) }
            page
        }
        .frame(minWidth: AdsMetrics.minWidth, minHeight: AdsMetrics.minHeight)
    }

    /// Overview or the log, in the row every section has under its toolbar,
    /// at the same place (#436); on Log, which decisions and its buttons too.
    private var scopeBar: some View {
        HStack(spacing: 10) {
            LabelledControl(L("Show")) {
                GlassSegmented(name: L("Show"), options: AdsViewModel.Tab.allCases, selection: $model.tab,
                               label: { $0.label }, size: .small)
                    .help(L("What was blocked, and every connection as it's decided"))
            }
            // The toolbar's search, as a filter like the others (#436).
            let query = model.logSearch.trimmingCharacters(in: .whitespaces)
            if !query.isEmpty {
                FilterChip(label: L("“%@”", query), onClear: { model.logSearch = "" })
            }
            if model.tab == .log {
                Divider().frame(height: 16)
                AdsLogControls(model: model)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(height: ScopeMetrics.height)
    }

    @ViewBuilder private var page: some View {
        VStack(spacing: 0) {
            if model.tab == .log {
                AdsLogView(model: model)
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
                        AdsList(title: L("Sites"), items: searched(model.report.sites), total: model.report.total,
                                model: model) {
                            item in
                            if !item.onlyThreats {
                                Button(L("Never Block %@", item.id)) { model.setSite(.neverBlock, site: item.id, app: nil) }
                            }
                        }
                        Divider()
                        AdsList(title: L("Apps"), items: searched(model.report.apps), total: model.report.total,
                                model: model) {
                            item in
                            Button(L("Don't Filter Ads in %@", item.title)) {
                                model.dontFilter(.init(key: item.id, name: item.title))
                            }
                        }
                    }
                }
            }
        }
    }

    /// The toolbar's search, on Overview: a site, a name under it, or an app.
    private func searched(_ items: [AdsItem]) -> [AdsItem] {
        let query = model.logSearch.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
                || ($0.detail?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    // MARK: Header

    /// The total, what each list blocked, and Pause: on one line when there's
    /// room, else the lists' counts flow under the total, each kept whole
    /// (#358), so a narrow window never breaks a name mid-word.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                total
                HStack(spacing: 14) { listCounts }.fixedSize()
                Spacer(minLength: 12)
                pause
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    total
                    FlowLayout(spacing: 14, lineSpacing: 6) { listCounts }
                }
                Spacer(minLength: 12)
                pause
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var total: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(L("%@ blocked", model.report.total.formatted()))
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                RowInfoButton(help: Self.explanation, state: info) { Text(Self.explanation) }
            }
            Text(model.title).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .fixedSize()
        .contentShape(Rectangle())
        .onHover { info.isHovering = $0 }
    }

    private var listCounts: some View {
        ForEach(model.report.lists, id: \.list) { entry in
            HStack(spacing: 6) {
                if let topic = BlocklistTopic(rawValue: entry.list) { ListTag(topic: topic) }
                Text(AdsReport.title(ofList: entry.list)).foregroundStyle(.secondary)
                Text(entry.count.formatted()).monospacedDigit()
            }
            .font(.system(size: 12))
            .fixedSize()
        }
    }

    @ViewBuilder private var pause: some View {
        if let until = model.pausedUntil {
            HStack(spacing: 8) {
                Text(L("Paused until %@", until.formatted(date: .omitted, time: .shortened)))
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                Button(L("Resume")) { model.resume() }
            }
        } else if let network = model.pausedHere, let id = model.currentNetwork?.id {
            HStack(spacing: 8) {
                Text(L("Off on %@", network))
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                Button(L("Turn On Here")) { model.resumeOnNetwork(id) }
            }
        } else {
            Menu(L("Pause")) {
                Button(L("For 1 Hour")) { model.pause(for: 3600) }
                Button(L("Until Tomorrow")) { model.pauseUntilTomorrow() }
                if let network = model.currentNetwork {
                    Divider()
                    Button(L("Whenever on %@", network.name)) { model.pauseOnThisNetwork() }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L("Let ads through for a while, in every app"))
        }
    }

    /// Every refused try is counted, as Little Snitch, Pi-hole and AdGuard
    /// Home count theirs; the ⓘ says so, since a retrying app's total reads
    /// as far more tracking than it is (#348, #388).
    static var explanation: String { L("Connections to sites on the lists you chose in the Lists tab, stopped before they started, in every app. Each try counts: an app that keeps trying a blocked site, as many do to send their usage reports, counts every time, so one app can reach thousands a day. NetworkMonitor reads only each connection's site name, from the app or from the opening of a secure connection, never what's sent. Ads served from a site's own servers, like YouTube's, can't be told apart from the site by name.") }

    // MARK: Chart

    private var chart: some View {
        let top = max(model.bins.map(\.count).max() ?? 0, 1)
        return Chart(model.bins) { bin in
            BarMark(x: .value(L("Time"), bin.interval.start, unit: model.scale.binComponent),
                    y: .value(L("Blocked"), bin.count))
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
            Text(model.period.contains(Date()) ? L("Nothing blocked yet") : L("Nothing blocked in this period"))
                .font(.system(size: 14, weight: .medium))
            Text(L("Ads and trackers your apps try to reach show here as they're stopped."))
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var off: some View {
        VStack(spacing: 8) {
            Image(systemName: "shield.slash").font(.system(size: 28)).foregroundStyle(.secondary)
            Text(L("Ad blocking is off")).font(.system(size: 14, weight: .medium))
            Text(L("Turn it on to stop ads, trackers and malware sites in every app."))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Button(L("Turn On")) { model.turnOn() }.padding(.top, 4)
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
                Image(nsImage: icon).resizable().frame(width: 20, height: 20).accessibilityHidden(true)
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
        .help(item.detail.map { L("%@: %@", item.title, $0) } ?? item.title)
    }
}

/// Its subviews left to right, onto a new line when the next doesn't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

enum AdsMetrics {
    /// With the tabs in the window (#358), the toolbar (title, period and
    /// ‹ Today ›) fits down to 620, and Overview's list counts wrap under the
    /// total; at 700 the Sites and Apps names still read. Measured on the
    /// real app, so no control is ever hidden in the toolbar's » menu (#315).
    static let minWidth: CGFloat = 700
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
            // Which decisions, and the buttons, are in the scope row above;
            // search is in the toolbar, as in every section (#436).
            Divider()
            AdsLogHeader()
            Divider()
            if entries.isEmpty {
                VStack(spacing: 6) {
                    Text(emptyTitle)
                        .font(.system(size: 14, weight: .medium))
                    Text(emptyDetail)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 40)
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

    /// Why the log is empty: it's live, so it fills only while the filter
    /// decides connections, from the moment NetworkMonitor starts (#436).
    private var emptyTitle: String {
        let query = model.logSearch.trimmingCharacters(in: .whitespaces)
        if model.logIsPaused { return L("Paused") }
        if !query.isEmpty { return L("Nothing matches “%@”", query) }
        if model.monitor.filter.state != .on { return L("Not filtering connections") }
        return L("Nothing yet")
    }

    private var emptyDetail: String {
        if model.monitor.filter.state != .on && !model.logIsPaused {
            return L("The log shows each connection as the filter decides it. It fills once ad blocking or a rule is on, and starts afresh each time NetworkMonitor opens.")
        }
        return L("Each connection your apps open shows here as it's decided, while NetworkMonitor runs.")
    }

    @ViewBuilder private func menu(for entry: AdsLogEntry) -> some View {
        let app = entry.appKey.map { AdsViewModel.RuleApp(key: $0, name: entry.appName) }
        // Never block wouldn't let it through past a malware list (#317).
        let neverBlocks = entry.lists.isEmpty || !entry.lists.allSatisfy(ListCatalogue.isThreat)
        if let name = entry.name {
            ForEach(FirewallRules.siteScopes(for: name), id: \.self) { site in
                Section(site == name ? site : L("%@ and every name under it", site)) {
                    if neverBlocks {
                        Button(L("Never Block %@", site)) { model.setSite(.neverBlock, site: site, app: nil) }
                    }
                    Button(L("Always Block %@", site)) { model.setSite(.alwaysBlock, site: site, app: nil) }
                    if let app {
                        if neverBlocks {
                            Button(L("Never Block %@ in %@", site, app.name)) {
                                model.setSite(.neverBlock, site: site, app: app)
                            }
                        }
                        Button(L("Always Block %@ in %@", site, app.name)) {
                            model.setSite(.alwaysBlock, site: site, app: app)
                        }
                    }
                }
            }
        }
        if let app {
            Divider()
            Button(L("Don't Filter Ads in %@", app.name)) { model.dontFilter(app) }
        }
        let adRules = model.adRules(for: entry)
        let firewallRules = (entry.name.map(FirewallRules.siteScopes(for:)) ?? []).flatMap { domain in
            [nil, entry.appKey].compactMap { model.rule(forDomain: domain, appKey: $0) }
        }
        if !adRules.isEmpty || !firewallRules.isEmpty {
            Divider()
            ForEach(adRules) { rule in
                Button(L("Remove Your Rule: %@", rule.shownSummary)) { model.remove(rule) }
            }
            ForEach(firewallRules) { rule in
                Button(Self.removeTitle(rule)) { model.remove(rule) }
            }
        }
        Divider()
        if let name = entry.name { Button(L("Copy Name")) { copy(name) } }
        Button(L("Copy Address")) { copy(entry.address) }
    }

    /// "Remove Your Rule: Block example.com in Safari", for a firewall rule.
    private static func removeTitle(_ rule: FirewallRule) -> String {
        let allow = rule.action == .allow
        if let app = rule.appTitle {
            return allow ? L("Remove Your Rule: Allow %@ in %@", rule.title, app)
                : L("Remove Your Rule: Block %@ in %@", rule.title, app)
        }
        return allow ? L("Remove Your Rule: Allow %@", rule.title) : L("Remove Your Rule: Block %@", rule.title)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

}

/// The log's own controls, in the scope row: which decisions, then Pause,
/// Clear and Export.
struct AdsLogControls: View {
    @ObservedObject var model: AdsViewModel

    var body: some View {
        HStack(spacing: 8) {
            GlassSegmented(name: L("Decisions"), options: AdsLog.Show.allCases, selection: $model.logShow,
                           label: { $0.label }, size: .small)
                .help(L("Every decision, or only some"))
            Spacer(minLength: 8)
            Button(model.logIsPaused ? L("Resume") : L("Pause")) { model.toggleLogPause() }
                .help(model.logIsPaused ? L("Show new connections again") : L("Stop the list moving while you read it"))
                .fixedSize()
            Button(L("Clear")) { model.clearLog() }
                .fixedSize()
            Button(L("Export…")) { export() }
                .help(L("Save what's shown as a text file"))
                .fixedSize()
        }
        .controlSize(.small)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = L("NetworkMonitor log.txt")
        panel.allowedContentTypes = [.plainText]
        let text = model.logText()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(text.utf8).write(to: url, options: .atomic)
    }
}

private struct AdsLogHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Text(L("Time")).frame(width: AdsMetrics.logTime, alignment: .leading)
            Text(L("App")).frame(width: AdsMetrics.logApp, alignment: .leading)
            Text(L("Site")).frame(maxWidth: .infinity, alignment: .leading)
            Text(L("Decision")).frame(width: AdsMetrics.logDecision, alignment: .leading)
            Text(L("Why")).frame(width: AdsMetrics.logWhy, alignment: .leading)
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
                if let icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16).accessibilityHidden(true) }
                Text(entry.appName).lineLimit(1).truncationMode(.tail)
            }
            .frame(width: AdsMetrics.logApp, alignment: .leading)
            HStack(spacing: 6) {
                if let name = entry.name {
                    Text(name).lineLimit(1).truncationMode(.middle)
                } else {
                    Text(entry.address).lineLimit(1).foregroundStyle(.secondary)
                    Text(L("NO NAME"))
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.18), in: Capsule())
                        .foregroundStyle(.secondary)
                        .help(L("Its site couldn't be read, so no list can match it. The app connected by address, and the start of the connection didn't name the site, or named only the service in front of it."))
                }
                ForEach(entry.lists, id: \.self) { list in
                    if let topic = BlocklistTopic(rawValue: list) { ListTag(topic: topic) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.isBlocked ? L("Blocked") : L("Let through"))
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

// MARK: - Lists (#254)

/// Which lists block: the two that ship with the app, the catalogue's, and
/// any added by address, each with what it blocked today (#311).
struct AdsListsView: View {
    @ObservedObject var model: AdsViewModel
    /// Not `@State`; see `SettingsPaneState`.
    @StateObject private var info = RowInfoState()
    @StateObject private var recommendedInfo = RowInfoState()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    group(L("Built in"), note: L("Updated weekly by NetworkMonitor, and signed.")) {
                        ForEach(BlocklistTopic.allCases.sorted { $0.rawValue < $1.rawValue }, id: \.self) { topic in
                            shippedRow(topic)
                        }
                    }
                    recommended
                    advanced
                }
                .padding(20)
            }
            if !model.isOn {
                Divider()
                Text(L("Lists block only while ad blocking is on: switch on a built-in list."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
        }
    }

    /// The lists the app picks (#314), used unless you choose your own.
    private var recommended: some View {
        let on = model.library.usesRecommended
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                // One switch for the pair, where each list's own would be.
                Toggle(L("Use the recommended lists"), isOn: Binding(get: { on }, set: { model.setUsesRecommended($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help(on ? L("Choose your own lists under Advanced instead") : L("Use the recommended lists again"))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L("Recommended")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Text(on ? L("Block most ads, and rarely break a site.")
                            : L("Off: the lists you choose under Advanced are used instead."))
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                    RowInfoButton(help: Self.recommendedExplanation, state: recommendedInfo) {
                        Text(Self.recommendedExplanation)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 2)
            .contentShape(Rectangle())
            .onHover { recommendedInfo.isHovering = $0 }
            ForEach(model.recommendedLists) { list in
                listRow(list, showsSwitch: false)
                    .opacity(on ? 1 : 0.5)
            }
        }
    }

    /// Every list, to choose your own, and any list by its address: more
    /// blocking, and the risk of broken sites that comes with it (#314).
    private var advanced: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                model.advancedListsShown = !model.showsAdvancedLists
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(model.showsAdvancedLists ? 90 : 0))
                        .frame(width: 10)
                    Text(L("Advanced")).font(.system(size: 12, weight: .semibold))
                    Text(L("Choose your own lists, or add one by its address."))
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if model.showsAdvancedLists {
                form
                ForEach(model.listGroups, id: \.topic) { group in
                    self.group(group.topic.title, note: note(for: group.topic)) {
                        ForEach(group.lists) { list in row(list) }
                    }
                }
            }
        }
    }

    static var recommendedExplanation: String { L("HaGeZi Normal and OISD Big, on top of the built-in lists. Between them they block most ads and trackers, and both are made to keep mistakes rare: OISD's aim is to block ads without breaking sites, and HaGeZi Normal is HaGeZi's all-round list, a step below its stricter Pro. They overlap rather than conflict. NetworkMonitor downloads them from their makers weekly, and a later version may change the pair.") }

    private var form: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                // Verbatim: a key would show the address as a link.
                TextField(text: $model.newListURL) { Text(verbatim: L("A list's address, like https://example.com/hosts.txt")) }
                    .accessibilityLabel(L("A list's address"))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 300)
                    .onSubmit { model.addList() }
                Button(L("Add List")) { model.addList() }
                RowInfoButton(help: Self.explanation, state: info) { Text(Self.explanation) }
                Spacer(minLength: 0)
            }
            if let error = model.listError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .contentShape(Rectangle())
        .onHover { info.isHovering = $0 }
        .onChange(of: model.newListURL) { _ in model.clearListError() }
    }

    static var explanation: String { L("A list names sites to block, and covers every name under each: listing example.com blocks ads.example.com. NetworkMonitor downloads each list you switch on from its makers, weekly, never on a hotspot or a metered connection, and keeps the last good copy. It reads hosts files, plain lists of names, and Adblock rules about whole sites (||example.com^, with @@ exceptions). Rules about parts of pages are for the Chrome extension. Each list you add blocks more, and makes it likelier that one blocks something a site needs to work. If a site stops working, today's counts show which list blocked what.") }

    private func note(for topic: ListTopic) -> String {
        switch topic {
        case .ads:          return L("Each one you add blocks more, but makes it likelier a site stops working.")
        case .trackers:     return L("Sites that follow you from page to page.")
        case .annoyances:   return L("Cookie notices and other parts of pages are for the Chrome extension.")
        case .malware:      return L("On top of the built-in malware list.")
        case .added:        return L("Downloaded from the address you gave.")
        }
    }

    @ViewBuilder private func group<Content: View>(_ title: String, note: String,
                                                   @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Text(note).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.bottom, 2)
            content()
        }
    }

    private func shippedRow(_ topic: BlocklistTopic) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { model.isShippedOn(topic) }, set: { model.setShipped(topic, $0) }))
                .labelsHidden()
                .accessibilityLabel(topic.shownTitle)
                .toggleStyle(.switch)
                .controlSize(.mini)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(topic.shownTitle)
                    ListTag(topic: topic)
                }
                Text(L("%@, %@", topic.source, model.shippedDetail(topic)))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            blocked(model.blockedToday(byList: topic.rawValue))
        }
        .font(.system(size: 13))
        .padding(.vertical, 3)
        .help(L("%@, %@ licence", topic.source, topic.licence))
    }

    private func row(_ list: ListSource) -> some View { listRow(list, showsSwitch: true) }

    /// A list, with its switch, or without one among the recommended, which
    /// come and go together.
    private func listRow(_ list: ListSource, showsSwitch: Bool) -> some View {
        let detail = model.listDetail(list.id)
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { model.library.isEnabled(list.id) }, set: { model.setList(list.id, $0) }))
                .labelsHidden()
                .accessibilityLabel(list.title)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .opacity(showsSwitch ? 1 : 0)
                .disabled(!showsSwitch)
                .accessibilityHidden(!showsSwitch)
            VStack(alignment: .leading, spacing: 1) {
                Text(list.title).lineLimit(1).truncationMode(.middle)
                Text(list.isAdded ? list.url.absoluteString : list.about)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                if !detail.text.isEmpty {
                    Text(detail.text)
                        .font(.system(size: 11))
                        .foregroundStyle(detail.isProblem ? Color.orange : Color.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if model.library.isEnabled(list.id) { blocked(model.blockedToday(byList: list.id)) }
            if list.isAdded {
                Button {
                    model.library.remove(list.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help(L("Remove this list"))
            }
        }
        .font(.system(size: 13))
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help(list.licence == "Its own terms" ? L("%@, on its own terms", list.source) // untranslated: the saved licence it matches
              : L("%@, %@ licence", list.source, list.licence))
        .contextMenu {
            if model.library.isEnabled(list.id) {
                Button(L("Update Now")) { model.library.download(list.id) }
            }
            Button(L("Copy Address")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(list.url.absoluteString, forType: .string)
            }
            if list.isAdded {
                Divider()
                Button(L("Remove")) { model.library.remove(list.id) }
            }
        }
    }

    private func blocked(_ count: Int64) -> some View {
        Text(count > 0 ? L("%@ blocked today", count.formatted()) : "")
            .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
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
            if model.adRules.isEmpty && model.pausedNetworks.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "list.bullet.rectangle").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text(L("No rules yet")).font(.system(size: 14, weight: .medium))
                    Text(L("Add a site above, or right-click one in the Overview or the Log."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        section(L("Never blocked"), rules: model.neverBlocked,
                                note: L("Let through even when a list has them."))
                        section(L("Always blocked"), rules: model.alwaysBlocked,
                                note: L("Blocked even when no list has them."))
                        section(L("Apps not filtered"), rules: model.unfilteredApps,
                                note: L("The lists leave these apps' connections alone."))
                        networks
                    }
                    .padding(20)
                }
            }
            Divider()
            HStack(spacing: 12) {
                Button(L("Don't Filter an App…")) { chooseApp() }
                    .help(L("Choose an app whose connections the lists should leave alone, such as a bank's app that breaks"))
                Spacer()
                Button(L("Import…")) { model.beginImport() }
                    .help(L("Bring rules over from uBlock Origin, AdGuard, or a list of rules"))
                Button(L("Export…")) { export() }
                    .disabled(model.adRules.isEmpty)
                    .help(L("Save your rules in the format uBlock Origin and AdGuard read"))
                if !model.isOn {
                    Text(L("Rules apply while ad blocking is on.")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                TextField(L("A site, like example.com"), text: $model.newSite)
                    .accessibilityLabel(L("Site"))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 220)
                    .onSubmit { model.addSite(.neverBlock) }
                Menu(model.newSiteApp.map { L("In %@", $0.name) } ?? L("In Every App")) {
                    Button(L("Every App")) { model.newSiteApp = nil }
                    let apps = model.knownApps
                    if !apps.isEmpty { Divider() }
                    ForEach(apps) { app in Button(app.name) { model.newSiteApp = app } }
                    Divider()
                    Button(L("Choose an App…")) {
                        if let app = Self.pickApp() { model.newSiteApp = app }
                    }
                }
                .fixedSize()
                Button(L("Never Block")) { model.addSite(.neverBlock) }
                Button(L("Always Block")) { model.addSite(.alwaysBlock) }
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

    static var explanation: String { L("A rule covers the site and every name under it: example.com covers ads.example.com. Rules change only what the ad and tracker lists do. Never block lets a listed site through, and always block stops one no list has. Malware and phishing lists still block whatever these rules say. A rule for one app wins over one for every app. In Connections, a block still blocks and Always Allow on a site lets it through; allowing a whole app or company doesn't let its ads through.") }

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

    @ViewBuilder private var networks: some View {
        let networks = model.pausedNetworks
        if !networks.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L("Networks")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Text(L("Ad blocking is off whenever the Mac is on these."))
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .padding(.bottom, 2)
                ForEach(networks, id: \.id) { network in
                    HStack(spacing: 10) {
                        Image(systemName: "wifi").foregroundStyle(.secondary).frame(width: 18, height: 18)
                        Text(network.name).lineLimit(1)
                        if network.id == model.currentNetwork?.id {
                            Text(L("the network you're on")).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button {
                            model.resumeOnNetwork(network.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(L("Block ads on this network again"))
                    }
                    .font(.system(size: 13))
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private func row(_ rule: AdRule) -> some View {
        HStack(spacing: 10) {
            if let icon = model.icon(forBundle: rule.appKey) {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18).accessibilityHidden(true)
            } else {
                Image(systemName: rule.kind == .neverBlock ? "checkmark.shield" : "xmark.shield")
                    .foregroundStyle(rule.kind == .neverBlock ? Color.green : Color.red)
                    .frame(width: 18, height: 18)
            }
            Text(rule.site ?? rule.appTitle ?? rule.appKey ?? "")
                .lineLimit(1).truncationMode(.middle)
            if rule.site != nil {
                Text(rule.appTitle.map { L("in %@", $0) } ?? L("in every app"))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                model.remove(rule)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(L("Remove this rule"))
        }
        .font(.system(size: 13))
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .contextMenu {
            Button(L("Remove")) { model.remove(rule) }
            if let site = rule.site {
                Button(rule.kind == .neverBlock ? L("Always Block Instead") : L("Never Block Instead")) {
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
        panel.nameFieldStringValue = L("NetworkMonitor ad rules.txt")
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
        panel.prompt = L("Choose")
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
            Text(L("Bring Rules Over")).font(.system(size: 15, weight: .semibold))
            Text(L("Choose uBlock Origin's backup (its Settings › Back up to file), AdGuard's exported settings, or a file of rules. Or paste rules below, one a line."))
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
                Text(L("Trusted sites become never blocked: connections to the site itself go through. Ads its pages load from other sites are still blocked, since the filter can't tell which page asked."))
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
