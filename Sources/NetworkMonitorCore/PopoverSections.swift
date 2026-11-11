import AppKit
import FirewallPolicy
import SwiftUI

/// The popover's four buttons (#436): each shows its own view under them,
/// without opening a window. Today, the apps, is where the popover opens.
public enum PopoverSection: String, CaseIterable, Identifiable {
    case today, companies, blocked, connection
    public var id: String { rawValue }
}

/// The popover's colours: the app's own (#436).
enum PopoverPalette {
    static let data = AppPalette.data
    static let companies = AppPalette.connections
    static let blocked = AppPalette.blocked
    static let hotspot = AppPalette.hotspot
}

extension PopoverMetrics {
    /// Each of the Companies, Blocked and Connection views, one height for
    /// all three, so the popover doesn't change size moving between them.
    public static let sectionHeight: CGFloat = 220
    /// The row at the end of a view that opens its window, and the footer.
    public static let openRowHeight: CGFloat = 40
    /// The leading edge the header's switch, its buttons' raised backgrounds
    /// and a list's switch all start from (#436).
    public static let edge: CGFloat = 12
}

/// The four buttons across the header: the number that matters, and what it
/// is. The first three cover the period chosen above them (#449); Network is
/// about now.
struct PopoverButtons: View {
    @Binding var selection: PopoverSection
    /// Not `@State`; see `SettingsPaneState`. A property wrapper, not a macro.
    @Namespace private var raised
    let period: PopoverPeriod
    let data: String
    let connections: String
    let blocked: String
    let blockedIsOn: Bool
    let connection: String
    let isHotspot: Bool

    var body: some View {
        HStack(spacing: 2) {
            button(.today, value: data, label: L("Data"), period: period, color: PopoverPalette.data,
                   help: L("Data your apps used, on every network"))
            button(.companies, value: connections, label: L("Connections"), period: period,
                   color: PopoverPalette.companies,
                   help: L("Connections: each app talking to a server counts once"))
            button(.blocked, value: blocked, label: L("Ads blocked"), period: period,
                   color: blockedIsOn ? PopoverPalette.blocked : .primary,
                   help: L("Ads, trackers and malware sites blocked"))
            button(.connection, value: connection, label: L("Network"), period: nil,
                   color: isHotspot ? PopoverPalette.hotspot : .primary,
                   help: L("What the Mac is connected to, and whether it's a hotspot"))
        }
    }

    private func button(_ section: PopoverSection, value: String, label: String, period: PopoverPeriod?,
                        color: Color, help: String) -> some View {
        let chosen = selection == section
        return Button { withAnimation(Motion.choice) { selection = section } } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(Motion.content, value: value)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 5)
            .padding(.vertical, 5)
            .background {
                if chosen {
                    // Raised, in the control's own grey: no colour for a state.
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(color.opacity(0.14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(color.opacity(0.35), lineWidth: 1)
                        }
                        .matchedGeometryEffect(id: "raised", in: raised)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(period.map { L("%@ · %@", help, $0.phrase) } ?? help)
        // The period is read with the number, since the switch above isn't
        // read with the buttons: "Data, This week, 38 GB".
        .accessibilityLabel(period.map { L("%@, %@, %@", label, $0.phrase, value) } ?? L("%@, %@", label, value))
        .accessibilityAddTraits(chosen ? [.isSelected] : [])
    }
}

/// A small segmented switch: the popover's period, and what each view
/// groups by (#449).
struct PopoverSwitch<Value: Hashable & Identifiable>: View {
    let name: String
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    /// The period is the larger: it scopes everything under it.
    var size: GlassSegmented<Value>.Size = .regular

    var body: some View {
        GlassSegmented(name: name, options: options, selection: $selection, label: label, size: size)
    }
}

/// Above a view's list: what it groups by, and how many there are (#449).
struct PopoverGroupingRow<Value: Hashable & Identifiable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    let count: String

    var body: some View {
        HStack(spacing: 8) {
            PopoverSwitch(name: L("Group by"), options: options, selection: $selection, label: label, size: .small)
            Spacer(minLength: 4)
            Text(count)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, PopoverMetrics.edge)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

/// The row at the end of a view that opens its window: "Open Connections ⌘K".
struct PopoverOpenRow: View {
    let title: String
    let shortcut: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(shortcut).font(.system(size: 11)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(PopoverShortcut(shortcut))
        .padding(.horizontal, 12)
        .frame(height: PopoverMetrics.openRowHeight)
    }
}

/// "⌘K" shown on an Open row also works there (#436): the app has no menu
/// to answer it while no window is open.
private struct PopoverShortcut: ViewModifier {
    let key: Character?
    init(_ shortcut: String) {
        key = shortcut.hasPrefix("⌘") ? shortcut.dropFirst().first.map { Character($0.lowercased()) } : nil
    }

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(KeyEquivalent(key), modifiers: .command)
        } else {
            content
        }
    }
}

/// A short line above a view's rows, or a message in place of them.
private struct SummaryCaption: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SummaryMessage: View {
    let title: String
    let detail: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.title, action: action.run).controlSize(.small)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The list Companies and Ads blocked share with Today (#436): as tall as
/// its rows up to the same cap, scrolling past it, with rows that open.
struct PopoverList<Content: View>: View {
    /// The rows on screen, the open ones' children included.
    let rows: Int
    var cap: CGFloat = PopoverMetrics.maxListHeight
    @ViewBuilder let content: Content

    init(rows: Int, cap: CGFloat = PopoverMetrics.maxListHeight, @ViewBuilder content: () -> Content) {
        self.rows = rows
        self.cap = cap
        self.content = content()
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) { content }
                .padding(.vertical, PopoverMetrics.listVerticalPadding / 2)
        }
        .frame(height: PopoverMetrics.listHeight(appRows: rows, expandedChildRows: 0, systemRowCount: 0,
                                                 systemExpanded: false, cap: cap))
        .scrollIndicators(PopoverMetrics.scrolls(appRows: rows, expandedChildRows: 0, systemRowCount: 0,
                                                 systemExpanded: false, cap: cap) ? .automatic : .never)
        // Tab goes through every row before the Open row under the list,
        // those scrolled out of sight too (#455).
        .focusSection()
    }
}

