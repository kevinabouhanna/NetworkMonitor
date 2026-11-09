import AppKit
import FirewallPolicy
import SwiftUI

/// The popover's four buttons (#436): each shows its own view under them,
/// without opening a window. Today, the apps, is where the popover opens.
public enum PopoverSection: String, CaseIterable, Identifiable {
    case today, companies, blocked, connection
    public var id: String { rawValue }
}

/// The colours the popover's numbers keep everywhere they appear (#436):
/// data in the accent colour, companies in teal, blocked in red. A hotspot is
/// orange, as the popover already marks one. The chosen button is marked by
/// looking raised, never by a colour.
enum PopoverPalette {
    static let data = Color.accentColor
    static let companies = Color.teal
    static let blocked = Color.red
    static let hotspot = Color.orange
}

extension PopoverMetrics {
    /// Each of the Companies, Blocked and Connection views, one height for
    /// all three, so the popover doesn't change size moving between them.
    public static let sectionHeight: CGFloat = 220
    /// A row in the Companies and Blocked views.
    public static let summaryRowHeight: CGFloat = 28
    /// The row at the end of a view that opens its window, and the footer.
    public static let openRowHeight: CGFloat = 40
}

/// The four buttons across the header: the number that matters, and what it is.
struct PopoverButtons: View {
    @Binding var selection: PopoverSection
    let today: String
    let companies: String
    let blocked: String
    let blockedIsOn: Bool
    let connection: String
    let isHotspot: Bool

    var body: some View {
        HStack(spacing: 4) {
            button(.today, value: today, label: L("Today"), color: PopoverPalette.data,
                   help: L("Data used today, by app"))
            button(.companies, value: companies, label: L("Companies"), color: PopoverPalette.companies,
                   help: L("Who your apps talked to today"))
            button(.blocked, value: blocked, label: L("Ads blocked"),
                   color: blockedIsOn ? PopoverPalette.blocked : .primary,
                   help: L("Ads, trackers and malware sites blocked today"))
            button(.connection, value: connection, label: L("Network"),
                   color: isHotspot ? PopoverPalette.hotspot : .primary,
                   help: L("What the Mac is connected to, and whether it's a hotspot"))
        }
    }

    private func button(_ section: PopoverSection, value: String, label: String, color: Color,
                        help: String) -> some View {
        let chosen = selection == section
        return Button { selection = section } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
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
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlColor))
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(L("%@, %@", label, value))
        .accessibilityAddTraits(chosen ? [.isSelected] : [])
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
        .padding(.horizontal, 12)
        .frame(height: PopoverMetrics.openRowHeight)
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
private struct PopoverList<Content: View>: View {
    /// The rows on screen, the open ones' children included.
    let rows: Int
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) { content }
                .padding(.vertical, PopoverMetrics.listVerticalPadding / 2)
        }
        .frame(height: PopoverMetrics.listHeight(appRows: rows, expandedChildRows: 0, systemRowCount: 0,
                                                 systemExpanded: false))
        .scrollIndicators(PopoverMetrics.scrolls(appRows: rows, expandedChildRows: 0, systemRowCount: 0,
                                                 systemExpanded: false) ? .automatic : .never)
    }
}

