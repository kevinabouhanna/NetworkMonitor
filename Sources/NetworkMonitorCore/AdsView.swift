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
        .background(escape)
    }

    /// Escape lets go of the bar picked, then of the row chosen (#536), as
    /// a click on either does. Only while there's one, so Escape still
    /// closes the search the rest of the time.
    @ViewBuilder private var escape: some View {
        if model.tab == .overview && model.canGoBack {
            Button(L("Show Everything Again")) { model.goBack() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    /// Overview or the log, in the row every section has under its toolbar,
    /// at the same place (#436); on Log, which decisions and its buttons too.
    private var scopeBar: some View {
        HStack(spacing: 10) {
            LabelledControl(L("Show")) {
                GlassSegmented(name: L("Show"), options: AdsViewModel.Tab.allCases, selection: $model.tab,
                               label: { $0.label }, size: .small,
                               help: L("What was blocked, and every connection as it's decided"))
            }
            // The toolbar's search, as a filter like the others (#436).
            let query = model.logSearch.trimmingCharacters(in: .whitespaces)
            if !query.isEmpty {
                FilterChip(label: L("“%@”", query), onClear: { model.logSearch = "" })
            }
            // The bar clicked and the row chosen (#536), as Connections and
            // Usage History show theirs.
            if model.tab == .overview {
                if let span = model.spanTitle {
                    FilterChip(label: span, onClear: model.clearSpan)
                }
                if let selection = model.selection {
                    FilterChip(label: selection.title, onClear: model.clearSelection)
                }
            }
            if model.tab == .log {
                Divider().frame(height: 16)
                AdsLogControls(model: model)
            } else {
                Spacer(minLength: 12)
                // Sites or Apps, where Connections and Usage History have All ·
                // Wi-Fi · Hotspot, while there's a list to show (#524).
                if model.layout.showsList {
                    GlassSegmented(name: L("Group by"), options: PopoverAdsGrouping.allCases,
                                   selection: $model.grouping, label: { $0.label }, size: .small,
                                   help: L("The sites blocked, or the apps that tried to reach them"))
                }
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
                if model.report.total == 0 && model.periodTotal == 0 {
                    empty
                } else {
                    // The toolbar's View (#524): the list on the left and the
                    // chart on the right, as Connections has its list and map
                    // (#534).
                    switch model.layout {
                    case .both:
                        SideBySide {
                            lists
                        } detail: {
                            chart
                                .padding(12)
                                .splitCard()
                                .padding(.top, 14)
                                .padding(.bottom, 20)
                        }
                        .padding(.trailing, 20)
                    case .list:
                        lists
                    case .chart:
                        chart
                            .frame(maxHeight: .infinity)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                    }
                }
            }
        }
    }

    /// Sites or Apps, as the switch at the top right says (#524): they were
    /// side by side, but one at a time each gets the window's width.
    private var lists: some View {
        ZStack(alignment: .top) {
            AdsList(model: model,
                    items: chosen(searched(model.grouping == .sites ? model.report.sites : model.report.apps)))
                // The other list fades in as the switch's pill slides, as Usage
                // History's lists do (#436).
                .id(model.grouping)
                .transition(Motion.swap)
        }
    }

    /// A row chosen (#593): the list keeps only it, and only the row chosen
    /// inside it, as Usage History and Connections keep theirs.
    private func chosen(_ items: [AdsItem]) -> [AdsItem] {
        guard let selection = model.selection, let parent = items.first(where: { $0.id == selection.parent }) else {
            return items
        }
        guard let child = selection.child else { return [parent] }
        return [parent.keeping(child)]
    }

    /// The toolbar's search, on Overview: a site, a name under it, or an app,
    /// or what's inside one, as Usage History finds an app by its parts.
    private func searched(_ items: [AdsItem]) -> [AdsItem] {
        let query = model.logSearch.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        func matches(_ item: AdsItem) -> Bool {
            item.title.localizedCaseInsensitiveContains(query) || item.id.localizedCaseInsensitiveContains(query)
                || (item.detail?.localizedCaseInsensitiveContains(query) ?? false)
        }
        return items.filter { matches($0) || $0.children.contains(where: matches) }
    }

    // MARK: Header

    /// The total and its period, and Pause. What each list blocked is behind
    /// the total's ⓘ (#402): a row of every list's count beside the total was
    /// noisy, and couldn't say that a list had been switched off since.
    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            total
            Spacer(minLength: 12)
            pause
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var total: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // The chosen row's, while there's one (#593), as Usage
                // History's and Connections' totals follow theirs.
                Text(L("%@ blocked", (model.chosenCount ?? model.report.total).formatted()))
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                RowInfoButton(help: breakdownHelp, state: info, accessibilityLabel: L("Blocked by each list")) {
                    breakdown
                }
                .accessibilityValue(breakdownLines.joined(separator: L(", ")))
                .accessibilityHint(Self.explanation)
            }
            Text(model.spanTitle.map { L("%@, %@", model.title, $0) } ?? model.title)
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .fixedSize()
        .contentShape(Rectangle())
        .onHover { info.isHovering = $0 }
    }

    /// The ⓘ's popover: how blocks are counted, then each list's share of the
    /// total, largest first. A list blocks only while it's on, so one switched
    /// off since keeps what it blocked before, marked off.
    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Self.explanation)
            if !model.report.lists.isEmpty {
                Divider()
                Text(L("Blocked by each list")).fontWeight(.semibold)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                    ForEach(model.report.lists, id: \.list) { entry in
                        GridRow {
                            HStack(spacing: 6) {
                                if let topic = BlocklistTopic(rawValue: entry.list) { ListTag(topic: topic) }
                                Text(AdsReport.title(ofList: entry.list))
                                if !model.isListOn(entry.list) {
                                    Text(L("off")).foregroundStyle(.secondary)
                                }
                            }
                            Text(entry.count.formatted())
                                .monospacedDigit()
                                .gridColumnAlignment(.trailing)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(line(entry))
                    }
                }
            }
        }
    }

    /// "Ads and trackers: 1,234", or "Peter Lowe's (off): 1".
    private func line(_ entry: (list: String, count: Int64)) -> String {
        let title = AdsReport.title(ofList: entry.list)
        let name = model.isListOn(entry.list) ? title : L("%@ (%@)", title, L("off"))
        return L("%@: %@", name, entry.count.formatted())
    }

    private var breakdownLines: [String] { model.report.lists.map(line) }

    /// The ⓘ's tooltip: the popover's words, as text.
    private var breakdownHelp: String {
        guard !breakdownLines.isEmpty else { return Self.explanation }
        return ([Self.explanation, "", L("Blocked by each list")] + breakdownLines).joined(separator: "\n")
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
        GeometryReader { geometry in
            AdsChart(model: model, height: geometry.size.height, width: geometry.size.width)
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

/// Sites or apps, most blocked first, made of Usage History's rows (#536):
/// a click on a row, or its chevron, opens what's inside it, the apps that
/// tried a site or the sites an app tried, each with when it was last
/// blocked; its Filter button keeps only it, and the chart and total show
/// its share (#593). ↑ and ↓ move through the rows, → and ← or Space open
/// and close one, Return filters to it.
private struct AdsList: View {
    @ObservedObject var model: AdsViewModel
    let items: [AdsItem]
    /// The row the keyboard is on (#546, #593). Not `@State`; see
    /// `SettingsPaneState`.
    @StateObject private var cursor = ListCursor()

    private var bySite: Bool { model.grouping == .sites }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // One element per row and its inside, as Connections has
                    // its groups: flattened, the same app under two sites
                    // gave the lazy stack two rows with one identity.
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 0) { rows(item) }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, AdsMetrics.listInset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // One stop, the arrow keys moving through it, as Usage History's
            // and Connections' (#593): ↑ ↓ move the ring, Space opens, Return
            // filters.
            .listKeys(keyRows, cursor: cursor, name: model.grouping.label, proxy: proxy,
                      open: { row, open in model.setExpanded(row.id, open) },
                      filter: { row in
                          if let shown = shownRows.first(where: { selection($0.item, parent: $0.parent).rowID == row.id }) {
                              filter(selection(shown.item, parent: shown.parent))
                          }
                      })
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func rows(_ item: AdsItem) -> some View {
        let largest = max(items.first?.count ?? 1, 1)
        let open = model.isExpanded(item.id)
        row(item, parent: nil, largest: largest, open: item.children.isEmpty ? nil : open)
        if open && !item.children.isEmpty {
            let showingAll = model.showingAll.contains(model.expansionKey(item.id))
            let shown = showingAll ? item.children : Array(item.children.prefix(AdsViewModel.preview))
            Text(L("%@ · %@", bySite ? L("Apps") : L("Sites"), String(item.children.count)))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 58)
                .padding(.top, 4)
                .padding(.bottom, 2)
            ForEach(shown) { child in
                row(child, parent: item, largest: largest, open: nil)
            }
            if item.children.count > shown.count {
                Button(L("Show all %@", String(item.children.count))) {
                    model.showingAll.insert(model.expansionKey(item.id))
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .padding(.leading, 58)
                .padding(.vertical, 4)
            }
        }
    }

    private func row(_ item: AdsItem, parent: AdsItem?, largest: Int64, open: Bool?) -> some View {
        let selection = self.selection(item, parent: parent)
        let isApp = bySite == (parent != nil)
        return HistoryListRow(
            leading: { AnyView(leading(item, isApp: isApp)) },
            title: item.title,
            subtitle: parent == nil ? item.detail : item.last.map { lastBlocked($0) },
            // An app under a site has the site's tags already.
            tags: { iconOnly in
                AnyView(ForEach(isApp && parent != nil ? [] : item.lists, id: \.self) { list in
                    if let topic = BlocklistTopic(rawValue: list) { ListTag(topic: topic, iconOnly: iconOnly) }
                })
            },
            figure: item.count.formatted(),
            fraction: Double(item.count) / Double(largest),
            indented: parent != nil,
            barColor: AppPalette.blocked,
            isSelected: model.selection == selection,
            isCurrent: cursor.marks(selection.rowID),
            disclosure: open,
            onToggleDisclosure: { model.toggleExpanded(item.id) },
            disclosureTakesFocus: false,
            truncation: isApp ? .tail : .middle,
            barMost: AdsMetrics.rowBarWidth,
            figureWidth: AdsMetrics.figureWidth,
            onFilter: { filter(selection) },
            onClick: {
                cursor.id = selection.rowID
                if open != nil { withAnimation(.easeInOut(duration: 0.15)) { model.toggleExpanded(item.id) } }
            })
            .id(selection.rowID)
            .contextMenu {
                AdsRowMenu(model: model,
                           site: isApp ? parent?.id : item.id,
                           app: isApp ? AdsViewModel.RuleApp(key: item.id, name: item.title)
                                      : parent.map { AdsViewModel.RuleApp(key: $0.id, name: $0.title) },
                           lists: item.lists,
                           copy: item.title)
            }
    }

    @ViewBuilder
    private func leading(_ item: AdsItem, isApp: Bool) -> some View {
        if isApp {
            if let icon = model.icon(for: item) {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18).accessibilityHidden(true)
            } else {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            }
        } else {
            // The popover's mark for a site the lists stopped.
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 12))
                .foregroundStyle(AppPalette.blocked)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
        }
    }

    /// "Last blocked 3 – 4 PM", or "Last blocked Tue, Nov 4, 3 – 4 PM" in a
    /// longer period.
    private func lastBlocked(_ hour: Date) -> String {
        let interval = DateInterval(start: hour, duration: 3600)
        let hours = HistoryFormat.binTitle(interval, scale: .day)
        guard model.scale != .day else { return L("Last blocked %@", hours) }
        return L("Last blocked %@", L("%@, %@", HistoryFormat.binTitle(interval, scale: .week), hours))
    }

    // MARK: Filtering

    private func selection(_ item: AdsItem, parent: AdsItem?) -> AdsViewModel.Selection {
        guard let parent else {
            return .init(grouping: model.grouping, parent: item.id, title: item.title)
        }
        let site = bySite ? parent.title : item.title
        let app = bySite ? item.title : parent.title
        return .init(grouping: model.grouping, parent: parent.id, child: item.id, title: L("%@ in %@", site, app))
    }

    /// A row's Filter button, or Return: the list keeps only it, or lets go.
    private func filter(_ selection: AdsViewModel.Selection) {
        cursor.id = selection.rowID
        model.select(selection)
    }

    /// Every row shown, in order, with what it's inside.
    private var shownRows: [(item: AdsItem, parent: AdsItem?)] {
        items.flatMap { item -> [(item: AdsItem, parent: AdsItem?)] in
            guard model.isExpanded(item.id) else { return [(item, nil)] }
            let all = model.showingAll.contains(model.expansionKey(item.id))
            let children = all ? item.children : Array(item.children.prefix(AdsViewModel.preview))
            return [(item, nil)] + children.map { ($0, item) }
        }
    }

    /// The rows shown, as the arrow keys go through them.
    private var keyRows: [KeyRow] {
        shownRows.map { row in
            let selection = selection(row.item, parent: row.parent)
            return KeyRow(id: selection.rowID,
                          spoken: L("%@, %@", row.item.title, row.item.count.formatted()),
                          parent: row.parent?.id,
                          isOpen: row.parent == nil && !row.item.children.isEmpty ? model.isExpanded(row.item.id) : nil,
                          name: row.item.title,
                          isFiltered: model.selection == selection)
        }
    }
}