/// Connections: who the apps talked to in the period, by company, country
/// or app, each opening into what's behind it, as Data's apps open into their
/// parts; then Open Connections (#449).
struct PopoverCompanies: View {
    @ObservedObject var glance: TodayGlance
    let icon: (String, String, String?) -> NSImage
    let onOpen: () -> Void

    /// In the order Kevin named them (#449).
    static let groupings: [ConnectionsGrouping] = [.companies, .countries, .apps]

    var body: some View {
        VStack(spacing: 0) {
            PopoverGroupingRow(options: Self.groupings, selection: $glance.connectionsGrouping,
                               label: { $0.label }, count: count)
            // Overlapping while they cross (#436): stacked, the popover
            // grew by the incoming view's height, then shrank again.
            ZStack(alignment: .top) {
                Group {
                    if glance.groups.isEmpty {
                        SummaryMessage(title: glance.hasLoaded ? L("No connections yet") : L("Reading…"),
                                       detail: L("Connections are counted while NetworkMonitor is running."))
                            .frame(height: PopoverMetrics.sectionHeight)
                    } else {
                        PopoverList(rows: max(rowCount, tallestGrouping)) {
                            ForEach(glance.groups) { group in
                                let item = group.item
                                let parts = self.parts(of: group)
                                let open = glance.expanded.contains(item.id)
                                PopoverRow(title: item.title, value: ByteFormat.bytes(item.total),
                                           icon: rowIcon(item),
                                           fraction: fraction(item.total), barColor: PopoverPalette.companies,
                                           isExpanded: open,
                                           onToggle: parts.isEmpty ? nil : {
                                               withAnimation(Motion.content) { glance.toggle(item.id) }
                                           })
                                if open {
                                    ForEach(parts) { part in
                                        PopoverRow(title: part.title, value: ByteFormat.bytes(part.total),
                                                   icon: rowIcon(part),
                                                   fraction: fraction(part.total), barColor: PopoverPalette.companies,
                                                   indented: true)
                                    }
                                }
                            }
                        }
                    }
                }
                .id(glance.connectionsGrouping)
                .transition(Motion.swap)
            }
            Divider()
            PopoverOpenRow(title: L("Open Connections"), shortcut: "⌘K", action: onOpen)
        }
    }

    /// What a row opens into: a company's or a country's apps or companies,
    /// an app's companies, as the window's first section under it.
    private func parts(of group: ConnectionsGroup) -> [ConnectionsItem] {
        Array((group.sections.first?.items ?? []).prefix(TodayGlance.rows))
    }