/// Companies: who the apps talked to today, each opening into the apps that
/// talked to it, as Today's apps open into their parts; then Open Connections.
struct PopoverCompanies: View {
    @ObservedObject var glance: TodayGlance
    let icon: (String, String, String?) -> NSImage
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if glance.companies.isEmpty {
                SummaryMessage(title: glance.hasLoaded ? L("No connections yet today") : L("Reading today…"),
                               detail: L("Connections are counted while NetworkMonitor is running."))
                    .frame(height: PopoverMetrics.sectionHeight)
            } else {
                SummaryCaption(text: caption)
                PopoverList(rows: rowCount) {
                    ForEach(glance.companies) { group in
                        let item = group.item
                        let apps = self.apps(of: group)
                        let open = glance.expanded.contains(item.id)
                        PopoverRow(title: item.title, value: ByteFormat.bytes(item.total),
                                   icon: .symbol(item.isHost ? "server.rack" : "building.2",
                                                 PopoverPalette.companies),
                                   fraction: fraction(item.total), barColor: PopoverPalette.companies,
                                   isExpanded: open,
                                   onToggle: apps.isEmpty ? nil : {
                                       withAnimation(.easeInOut(duration: 0.15)) { glance.toggle(item.id) }
                                   })
                        if open {
                            ForEach(apps) { app in
                                PopoverRow(title: app.title, value: ByteFormat.bytes(app.total),
                                           icon: .image(icon(app.key, app.title, app.bundlePath)),
                                           fraction: fraction(app.total), barColor: PopoverPalette.companies,
                                           indented: true)
                            }
                        }
                    }
                }
            }
            Divider()
            PopoverOpenRow(title: L("Open Connections"), shortcut: "⌘K", action: onOpen)
        }
    }

    private func apps(of group: ConnectionsGroup) -> [ConnectionsItem] {
        group.sections.first { $0.dimension == .app }?.items ?? []
    }

    private var rowCount: Int {
        glance.companies.reduce(0) { count, group in
            count + 1 + (glance.expanded.contains(group.item.id) ? apps(of: group).count : 0)
        }
    }

    /// Each bar is a share of all of today's traffic to servers.
    private func fraction(_ bytes: Int64) -> Double {
        let total = glance.summary.bytesIn + glance.summary.bytesOut
        return total > 0 ? Double(bytes) / Double(total) : 0
    }

    private var caption: String {
        let countries = glance.summary.countries
        var parts = [countries == 1 ? L("1 country") : L("%@ countries", String(countries))]
        if glance.blockedConnections > 0 {
            parts.append(glance.blockedConnections == 1 ? L("1 connection blocked")
                         : L("%@ connections blocked", glance.blockedConnections.formatted()))
        }
        return L("Today · %@", parts.joined(separator: " · "))
    }
}

/// Ads blocked: what the lists stopped today, by site, each opening into the
/// apps that tried it; then Open Ads and Trackers.
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
            } else if glance.ads.sites.isEmpty {
                SummaryMessage(title: pausedText ?? L("Nothing blocked yet today"),
                               detail: L("Sites the lists stop show here, busiest first."))
                    .frame(height: PopoverMetrics.sectionHeight)
            } else {
                SummaryCaption(text: pausedText ?? L("Today · by site"))
                PopoverList(rows: rowCount) {
                    ForEach(sites) { site in
                        let apps = glance.siteApps[site.id] ?? []
                        let open = glance.expanded.contains(rowID(site))
                        PopoverRow(title: site.title, value: site.count.formatted(),
                                   icon: .symbol("shield.lefthalf.filled", PopoverPalette.blocked),
                                   fraction: fraction(site.count), barColor: PopoverPalette.blocked,
                                   isExpanded: open,
                                   onToggle: apps.isEmpty ? nil : {
                                       withAnimation(.easeInOut(duration: 0.15)) { glance.toggle(rowID(site)) }
                                   })
                        if open {
                            ForEach(apps) { app in
                                PopoverRow(title: app.title, value: app.count.formatted(),
                                           icon: .image(icon(app.id, app.title, app.bundlePath)),
                                           fraction: fraction(app.count), barColor: PopoverPalette.blocked,
                                           indented: true)
                            }
                        }
                    }
                }
            }
            Divider()
            PopoverOpenRow(title: L("Open Ads and Trackers"), shortcut: "⌘B", action: onOpen)
        }
    }

    private var sites: [AdsItem] { Array(glance.ads.sites.prefix(TodayGlance.rows)) }

    /// Kept apart from a company of the same name in `expanded`.
    private func rowID(_ site: AdsItem) -> String { "site:" + site.id }

    private var rowCount: Int {
        sites.reduce(0) { count, site in
            count + 1 + (glance.expanded.contains(rowID(site)) ? (glance.siteApps[site.id]?.count ?? 0) : 0)
        }
    }

    /// Each bar is a share of everything blocked today.
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