/// A row's right-click menu (#536), as the Log's: never or always block its
/// site, in every app or only its app; stop filtering its app; remove a rule
/// you made about it; copy its name.
private struct AdsRowMenu: View {
    @ObservedObject var model: AdsViewModel
    let site: String?
    let app: AdsViewModel.RuleApp?
    let lists: [String]
    let copy: String

    var body: some View {
        // Never block wouldn't let it through past a malware list (#317).
        let neverBlocks = lists.isEmpty || !lists.allSatisfy(ListCatalogue.isThreat)
        if let site {
            if neverBlocks {
                Button(L("Never Block %@", site)) { model.setSite(.neverBlock, site: site, app: nil) }
            }
            Button(L("Always Block %@", site)) { model.setSite(.alwaysBlock, site: site, app: nil) }
            if let app {
                if neverBlocks {
                    Button(L("Never Block %@ in %@", site, app.name)) { model.setSite(.neverBlock, site: site, app: app) }
                }
                Button(L("Always Block %@ in %@", site, app.name)) { model.setSite(.alwaysBlock, site: site, app: app) }
            }
        }
        if let app {
            Divider()
            Button(L("Don't Filter Ads in %@", app.name)) { model.dontFilter(app) }
        }
        let rules = model.adRules(site: site, appKey: app?.key)
        if !rules.isEmpty {
            Divider()
            ForEach(rules) { rule in
                Button(L("Remove Your Rule: %@", rule.shownSummary)) { model.remove(rule) }
            }
        }
        Divider()
        Button(L("Copy Name")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copy, forType: .string)
        }
    }
}