    private func rowIcon(_ item: ConnectionsItem) -> PopoverRowIcon {
        switch item.dimension {
        case .app:
            return .image(icon(item.key, item.title, item.bundlePath))
        case .country:
            if let flag = item.symbol { return .text(flag) }
            return .symbol("globe", PopoverPalette.companies)
        default:
            return .symbol(item.isHost ? "server.rack" : "building.2", PopoverPalette.companies)
        }
    }

    private var count: String {
        let summary = glance.summary
        switch glance.connectionsGrouping {
        case .companies:
            return summary.companies == 1 ? L("1 company") : L("%@ companies", String(summary.companies))
        case .countries:
            return summary.countries == 1 ? L("1 country") : L("%@ countries", String(summary.countries))
        case .apps:
            return summary.apps == 1 ? L("1 app") : L("%@ apps", String(summary.apps))
        }
    }

    private var rowCount: Int {
        glance.groups.reduce(0) { count, group in
            count + 1 + (glance.expanded.contains(group.item.id) ? parts(of: group).count : 0)
        }
    }

    /// One height whichever grouping is shown (#436): the most rows any of
    /// them has, so switching never shrinks the popover and grows it again.
    private var tallestGrouping: Int {
        let summary = glance.summary
        return min(max(summary.companies, summary.countries, summary.apps), TodayGlance.rows)
    }

    /// Each bar is a share of all the period's traffic to servers.
    private func fraction(_ bytes: Int64) -> Double {
        let total = glance.summary.bytesIn + glance.summary.bytesOut
        return total > 0 ? Double(bytes) / Double(total) : 0
    }
}

