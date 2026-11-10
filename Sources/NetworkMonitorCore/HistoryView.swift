import AppKit
import Charts
import SwiftUI

/// The Usage History window.
///
/// One column, read top to bottom: which period, what it is narrowed to, how
/// much, when, and then who — apps, networks or visits. The lists double as the
/// filters: clicking a row narrows the whole window to it, chart included, and
/// its chip above the chart undoes that. That replaces a row of pop-up menus
/// with the list the user was already reading.
public struct HistoryView: View {
    @ObservedObject var model: HistoryViewModel

    public init(model: HistoryViewModel) {
        self.model = model
    }

    private var report: HistoryReport { model.report }

    public var body: some View {
        VStack(alignment: .leading, spacing: ScopeMetrics.below) {
            scopeBar
            heading
            // The toolbar's View (#524): the list on the left and the chart
            // on the right, the chart's legend under it, as Connections has
            // its list and map (#534).
            switch model.layout {
            case .both:
                SideBySide {
                    listStack
                } detail: {
                    VStack(alignment: .leading, spacing: 10) {
                        GeometryReader { geometry in
                            HistoryChart(model: model, height: geometry.size.height, width: geometry.size.width)
                        }
                        legend
                    }
                    .padding(12)
                    .splitCard()
                }
            case .list:
                legend
                Divider()
                listStack
            case .chart:
                GeometryReader { geometry in
                    HistoryChart(model: model, height: geometry.size.height)
                }
                .frame(minHeight: HistoryMetrics.chartHeight, maxHeight: .infinity)
                legend
            }
            Divider()
            footer
        }
        .padding(.horizontal, ScopeMetrics.inset)
        .padding(.top, ScopeMetrics.top)
        .padding(.bottom, 14)
        .background(periodShortcuts)
        .frame(minWidth: HistoryMetrics.windowMinWidth, minHeight: HistoryMetrics.windowMinHeight)
    }

    /// Overlapping while one tab's list gives way to another's.
    private var listStack: some View {
        ZStack(alignment: .top) { list }
    }

    // MARK: Scope

    /// What the list shows and which networks, in one row under the toolbar,
    /// as Connections has it (#436). The period, ‹ Today › and the gear are in
    /// the window's toolbar (`HistoryWindowController`).
    private var scopeBar: some View {
        HStack(spacing: 10) {
            // Which list, while there's one to show (#524).
            if model.layout.showsList {
                LabelledControl(L("Show")) {
                    GlassSegmented(name: L("Show"), options: HistoryViewModel.Tab.allCases, selection: $model.tab,
                                   label: { $0.label }, size: .small)
                        .help(L("Apps, networks or each visit to a network. A row narrows the window to it."))
                }
            }
            if hasChips {
                if model.layout.showsList { Divider().frame(height: 16) }
                HStack(spacing: 6) { chips }
            }
            Spacer(minLength: 12)
            // Wi-Fi and Hotspot, the two kinds asked for in #70. Ethernet and
            // Other stay under All, and on the Networks list.
            GlassSegmented(name: L("Networks"), options: [nil, .wifi, .hotspot],
                           selection: Binding(get: { model.kind }, set: { model.kind = $0 }),
                           label: { $0?.historyLabel ?? L("All") }, size: .small)
                .help(L("Every connection, Wi-Fi only, or hotspots only"))
        }
        .frame(height: ScopeMetrics.height)
    }

    private var hasChips: Bool {
        model.filteredAppName != nil || model.filteredNetworkName != nil || model.filter.sessionID != nil
            || !query.isEmpty
    }