// MARK: - Chart (#536)

/// What the lists blocked over the period, one bar per hour, day or month,
/// as Usage History's chart is drawn and read: hover a bar for its figures,
/// click one to narrow the list to it (again, or Escape, to go back), and a
/// row chosen in the list shows its share of each bar.
private struct AdsChart: View {
    @ObservedObject var model: AdsViewModel
    let height: CGFloat
    let width: CGFloat

    private var ticks: [Int64] { AdsAxis.ticks(forMaximum: model.bins.map(\.count).max() ?? 0) }

    private var top: Double { Double(ticks.last ?? 1) }

    var body: some View {
        Chart {
            ForEach(segments) { segment in
                BarMark(x: .value(L("Time"), segment.binStart, unit: model.scale.binComponent),
                        yStart: .value(L("Blocked"), segment.low),
                        yEnd: .value(L("Blocked"), segment.high),
                        width: .fixed(barWidth))
                    .foregroundStyle(color(segment))
                    .cornerRadius(segment.roundsTop ? HistoryMetrics.barRadius : 0)
                    // Each bar is read once, as its period and its figures.
                    .accessibilityLabel(segment.label)
                    .accessibilityValue(segment.value)
                    .accessibilityHidden(!segment.isRead)
            }
        }
        .chartXScale(domain: model.period.start...model.period.end)
        .chartYScale(domain: 0...top)
        .chartYAxis {
            AxisMarks(position: .leading, values: ticks.map(Double.init)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Color.secondary.opacity(0.18))
                AxisValueLabel {
                    if let count = value.as(Double.self) {
                        Text(Int64(count).formatted()).font(.system(size: 10)).monospacedDigit()
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: axisDates) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(HistoryFormat.axisLabel(date, scale: model.scale))
                            .font(.system(size: 10))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                hoverLayer(proxy: proxy, geometry: geometry)
            }
        }
        .frame(height: height)
        .accessibilityLabel(model.scale.binComponent == .hour ? L("Blocked by hour")
                            : model.scale == .year ? L("Blocked by month") : L("Blocked by day"))
    }