/// Ads blocked: what the lists stopped in the period, by site or by app,
/// each opening into the apps that tried a site or the sites an app tried;
/// then Open Ads and Trackers (#449).
struct PopoverBlocked: View {
    @ObservedObject var glance: TodayGlance
    @ObservedObject var firewall: FirewallRules
    @ObservedObject var filter: FilterController
    let pausedText: String?
    let icon: (String, String, String?) -> NSImage
    let onTurnOn: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if firewall.lists.isEmpty {
                SummaryMessage(title: L("Ad blocking is off"),
                               detail: L("Turn it on to stop ads, trackers and malware sites in every app."),
                               action: filter.state == .unavailable ? nil : (L("Turn On"), onTurnOn))
                    .frame(height: PopoverMetrics.sectionHeight)
            } else {
                PopoverGroupingRow(options: PopoverAdsGrouping.allCases, selection: $glance.adsGrouping,
                                   label: { $0.label }, count: count)
                if let pausedText { SummaryCaption(text: pausedText) }
                // Overlapping while they cross (#436): stacked, the popover
                // grew by the incoming view's height, then shrank again.
                ZStack(alignment: .top) {
                    Group {
                        if items.isEmpty {
                            SummaryMessage(title: L("Nothing blocked yet"),
                                           detail: L("Sites the lists stop show here, busiest first."))
                                .frame(height: PopoverMetrics.sectionHeight)
                        } else {
                            PopoverList(rows: max(rowCount, tallestGrouping)) {
                                ForEach(items) { item in
                                    let parts = self.parts(of: item)
                                    let open = glance.expanded.contains(rowID(item))
                                    PopoverRow(title: item.title, value: item.count.formatted(),
                                               icon: rowIcon(item, isApp: !bySite),
                                               fraction: fraction(item.count), barColor: PopoverPalette.blocked,
                                               isExpanded: open,
                                               onToggle: parts.isEmpty ? nil : {
                                                   withAnimation(Motion.content) { glance.toggle(rowID(item)) }
                                               })
                                    if open {
                                        ForEach(parts) { part in
                                            PopoverRow(title: part.title, value: part.count.formatted(),
                                                       icon: rowIcon(part, isApp: bySite),
                                                       fraction: fraction(part.count), barColor: PopoverPalette.blocked,
                                                       indented: true)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .id(glance.adsGrouping)
                    .transition(Motion.swap)
                }
            }
            Divider()
            PopoverOpenRow(title: L("Open Ads and Trackers"), shortcut: "⌘B", action: onOpen)
        }
    }

    private var bySite: Bool { glance.adsGrouping == .sites }

    private var items: [AdsItem] {
        Array((bySite ? glance.ads.sites : glance.ads.apps).prefix(TodayGlance.rows))
    }

    private func parts(of item: AdsItem) -> [AdsItem] {
        Array(((bySite ? glance.siteApps : glance.appSites)[item.id] ?? []).prefix(TodayGlance.rows))
    }

    private func rowIcon(_ item: AdsItem, isApp: Bool) -> PopoverRowIcon {
        isApp ? .image(icon(item.id, item.title, item.bundlePath))
              : .symbol("shield.lefthalf.filled", PopoverPalette.blocked)
    }

    /// Kept apart from a company of the same name in `expanded`, and a site
    /// from an app.
    private func rowID(_ item: AdsItem) -> String { (bySite ? "site:" : "blockedApp:") + item.id }

    private var count: String {
        if bySite {
            let sites = glance.ads.sites.count
            return sites == 1 ? L("1 site") : L("%@ sites", String(sites))
        }
        let apps = glance.ads.apps.count
        return apps == 1 ? L("1 app") : L("%@ apps", String(apps))
    }

    private var rowCount: Int {
        items.reduce(0) { count, item in
            count + 1 + (glance.expanded.contains(rowID(item)) ? parts(of: item).count : 0)
        }
    }

    /// One height for Sites and Apps (#436), as for Connections' groupings.
    private var tallestGrouping: Int {
        min(max(glance.ads.sites.count, glance.ads.apps.count), TodayGlance.rows)
    }

    /// Each bar is a share of everything blocked in the period.
    private func fraction(_ count: Int64) -> Double {
        glance.ads.total > 0 ? Double(count) / Double(glance.ads.total) : 0
    }
}

/// Connection: what the Mac is on, and on every kind of network a switch to
/// say it's a hotspot, since a phone isn't always recognised (#436).
struct PopoverConnection: View {
    @ObservedObject var metering: MeteringController
    @ObservedObject var speedTest: SpeedTestController
    let status: ConnectionStatus
    let onHotspotSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 17))
                        .foregroundStyle(isHotspot ? Color.white : Color.primary)
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 9)
                            .fill(isHotspot ? PopoverPalette.hotspot : Color.primary.opacity(0.08)))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(status.name ?? status.medium ?? L("No connection"))
                            .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(PopoverConnection.word(status, metering: metering))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                if status.kind != .offline {
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("This is a hotspot")).font(.system(size: 13, weight: .semibold))
                            Text(subtext)
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Toggle(L("This is a hotspot"), isOn: Binding(get: { metering.verdict.isMetered },
                                                                     set: metering.setHotspot))
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
                    if SpeedTestRunner.isAvailable { speedRow }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(height: PopoverMetrics.sectionHeight)
            PopoverOpenRow(title: L("Open Network"), shortcut: "", action: onHotspotSettings)
        }
    }

    private var isHotspot: Bool { metering.verdict.isMetered }

    /// The speed test, for this connection: the last result, and a button.
    private var speedRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Speed test")).font(.system(size: 12, weight: .medium))
                Text(lastResult).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button(speedTest.phase.isRunning ? L("Show") : L("Test Speed")) {
                if speedTest.phase != .idle && !speedTest.isPresented { speedTest.present() } else { speedTest.run() }
            }
            .controlSize(.small)
            .disabled(speedTest.phase.isRunning && speedTest.isPresented)
        }
        .padding(.horizontal, 2)
    }

    private var lastResult: String {
        guard let result = speedTest.lastResult else { return L("Not tested yet") }
        return L("↓ %@  ↑ %@ · %@", ByteFormat.speed(result.downloadBitsPerSecond, unit: speedTest.unit),
                 ByteFormat.speed(result.uploadBitsPerSecond, unit: speedTest.unit),
                 result.finishedAt.formatted(date: .omitted, time: .shortened))
    }

    private var symbol: String {
        if isHotspot { return "personalhotspot" }
        switch status.kind {
        case .ethernet: return "cable.connector"
        case .offline:  return "wifi.slash"
        default:        return "wifi"
        }
    }

    /// What the switch does, and that you set it, once you have.
    private var subtext: String {
        let what = metering.isEnabled
            ? L("Pauses app updates and iCloud downloads while you're on this network.")
            : L("Stopping app updates on hotspots is off: switch it on in Network.")
        return metering.override == nil ? what : what + "\n" + L("Marked by you for this network.")
    }

    /// The word on the Connection button: Wi-Fi, Ethernet or Hotspot.
    static func word(_ status: ConnectionStatus, metering: MeteringController) -> String {
        if status.kind == .offline { return L("Offline") }
        if metering.verdict.isMetered { return L("Hotspot") }
        switch status.kind {
        case .ethernet:      return L("Ethernet")
        case .wifi, .hotspot: return L("Wi-Fi")
        default:             return status.medium ?? L("Other")
        }
    }
}