    /// ⌘← and ⌘→ step through periods, as in Connections. The toolbar's arrows
    /// do the same with the pointer.
    private var periodShortcuts: some View {
        ZStack {
            Button(L("Previous")) { model.step(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .disabled(!model.canStepBack)
            Button(L("Next")) { model.step(1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                .disabled(!model.canStepForward)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: Filters

    /// What History is narrowed to, as chips at the end of the lists' row,
    /// beside the row that was clicked to add one (#192).
    @ViewBuilder
    private var chips: some View {
        // The toolbar's search, as a filter like the others (#436).
        if !query.isEmpty {
            FilterChip(label: L("“%@”", query), onClear: { model.search = "" })
        }
        if let name = model.filteredAppName {
            FilterChip(label: name, onClear: model.clearApp)
        }
        if let name = model.filteredNetworkName {
            FilterChip(label: name, onClear: model.clearNetwork)
        }
        if let session = model.filteredSession {
            FilterChip(label: model.networkName(session.networkID,
                                                defaultLabel: session.defaultLabel)
                           + " · " + HistoryFormat.sessionSpan(session),
                       onClear: model.clearSession)
        } else if model.filter.sessionID != nil {
            FilterChip(label: L("Session"), onClear: model.clearSession)
        }
    }

    // MARK: Heading

    /// The period's name, then the total, then what was metered and the daily
    /// average as one quieter line.
    private var heading: some View {
        var details: [String] = []
        // Only when there's some: "0 B on metered connections" says nothing.
        if model.kind == nil && report.meteredBytes > 0 {
            details.append(L("%@ on metered connections", ByteFormat.bytes(report.meteredBytes)))
        }
        if model.scale != .day {
            let days = report.period.elapsedDays(now: Date())
            if days > 0 { details.append(L("%@ a day on average", ByteFormat.bytes(report.total / Int64(days)))) }
        }
        return PeriodHeading(title: model.title, figure: ByteFormat.bytes(report.total),
                             caption: L("used"), details: details)
    }

    // MARK: Legend

    /// Each network type with its total for the period. Doubles as the chart's
    /// table of values, so no figure is only readable by hovering.
    private var legend: some View {
        HStack(spacing: 18) {
            ForEach(NetworkFingerprint.Kind.charted, id: \.self) { kind in
                if let bytes = report.byKind[kind], bytes > 0 {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(HistoryPalette.color(for: kind))
                            .frame(width: 10, height: 10)
                        Text(kind.historyLabel)
                            .foregroundStyle(.secondary)
                        Text(ByteFormat.bytes(bytes))
                            .monospacedDigit()
                    }
                    .font(.system(size: 11))
                }
            }
            Spacer()
        }
        .frame(height: 14)
    }

    // MARK: Lists

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                switch model.tab {
                case .apps:     appRows
                case .networks: networkRows
                case .sessions: sessionRows
                }
            }
        }
        .frame(minHeight: HistoryMetrics.listMinHeight, maxHeight: .infinity)
        .overlay {
            if isListEmpty { emptyList }
        }
        // Another tab's list fades in as the switch's pill slides (#436).
        .id(model.tab)
        .transition(Motion.swap)
    }

    private var isListEmpty: Bool {
        switch model.tab {
        case .apps:     return apps.isEmpty && systemRows.isEmpty
        case .networks: return networks.isEmpty
        case .sessions: return sessions.isEmpty
        }
    }

    // MARK: Search (#436)

    private var query: String { model.search.trimmingCharacters(in: .whitespaces) }

    private func matches(_ name: String) -> Bool {
        query.isEmpty || name.localizedCaseInsensitiveContains(query)
    }

    /// An app shows when its name or one of its parts' matches.
    private var apps: [UsageRow] {
        report.apps.filter { matches($0.displayName) || $0.children.contains { matches($0.displayName) } }
    }

    private var systemRows: [UsageRow] { report.systemRows.filter { matches($0.displayName) } }

    private var networks: [HistoryReport.NetworkTotal] {
        report.networks.filter { matches(model.networkName($0.id, defaultLabel: $0.defaultLabel)) }
    }

    private var sessions: [HistoryReport.SessionTotal] {
        report.sessions.filter {
            matches(model.networkName($0.session.networkID, defaultLabel: $0.session.defaultLabel))
        }
    }

    private var emptyList: some View {
        VStack(spacing: 4) {
            if !query.isEmpty && report.recordingSince != nil {
                Text(L("Nothing matches “%@”", query))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if report.recordingSince == nil {
                Text(L("No history yet"))
                    .font(.system(size: 13, weight: .medium))
                Text(L("NetworkMonitor keeps every hour from now on, per app and per network."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text(L("Nothing used in this period"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Every row's bar is measured against the biggest row on its list.
    private func fraction(_ bytes: Int64, of largest: Int64) -> Double {
        largest > 0 ? Double(bytes) / Double(largest) : 0
    }

    @ViewBuilder
    private var appRows: some View {
        let largest = max((report.apps.map(\.total) + [report.systemTotal]).max() ?? 0, 1)
        ForEach(apps) { row in
            appRow(row, largest: largest, indented: false)
            if model.expandedApps.contains(row.id) {
                ForEach(row.children) { child in
                    appRow(child, largest: largest, indented: true)
                }
            }
        }
        if !systemRows.isEmpty {
            HistoryListRow(
                leading: { AnyView(Image(nsImage: model.icon(for: systemSummary))
                    .resizable().frame(width: 18, height: 18).accessibilityHidden(true)) },
                title: L("System (%@)", String(systemRows.count)),
                subtitle: nil,
                bytes: report.systemTotal,
                fraction: fraction(report.systemTotal, of: largest),
                kinds: systemRows.reduce(into: [:]) {
                    $0.merge($1.kinds, uniquingKeysWith: +)
                },
                isMuted: true,
                isSelected: false,
                disclosure: model.systemExpanded,
                onToggleDisclosure: { model.systemExpanded.toggle() },
                onSelect: { model.systemExpanded.toggle() })
            if model.systemExpanded {
                ForEach(systemRows) { row in
                    appRow(row, largest: largest, indented: true)
                }
            }
        }
    }

    private var systemSummary: UsageRow {
        UsageRow(id: "\u{1}system", displayName: "System", bytesIn: 0, bytesOut: 0,
                 bundlePath: nil, isSystem: true, isActive: false)
    }

    private func appRow(_ row: UsageRow, largest: Int64, indented: Bool) -> some View {
        HistoryListRow(
            leading: { AnyView(Image(nsImage: model.icon(for: row))
                .resizable().frame(width: 18, height: 18).accessibilityHidden(true)) },
            title: row.displayName,
            subtitle: nil,
            bytes: row.total,
            fraction: fraction(row.total, of: largest),
            kinds: row.kinds,
            indented: indented,
            isSelected: model.filter.appKey == row.id,
            disclosure: row.hasChildren ? model.expandedApps.contains(row.id) : nil,
            onToggleDisclosure: { model.toggleExpanded(row.id) },
            onSelect: { model.toggleApp(row.id) })
    }

    @ViewBuilder
    private var networkRows: some View {
        let largest = max(report.networks.first?.bytes ?? 0, 1)
        ForEach(networks) { network in
            HistoryListRow(
                leading: { AnyView(KindBadge(kind: network.kind)) },
                title: model.networkName(network.id, defaultLabel: network.defaultLabel),
                subtitle: nil,
                isMetered: network.isMetered,
                bytes: network.bytes,
                fraction: fraction(network.bytes, of: largest),
                barColor: HistoryPalette.color(for: network.kind),
                isSelected: model.filter.networkID == network.id,
                onSelect: { model.toggleNetwork(network.id) })
            .contextMenu {
                Button(L("Rename…")) {
                    model.rename(networkID: network.id, defaultLabel: network.defaultLabel,
                                 in: NSApp.keyWindow)
                }
            }
        }
    }

    @ViewBuilder
    private var sessionRows: some View {
        let largest = max(report.sessions.map(\.bytes).max() ?? 0, 1)
        ForEach(sessions) { total in
            let session = total.session
            let updates = report.updates(in: session.id)
            HistoryListRow(
                leading: { AnyView(KindBadge(kind: session.kind)) },
                title: model.networkName(session.networkID, defaultLabel: session.defaultLabel),
                subtitle: HistoryFormat.sessionSpan(session) + " · "
                    + HistoryFormat.duration(session.end.timeIntervalSince(session.start))
                    + (updates.isEmpty ? "" : " · " + Self.gotThrough(updates.count)),
                isMetered: session.isMetered,
                bytes: total.bytes,
                fraction: fraction(total.bytes, of: largest),
                barColor: HistoryPalette.color(for: session.kind),
                isSelected: model.filter.sessionID == session.id,
                onSelect: { model.toggleSession(session.id) })
            // Listed once the visit is chosen: what got through on it (#96).
            if model.filter.sessionID == session.id {
                ForEach(updates) { update in
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle").foregroundStyle(.orange)
                        Text(update.label)
                        Spacer(minLength: 8)
                        Text(update.amount).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11))
                    .padding(.leading, 34)
                    .padding(.trailing, 8)
                    .padding(.vertical, 3)
                }
            }
        }
    }

    static func gotThrough(_ count: Int) -> String {
        count == 1 ? L("1 update got through") : L("%@ updates got through", String(count))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text(L("Every hour is kept on this Mac, per app and per network."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button(L("Export CSV…")) { model.export(in: NSApp.keyWindow) }
        }
    }
}

/// Usage History's settings (#436): how long to keep it, and clearing it. The
/// history itself is in the Usage History window.
struct HistorySettingsPane: View {
    @ObservedObject var model: HistoryViewModel
    let onOpen: () -> Void

    var body: some View {
        Form {
            Section {
                SettingsStatusLine(title: L("%@ used today", ByteFormat.bytes(model.todayTotal)),
                                   detail: L("Every hour is kept on this Mac, per app and per network"),
                                   action: L("Open Usage History…"), help: L("Also ⌘Y"), onAction: onOpen)
            }
            Section {
                LabeledContent(L("Keep history for")) {
                    Picker(L("Keep history for"),
                           selection: Binding(get: { model.retention },
                                              set: { model.requestRetention($0, in: NSApp.keyWindow) })) {
                        ForEach(HistoryRetention.allCases) { retention in
                            Text(retention.label).tag(retention)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                LabeledContent(L("Clear History")) {
                    Button(L("Clear History…")) { model.confirmClear(in: NSApp.keyWindow) }
                }
            } footer: {
                SettingsFootnote(L("Usage History never leaves this Mac. Clearing it can't be undone."))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Chart

/// Stacked bars by network type, one per hour, day or month.
///
/// Stacked by hand rather than with `foregroundStyle(by:)`, for two things
/// Swift Charts will not do on its own: a 2 pt gap between the segments of a
/// bar, and rounding only the top of the bar, so it still stands square on
/// the baseline.
private struct HistoryChart: View {
    @ObservedObject var model: HistoryViewModel
    /// The chart's height: fixed above the list, the window's when it's
    /// the chart alone (#524).
    var height: CGFloat = HistoryMetrics.chartHeight
    /// The chart's width, beside the list (#534); otherwise the bars are
    /// as wide as they always were.
    var width: CGFloat?

    private var report: HistoryReport { model.report }

    private var ticks: [Int64] { HistoryAxis.ticks(forMaximum: report.peakBin) }

    private var top: Double { Double(ticks.last ?? 1024) }

    var body: some View {
        Chart {
            ForEach(segments) { segment in
                BarMark(x: .value("Time", segment.binStart, unit: model.scale.binComponent),
                        yStart: .value("Bytes", segment.low),
                        yEnd: .value("Bytes", segment.high),
                        width: .fixed(barWidth))
                    .foregroundStyle(HistoryPalette.color(for: segment.kind,
                                                          dimmed: isDimmed(segment.binStart)))
                    .cornerRadius(segment.roundsTop ? HistoryMetrics.barRadius : 0)
            }
        }
        .chartXScale(domain: report.period.start...report.period.end)
        .chartYScale(domain: 0...top)
        .chartYAxis {
            AxisMarks(position: .leading, values: ticks.map(Double.init)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Color.secondary.opacity(0.18))
                AxisValueLabel {
                    if let bytes = value.as(Double.self) {
                        Text(HistoryAxis.label(Int64(bytes), inUnitOf: Int64(top)))
                            .font(.system(size: 10))
                            .monospacedDigit()
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
        .accessibilityLabel(model.scale.binComponent == .hour ? L("Usage by hour") : model.scale == .year ? L("Usage by month") : L("Usage by day"))
    }

    // MARK: Geometry

    private var plotWidth: CGFloat {
        (width ?? SettingsMetrics.paneWidth - 40) - HistoryMetrics.yAxisWidth
    }

    /// At most 24 pt, and never more than 60% of a bar's slot.
    private var barWidth: CGFloat {
        let slot = plotWidth / CGFloat(max(report.bins.count, 1))
        return min(HistoryMetrics.maxBarWidth, (slot * 0.6).rounded())
    }

    /// One data unit, in bytes, per point of plot height.
    private var bytesPerPoint: Double {
        top / Double(max(height - HistoryMetrics.xAxisHeight, 1))
    }

    struct Segment: Identifiable {
        let binStart: Date
        let kind: NetworkFingerprint.Kind
        let low: Double
        let high: Double
        let roundsTop: Bool
        var id: String { "\(binStart.timeIntervalSince1970)-\(kind.rawValue)" }
    }

    /// Each bar's segments in legend order, bottom up, with the gap taken from
    /// the segment above it so the bar's height is still its total.
    ///
    /// The top segment is drawn twice: rounded, and again square over its lower
    /// half, which is how a bar gets rounded corners on top only.
    private var segments: [Segment] {
        let gap = HistoryMetrics.segmentGap * bytesPerPoint
        let radius = HistoryMetrics.barRadius * bytesPerPoint
        var result: [Segment] = []
        for bin in report.bins {
            let parts = NetworkFingerprint.Kind.charted.compactMap { kind -> (NetworkFingerprint.Kind, Double)? in
                guard let bytes = bin.byKind[kind], bytes > 0 else { return nil }
                return (kind, Double(bytes))
            }
            var base = 0.0
            for (index, part) in parts.enumerated() {
                let isTop = index == parts.count - 1
                let low = index > 0 && part.1 > 2 * gap ? base + gap : base
                let high = base + part.1
                // A sliver still shows: a real but tiny hour is not zero.
                let visibleHigh = max(high, low + bytesPerPoint)
                result.append(Segment(binStart: bin.interval.start, kind: part.0,
                                      low: low, high: visibleHigh, roundsTop: isTop))
                if isTop && visibleHigh - low > 2 * radius {
                    result.append(Segment(binStart: bin.interval.start, kind: part.0,
                                          low: low, high: low + (visibleHigh - low) / 2,
                                          roundsTop: false))
                }
                base = high
            }
        }
        return result
    }

    /// Every bar but the hovered one steps back, so the one being read stands out.
    private func isDimmed(_ binStart: Date) -> Bool {
        model.hoveredBin.map { $0 != binStart } ?? false
    }

    /// Where the x-axis labels go: every third hour of a day, every day of a
    /// week, every seventh of a month, every month of a year — centred under
    /// their bar.
    private var axisDates: [Date] {
        let bins = report.bins
        let stride: Int
        switch model.scale {
        case .day:   stride = 3
        case .week:  stride = 1
        case .month: stride = 7
        case .year:  stride = 1
        }
        return bins.enumerated()
            .filter { $0.offset % stride == 0 }
            .map { $0.element.interval.start + $0.element.interval.duration / 2 }
    }

    // MARK: Hover

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
                    if let bin = bin(at: location.x - plot.minX, proxy: proxy), bin.total > 0 {
                        model.open(binStarting: bin.interval.start)
                    }
                }

            if let start = model.hoveredBin,
               let bin = report.bins.first(where: { $0.interval.start == start }),
               let x = proxy.position(forX: bin.interval.start + bin.interval.duration / 2) {
                let width = HistoryMetrics.tooltipWidth
                HistoryTooltip(bin: bin, scale: model.scale,
                               canOpen: model.scale.drillDown != nil && bin.total > 0)
                    .frame(width: width)
                    .position(x: min(max(plot.minX + x, width / 2), geometry.size.width - width / 2),
                              y: tooltipY(for: bin, proxy: proxy, plot: plot))
                    .allowsHitTesting(false)
            }
        }
    }

    /// Above the bar when there is room, otherwise over the top of the plot.
    private func tooltipY(for bin: HistoryReport.Bin, proxy: ChartProxy, plot: CGRect) -> CGFloat {
        let barTop = proxy.position(forY: Double(bin.total)).map { plot.minY + $0 } ?? plot.minY
        let height = HistoryTooltip.height(kinds: bin.byKind.filter { $0.value > 0 }.count)
        let above = barTop - 8 - height / 2
        return max(above, plot.minY + height / 2)
    }

    private func plotFrame(_ proxy: ChartProxy, _ geometry: GeometryProxy) -> CGRect {
        if #available(macOS 14, *) {
            return proxy.plotFrame.map { geometry[$0] } ?? .zero
        }
        return geometry[proxy.plotAreaFrame]
    }

    private func bin(at x: CGFloat, proxy: ChartProxy) -> HistoryReport.Bin? {
        guard let date: Date = proxy.value(atX: x) else { return nil }
        guard let index = UsageHistory.binIndex(of: date, in: report.bins.map(\.interval.start)),
              report.bins[index].interval.contains(date)
        else { return nil }
        return report.bins[index]
    }
}

/// The hovered bar's figures: the total first, then each network type.
private struct HistoryTooltip: View {
    let bin: HistoryReport.Bin
    let scale: HistoryScale
    let canOpen: Bool

    static func height(kinds: Int) -> CGFloat {
        CGFloat(38 + 15 * kinds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(HistoryFormat.binTitle(bin.interval, scale: scale))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(ByteFormat.bytes(bin.total))
                .font(.system(size: 13, weight: .semibold))
            ForEach(NetworkFingerprint.Kind.charted, id: \.self) { kind in
                if let bytes = bin.byKind[kind], bytes > 0 {
                    HStack(spacing: 5) {
                        Capsule()
                            .fill(HistoryPalette.color(for: kind))
                            .frame(width: 8, height: 2)
                        Text(ByteFormat.bytes(bytes))
                            .monospacedDigit()
                        Text(kind.historyLabel)
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 10))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
    }
}

// MARK: - Rows

/// One row of any of the three lists: something on the left, a name, a bar
/// for its share, and its figure.
private struct HistoryListRow: View {
    let leading: () -> AnyView
    let title: String
    let subtitle: String?
    var isMetered = false
    let bytes: Int64
    let fraction: Double
    /// An app's bytes by network type, which split its bar into the chart's
    /// colours (#70). Empty for Networks and Sessions, which are one type each.
    var kinds: [NetworkFingerprint.Kind: Int64] = [:]
    var indented = false
    var isMuted = false
    /// The network type's colour on the Networks and Sessions lists, so a row
    /// matches its part of the chart. Apps take theirs from `kinds`.
    var barColor: Color = AppPalette.data
    let isSelected: Bool
    /// nil for a row with nothing to expand; otherwise whether it is open.
    var disclosure: Bool?
    var onToggleDisclosure: () -> Void = {}
    let onSelect: () -> Void

    /// Not `@State`, which needs Xcode from the macOS 27 SDK on.
    @StateObject private var hover = HistoryRowHover()
    @Environment(\.splitListWidth) private var listWidth
    private var barWidth: CGFloat {
        SplitMetrics.bar(listWidth: listWidth,
                         fixed: HistoryMetrics.rowFixed + (indented ? HistoryMetrics.rowIndent : 0),
                         most: HistoryMetrics.rowBarWidth)
    }

    var body: some View {
        HStack(spacing: 8) {
            if indented { Spacer().frame(width: 22) }
            disclosureButton
            leading()
            VStack(alignment: .leading, spacing: 1) {
                NameBeforeTags {
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(indented || isMuted
                                         ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } tags: { iconOnly in
                    if isMetered {
                        RowTag(word: L("METERED"), symbol: "antenna.radiowaves.left.and.right",
                               color: .orange, iconOnly: iconOnly)
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            bar
                .frame(width: barWidth, alignment: .leading)
            Text(ByteFormat.bytes(bytes))
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: subtitle == nil ? 30 : 38)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18)
                      : hover.isHovering ? Color.secondary.opacity(0.08) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hover.isHovering = $0 }
        .onTapGesture(perform: onSelect)
        .help(isSelected ? L("Click to show everything again") : L("Click to see only %@", title))
    }

    /// The row's share of the biggest row. Split by network type, it reads as
    /// that row's part of the chart: Wi-Fi then Hotspot, left to right, 1 pt
    /// apart as the chart's segments are 2 pt apart.
    private var bar: some View {
        let width = max(3, barWidth * min(max(fraction, 0), 1))
        let total = Double(kinds.values.reduce(0, +))
        let gap: CGFloat = 1
        // Parts under 2 pt read as noise on a short bar, not as a share. The
        // Networks list has the exact split.
        var parts = NetworkFingerprint.Kind.charted.filter { kind in
            total > 0 && Double(kinds[kind] ?? 0) / total * width >= 2
        }
        if parts.isEmpty, let largest = kinds.max(by: { $0.value < $1.value })?.key {
            parts = [largest.charted]
        }
        let room = width - gap * CGFloat(max(parts.count - 1, 0))
        let shown = Double(parts.reduce(0) { $0 + (kinds[$1] ?? 0) })
        return HStack(spacing: gap) {
            if parts.isEmpty {
                Rectangle().fill(barColor)
            } else {
                ForEach(parts, id: \.self) { kind in
                    Rectangle()
                        .fill(HistoryPalette.color(for: kind))
                        .frame(width: room * Double(kinds[kind] ?? 0) / max(shown, 1))
                }
            }
        }
        .frame(width: width, height: 5)
        .clipShape(Capsule())
        .opacity(isMuted ? 0.5 : 0.85)
    }

    @ViewBuilder
    private var disclosureButton: some View {
        if let open = disclosure {
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { onToggleDisclosure() } }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 12, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(open ? L("Collapse") : L("Expand"))
            .foregroundStyle(.secondary)
        } else {
            Spacer().frame(width: 12)
        }
    }
}

final class HistoryRowHover: ObservableObject {
    @Published var isHovering = false
}

/// A network type's chart colour, as a swatch, with its symbol.
private struct KindBadge: View {
    let kind: NetworkFingerprint.Kind

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(HistoryPalette.color(for: kind))
            .frame(width: 18, height: 18)
            .overlay(
                Image(systemName: HistoryPalette.symbol(for: kind))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white))
    }
}

struct FilterChip: View {
    let label: String
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L("Show everything again"))
        }
        .font(.system(size: 11))
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.15), in: Capsule())
        // Its own width: a flexible frame would centre the chip in a gap.
        .fixedSize()
    }
}

// MARK: - Shared values

enum HistoryMetrics {
    /// The Usage History window (#436): wide enough for its toolbar and the
    /// scope row with search open, measured on the app as #315 asks.
    static let windowMinWidth: CGFloat = 894
    static let windowMinHeight: CGFloat = 560
    /// The list's least height, under the chart.
    static let listMinHeight: CGFloat = 160
    static let chartHeight: CGFloat = 200
    static let xAxisHeight: CGFloat = 22
    static let yAxisWidth: CGFloat = 46
    static let maxBarWidth: CGFloat = 24
    static let barRadius: CGFloat = 3
    static let segmentGap: CGFloat = 2
    static let tooltipWidth: CGFloat = 150
    static let listHeight: CGFloat = 220
    static let rowBarWidth: CGFloat = 150
    /// A list row's width besides its name and bar: 8 pt padding each side,
    /// the disclosure (12), what's on the left (18), five 8 pt gaps, the
    /// least space before the bar (12) and the figure (76).
    static let rowFixed: CGFloat = 16 + 12 + 18 + 5 * 8 + 12 + 76
    /// An indented row's indent and its gap.
    static let rowIndent: CGFloat = 22 + 8
}

/// The chart's four colours, one per network type, in light and dark steps.
///
/// Fixed to the type, never to rank, so Hotspot is the same orange whether or
/// not Wi-Fi is in the period. Checked as a set with the data-viz palette
/// validator: adjacent pairs clear the colour-blind separation target in both
/// modes. Two light steps sit under 3:1 against the window, which is why the
/// legend and the Networks list carry every figure as text.
public enum HistoryPalette {

    /// `dimmed` mixes the colour into the window background rather than
    /// lowering its opacity: a bar's top segment is drawn as two overlapping
    /// marks, and two translucent marks would show their overlap.
    public static func color(for kind: NetworkFingerprint.Kind, dimmed: Bool = false) -> Color {
        let fade: CGFloat = dimmed ? 0.55 : 0
        switch kind.charted {
        // Data is blue everywhere (#436): the kinds of network are shades
        // of it, and a hotspot, the one that costs, is orange.
        case .wifi:     return AppPalette.dynamic(light: 0x1A6BD8, dark: 0x5AA9FF, fade: fade)
        case .hotspot:  return AppPalette.dynamic(light: 0xD9570F, dark: 0xFF9A3D, fade: fade)
        case .ethernet: return AppPalette.dynamic(light: 0x0F4C9E, dark: 0x2F7BE0, fade: fade)
        default:        return AppPalette.dynamic(light: 0x7EA6DA, dark: 0x9CC7FF, fade: fade)
        }
    }

    static func symbol(for kind: NetworkFingerprint.Kind) -> String {
        switch kind.charted {
        case .wifi:     return "wifi"
        case .hotspot:  return "personalhotspot"
        case .ethernet: return "cable.connector.horizontal"
        default:        return "network"
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32, fade: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            let color = NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                                green: CGFloat((hex >> 8) & 0xFF) / 255,
                                blue: CGFloat(hex & 0xFF) / 255,
                                alpha: 1)
            guard fade > 0 else { return color }
            // Resolved under the same appearance, so the mix is against the
            // background actually behind the chart.
            var background = NSColor.windowBackgroundColor
            appearance.performAsCurrentDrawingAppearance {
                background = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? background
            }
            return color.blended(withFraction: fade, of: background) ?? color
        })
    }
}

/// Date and duration wording for the window.
enum HistoryFormat {

    static func axisLabel(_ date: Date, scale: HistoryScale) -> String {
        switch scale {
        case .day:   return date.formatted(.dateTime.hour().locale(Localization.shared.locale))
        case .week:  return date.formatted(.dateTime.weekday(.abbreviated).locale(Localization.shared.locale))
        case .month: return date.formatted(.dateTime.day().locale(Localization.shared.locale))
        case .year:  return date.formatted(.dateTime.month(.abbreviated).locale(Localization.shared.locale))
        }
    }

    /// "9 – 10 AM", "Wed, Oct 21", "October 2026".
    static func binTitle(_ interval: DateInterval, scale: HistoryScale) -> String {
        switch scale {
        case .day:
            let formatter = DateIntervalFormatter()
            formatter.locale = Localization.shared.locale
            formatter.dateTemplate = "j"
            return formatter.string(from: interval.start, to: interval.end)
        case .week, .month:
            return interval.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(Localization.shared.locale))
        case .year:
            return interval.start.formatted(.dateTime.month(.wide).year().locale(Localization.shared.locale))
        }
    }

    /// "Today 09:02 – 12:30", "Oct 21, 22:10 – Oct 22, 07:45".
    static func sessionSpan(_ session: HistorySession) -> String {
        let formatter = DateIntervalFormatter()
        formatter.locale = Localization.shared.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        if Calendar.current.isDate(session.start, inSameDayAs: session.end) {
            let day = Calendar.current.isDateInToday(session.start) ? L("Today")
                : Calendar.current.isDateInYesterday(session.start) ? L("Yesterday")
                : session.start.formatted(.dateTime.month(.abbreviated).day().locale(Localization.shared.locale))
            formatter.dateStyle = .none
            return L("%@, %@", day, formatter.string(from: session.start, to: session.end))
        }
        return formatter.string(from: session.start, to: session.end)
    }

    /// "3 h 28 min", "12 min", "under a minute".
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else { return L("under a minute") }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? ""
    }
}
