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
        VStack(alignment: .leading, spacing: 14) {
            navigation
            filterBar
            summary
            HistoryChart(model: model)
            legend
            Divider()
            lists
            Divider()
            footer
        }
        .padding(20)
        // Up to, as Settings' forms are: see `SettingsWindowController.paneHost`.
        .frame(maxWidth: HistoryMetrics.windowWidth)
    }

    // MARK: Navigation

    private var navigation: some View {
        HStack(spacing: 10) {
            Picker("Show", selection: Binding(get: { model.scale }, set: { model.scale = $0 })) {
                ForEach(HistoryScale.allCases) { scale in
                    Text(scale.label).tag(scale)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            Button { model.step(-1) } label: {
                Image(systemName: "chevron.left").frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .disabled(!model.canStepBack)
            .keyboardShortcut(.leftArrow, modifiers: [.command])
            .help("Previous \(model.scale.label.lowercased())")

            Text(model.title)
                .font(.system(size: 13, weight: .semibold))
                .frame(minWidth: 160)

            Button { model.step(1) } label: {
                Image(systemName: "chevron.right").frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .disabled(!model.canStepForward)
            .keyboardShortcut(.rightArrow, modifiers: [.command])
            .help("Next \(model.scale.label.lowercased())")

            // Held in place but hidden on the current period, where it would
            // only repeat the title beside it.
            Button(presentLabel) { model.goToPresent() }
                .disabled(model.isCurrent)
                .opacity(model.isCurrent ? 0 : 1)
        }
    }

    private var presentLabel: String {
        switch model.scale {
        case .day:   return "Today"
        case .week:  return "This Week"
        case .month: return "This Month"
        case .year:  return "This Year"
        }
    }

    // MARK: Filters

    /// Always the same height, so choosing a filter never shifts the chart.
    private var filterBar: some View {
        HStack(spacing: 6) {
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
                FilterChip(label: "Session", onClear: model.clearSession)
            }
            if model.filter.appKey == nil && model.filter.networkID == nil
                && model.filter.sessionID == nil {
                Text("Click an app, network or session to see only its usage.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Toggle("Metered only",
                   isOn: Binding(get: { model.meteredOnly }, set: { model.meteredOnly = $0 }))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .help("Only connections NetworkMonitor counted as metered, such as a hotspot")
        }
        .frame(height: 22)
    }

    // MARK: Summary

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 32) {
            stat("Total", ByteFormat.bytes(report.total), prominent: true)
            if model.scale != .day {
                let days = report.period.elapsedDays(now: Date())
                stat("Daily average",
                     days > 0 ? ByteFormat.bytes(report.total / Int64(days)) : "—")
            }
            if !model.meteredOnly {
                stat("On metered connections", ByteFormat.bytes(report.meteredBytes))
            }
            Spacer()
        }
    }

    private func stat(_ label: String, _ value: String, prominent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: prominent ? 22 : 15, weight: prominent ? .semibold : .medium,
                              design: .rounded))
        }
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

    private var lists: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("List", selection: $model.tab) {
                ForEach(HistoryViewModel.Tab.allCases) { tab in
                    Text(tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch model.tab {
                    case .apps:     appRows
                    case .networks: networkRows
                    case .sessions: sessionRows
                    }
                }
            }
            .frame(height: HistoryMetrics.listHeight)
            .overlay {
                if isListEmpty { emptyList }
            }
        }
    }

    private var isListEmpty: Bool {
        switch model.tab {
        case .apps:     return report.apps.isEmpty && report.systemRows.isEmpty
        case .networks: return report.networks.isEmpty
        case .sessions: return report.sessions.isEmpty
        }
    }

    private var emptyList: some View {
        VStack(spacing: 4) {
            if report.recordingSince == nil {
                Text("No history yet")
                    .font(.system(size: 13, weight: .medium))
                Text("NetworkMonitor keeps every hour from now on, per app and per network.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("Nothing used in this period")
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
        ForEach(report.apps) { row in
            appRow(row, largest: largest, indented: false)
            if model.expandedApps.contains(row.id) {
                ForEach(row.children) { child in
                    appRow(child, largest: largest, indented: true)
                }
            }
        }
        if !report.systemRows.isEmpty {
            HistoryListRow(
                leading: { AnyView(Image(nsImage: model.icon(for: systemSummary))
                    .resizable().frame(width: 18, height: 18)) },
                title: "System (\(report.systemRows.count))",
                subtitle: nil,
                bytes: report.systemTotal,
                fraction: fraction(report.systemTotal, of: largest),
                isMuted: true,
                isSelected: false,
                disclosure: model.systemExpanded,
                onToggleDisclosure: { model.systemExpanded.toggle() },
                onSelect: { model.systemExpanded.toggle() })
            if model.systemExpanded {
                ForEach(report.systemRows) { row in
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
                .resizable().frame(width: 18, height: 18)) },
            title: row.displayName,
            subtitle: nil,
            bytes: row.total,
            fraction: fraction(row.total, of: largest),
            indented: indented,
            isSelected: model.filter.appKey == row.id,
            disclosure: row.hasChildren ? model.expandedApps.contains(row.id) : nil,
            onToggleDisclosure: { model.toggleExpanded(row.id) },
            onSelect: { model.toggleApp(row.id) })
    }

    @ViewBuilder
    private var networkRows: some View {
        let largest = max(report.networks.first?.bytes ?? 0, 1)
        ForEach(report.networks) { network in
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
                Button("Rename…") {
                    model.rename(networkID: network.id, defaultLabel: network.defaultLabel,
                                 in: NSApp.keyWindow)
                }
            }
        }
    }

    @ViewBuilder
    private var sessionRows: some View {
        let largest = max(report.sessions.map(\.bytes).max() ?? 0, 1)
        ForEach(report.sessions) { total in
            let session = total.session
            HistoryListRow(
                leading: { AnyView(KindBadge(kind: session.kind)) },
                title: model.networkName(session.networkID, defaultLabel: session.defaultLabel),
                subtitle: HistoryFormat.sessionSpan(session) + " · "
                    + HistoryFormat.duration(session.end.timeIntervalSince(session.start)),
                isMetered: session.isMetered,
                bytes: total.bytes,
                fraction: fraction(total.bytes, of: largest),
                barColor: HistoryPalette.color(for: session.kind),
                isSelected: model.filter.sessionID == session.id,
                onSelect: { model.toggleSession(session.id) })
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Keep history for")
                .font(.system(size: 12))
            Picker("Keep history for",
                   selection: Binding(get: { model.retention },
                                      set: { model.requestRetention($0, in: NSApp.keyWindow) })) {
                ForEach(HistoryRetention.allCases) { retention in
                    Text(retention.label).tag(retention)
                }
            }
            .labelsHidden()
            .fixedSize()
            Spacer()
            Button("Clear History…") { model.confirmClear(in: NSApp.keyWindow) }
            Button("Export CSV…") { model.export(in: NSApp.keyWindow) }
        }
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
        .frame(height: HistoryMetrics.chartHeight)
        .accessibilityLabel("Usage by \(model.scale.binComponent == .hour ? "hour" : model.scale == .year ? "month" : "day")")
    }

    // MARK: Geometry

    private var plotWidth: CGFloat {
        HistoryMetrics.windowWidth - 40 - HistoryMetrics.yAxisWidth
    }

    /// At most 24 pt, and never more than 60% of a bar's slot.
    private var barWidth: CGFloat {
        let slot = plotWidth / CGFloat(max(report.bins.count, 1))
        return min(HistoryMetrics.maxBarWidth, (slot * 0.6).rounded())
    }

    /// One data unit, in bytes, per point of plot height.
    private var bytesPerPoint: Double {
        top / Double(HistoryMetrics.chartHeight - HistoryMetrics.xAxisHeight)
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
    var indented = false
    var isMuted = false
    /// The network type's colour on the Networks and Sessions lists, so a row
    /// matches its part of the chart; the accent colour for apps.
    var barColor: Color = .accentColor
    let isSelected: Bool
    /// nil for a row with nothing to expand; otherwise whether it is open.
    var disclosure: Bool?
    var onToggleDisclosure: () -> Void = {}
    let onSelect: () -> Void

    /// Not `@State`, which needs Xcode from the macOS 27 SDK on.
    @StateObject private var hover = HistoryRowHover()

    var body: some View {
        HStack(spacing: 8) {
            if indented { Spacer().frame(width: 22) }
            disclosureButton
            leading()
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(indented || isMuted
                                         ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if isMetered {
                        Text("METERED")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
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
            Capsule()
                .fill(barColor.opacity(isMuted ? 0.5 : 0.85))
                .frame(width: max(3, HistoryMetrics.rowBarWidth * min(max(fraction, 0), 1)),
                       height: 5)
                .frame(width: HistoryMetrics.rowBarWidth, alignment: .leading)
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
        .help(isSelected ? "Click to show everything again" : "Click to see only \(title)")
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
            .foregroundStyle(.secondary)
        } else {
            Spacer().frame(width: 12)
        }
    }
}

private final class HistoryRowHover: ObservableObject {
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

private struct FilterChip: View {
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
            .help("Show everything again")
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
    static let windowWidth: CGFloat = 768
    static let chartHeight: CGFloat = 200
    static let xAxisHeight: CGFloat = 22
    static let yAxisWidth: CGFloat = 46
    static let maxBarWidth: CGFloat = 24
    static let barRadius: CGFloat = 3
    static let segmentGap: CGFloat = 2
    static let tooltipWidth: CGFloat = 150
    static let listHeight: CGFloat = 220
    static let rowBarWidth: CGFloat = 150
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
        case .wifi:     return dynamic(light: 0x2A78D6, dark: 0x3987E5, fade: fade)
        case .hotspot:  return dynamic(light: 0xEB6834, dark: 0xD95926, fade: fade)
        case .ethernet: return dynamic(light: 0x1BAF7A, dark: 0x199E70, fade: fade)
        default:        return dynamic(light: 0xEDA100, dark: 0xC98500, fade: fade)
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
        case .day:   return date.formatted(.dateTime.hour())
        case .week:  return date.formatted(.dateTime.weekday(.abbreviated))
        case .month: return date.formatted(.dateTime.day())
        case .year:  return date.formatted(.dateTime.month(.abbreviated))
        }
    }

    /// "9 – 10 AM", "Wed, Oct 21", "October 2026".
    static func binTitle(_ interval: DateInterval, scale: HistoryScale) -> String {
        switch scale {
        case .day:
            let formatter = DateIntervalFormatter()
            formatter.dateTemplate = "j"
            return formatter.string(from: interval.start, to: interval.end)
        case .week, .month:
            return interval.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .year:
            return interval.start.formatted(.dateTime.month(.wide).year())
        }
    }

    /// "Today 09:02 – 12:30", "Oct 21, 22:10 – Oct 22, 07:45".
    static func sessionSpan(_ session: HistorySession) -> String {
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        if Calendar.current.isDate(session.start, inSameDayAs: session.end) {
            let day = Calendar.current.isDateInToday(session.start) ? "Today"
                : Calendar.current.isDateInYesterday(session.start) ? "Yesterday"
                : session.start.formatted(.dateTime.month(.abbreviated).day())
            formatter.dateStyle = .none
            return day + ", " + formatter.string(from: session.start, to: session.end)
        }
        return formatter.string(from: session.start, to: session.end)
    }

    /// "3 h 28 min", "12 min", "under a minute".
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else { return "under a minute" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? ""
    }
}