    // MARK: Geometry, as Usage History's

    private var plotWidth: CGFloat { width - HistoryMetrics.yAxisWidth }

    private var barWidth: CGFloat {
        let slot = plotWidth / CGFloat(max(model.bins.count, 1))
        return max(1, min(HistoryMetrics.maxBarWidth, (slot * 0.6).rounded()))
    }

    private var unitsPerPoint: Double {
        top / Double(max(height - HistoryMetrics.xAxisHeight, 1))
    }

    struct Segment: Identifiable {
        enum Part { case all, chosen, rest }
        let binStart: Date
        let part: Part
        let low: Double
        let high: Double
        let roundsTop: Bool
        /// The one mark of its bar VoiceOver reads; the others are hidden.
        let isRead: Bool
        let label: String
        let value: String
        var id: String { "\(binStart.timeIntervalSince1970)-\(part)-\(roundsTop)-\(isRead)" }
    }

    /// Each bar, or with a row chosen, the row's part of it at the bottom and
    /// the rest above, 2 pt apart and rounded on top, as Usage History draws
    /// its network types.
    private var segments: [Segment] {
        let gap = HistoryMetrics.segmentGap * unitsPerPoint
        let radius = HistoryMetrics.barRadius * unitsPerPoint
        var result: [Segment] = []
        for bin in model.bins where bin.count > 0 {
            let chosen = model.selection == nil ? nil : min(model.selectedCounts[bin.interval.start] ?? 0, bin.count)
            let parts: [(Segment.Part, Double)] = chosen.map {
                [(.chosen, Double($0)), (.rest, Double(bin.count - $0))].filter { $0.1 > 0 }
            } ?? [(.all, Double(bin.count))]
            let label = HistoryFormat.binTitle(bin.interval, scale: model.scale)
            let value = AdsChart.value(bin.count, chosen: chosen, of: model.selection?.title)
            var base = 0.0
            for (index, part) in parts.enumerated() {
                let isTop = index == parts.count - 1
                let low = index > 0 && part.1 > 2 * gap ? base + gap : base
                let high = base + part.1
                let visibleHigh = max(high, low + unitsPerPoint)
                result.append(Segment(binStart: bin.interval.start, part: part.0, low: low, high: visibleHigh,
                                      roundsTop: isTop, isRead: index == 0, label: label, value: value))
                if isTop && visibleHigh - low > 2 * radius {
                    result.append(Segment(binStart: bin.interval.start, part: part.0, low: low,
                                          high: low + (visibleHigh - low) / 2, roundsTop: false,
                                          isRead: false, label: label, value: value))
                }
                base = high
            }
        }
        return result
    }

    /// "40 blocked", or "40 blocked, 12 of them doubleclick.net".
    static func value(_ count: Int64, chosen: Int64?, of title: String?) -> String {
        let total = L("%@ blocked", count.formatted())
        guard let chosen, let title else { return total }
        return L("%@, %@", total, L("%@ of them %@", chosen.formatted(), title))
    }

    /// The bar under the pointer stands out, or else the bar picked.
    private func isDimmed(_ start: Date) -> Bool {
        if let hovered = model.hoveredBin { return hovered != start }
        if let picked = model.spanStart { return picked != start }
        return false
    }

    private func color(_ segment: Segment) -> Color {
        let dimmed = isDimmed(segment.binStart)
        switch segment.part {
        case .all, .chosen: return AppPalette.blockedFaded(dimmed ? 0.55 : 0)
        case .rest:         return AppPalette.blockedFaded(dimmed ? 0.8 : 0.5)
        }
    }

    /// Where the x-axis labels go, as in Usage History.
    private var axisDates: [Date] {
        let stride: Int
        switch model.scale {
        case .day:   stride = 3
        case .week:  stride = 1
        case .month: stride = 7
        case .year:  stride = 1
        }
        return model.bins.enumerated()
            .filter { $0.offset % stride == 0 }
            .map { $0.element.interval.start + $0.element.interval.duration / 2 }
    }

    // MARK: Hover, as Usage History's

    @ViewBuilder
    private func hoverLayer(proxy: ChartProxy, geometry: GeometryProxy) -> some View {
        let plot = plotFrame(proxy, geometry)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        model.hover(bin(at: location.x - plot.minX, proxy: proxy)?.interval.start)
                    case .ended:
                        model.hover(nil)
                    }
                }
                .onTapGesture { location in
                    if let bin = bin(at: location.x - plot.minX, proxy: proxy), bin.count > 0 {
                        model.pick(binStarting: bin.interval.start)
                    }
                }

            if let start = model.hoveredBin,
               let bin = model.bins.first(where: { $0.interval.start == start }),
               let x = proxy.position(forX: bin.interval.start + bin.interval.duration / 2) {
                let width = HistoryMetrics.tooltipWidth + 30
                tooltip(bin)
                    .frame(width: width)
                    .position(x: min(max(plot.minX + x, width / 2), geometry.size.width - width / 2),
                              y: tooltipY(for: bin, proxy: proxy, plot: plot))
                    .allowsHitTesting(false)
            }
        }
    }

    private func tooltip(_ bin: AdsViewModel.Bin) -> ChartTooltip {
        var lines: [ChartTooltip.Line] = []
        if let selection = model.selection {
            lines.append(.init(color: AppPalette.blocked,
                               value: (model.selectedCounts[bin.interval.start] ?? 0).formatted(),
                               label: selection.title))
        }
        return ChartTooltip(title: HistoryFormat.binTitle(bin.interval, scale: model.scale),
                            figure: L("%@ blocked", bin.count.formatted()), lines: lines)
    }

    private func tooltipY(for bin: AdsViewModel.Bin, proxy: ChartProxy, plot: CGRect) -> CGFloat {
        let barTop = proxy.position(forY: Double(bin.count)).map { plot.minY + $0 } ?? plot.minY
        let height = ChartTooltip.height(lines: model.selection == nil ? 0 : 1)
        return max(barTop - 8 - height / 2, plot.minY + height / 2)
    }

    private func plotFrame(_ proxy: ChartProxy, _ geometry: GeometryProxy) -> CGRect {
        if #available(macOS 14, *) {
            return proxy.plotFrame.map { geometry[$0] } ?? .zero
        }
        return geometry[proxy.plotAreaFrame]
    }

    private func bin(at x: CGFloat, proxy: ChartProxy) -> AdsViewModel.Bin? {
        guard let date: Date = proxy.value(atX: x) else { return nil }
        let bins = model.bins
        guard let index = UsageHistory.binIndex(of: date, in: bins.map(\.interval.start)),
              bins[index].interval.contains(date)
        else { return nil }
        return bins[index]
    }
}

enum AdsMetrics {
    /// What the toolbar needs with the View in it (#524) and search open:
    /// 812, measured with `make design-shots` and `--measure`, so no control
    /// is ever hidden in the toolbar's » menu (#315). It was 700 before the
    /// View, as Connections' and Usage History's have it.
    static let minWidth: CGFloat = 820
    static let minHeight: CGFloat = 480
    /// Sites and Apps are Usage History's rows (#536): this either side of
    /// them puts a row's name in line with the header's 20 pt.
    static let listInset: CGFloat = 12
    static let rowBarWidth: CGFloat = 90
    static let figureWidth: CGFloat = 48
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
                           label: { $0.label }, size: .small,
                           help: L("Every decision, or only some"))
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
                .foregroundStyle(entry.isBlocked ? AppPalette.blocked : Color.secondary)
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
