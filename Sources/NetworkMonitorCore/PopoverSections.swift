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
    public static let sectionHeight: CGFloat = 176
    /// A row in the Companies and Blocked views.
    public static let summaryRowHeight: CGFloat = 28
    /// The row at the end of a view that opens its window, and the footer.
    public static let openRowHeight: CGFloat = 40
    public static let footerHeight: CGFloat = 32
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
            button(.blocked, value: blocked, label: L("Blocked"),
                   color: blockedIsOn ? PopoverPalette.blocked : .primary,
                   help: L("Ads, trackers and malware sites blocked today"))
            button(.connection, value: connection, label: L("Connection"),
                   color: isHotspot ? PopoverPalette.hotspot : .primary,
                   help: L("What the Mac is connected to, and whether it's a hotspot"))
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 7)
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

/// Settings, named, at the bottom of the popover (#436).
struct PopoverFooter: View {
    let onSettings: () -> Void

    var body: some View {
        Button(action: onSettings) {
            HStack(spacing: 6) {
                Image(systemName: "gearshape").accessibilityHidden(true)
                Text(L("Settings…"))
                Spacer()
                Text("⌘,").foregroundStyle(.tertiary).accessibilityHidden(true)  // untranslated: a shortcut
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .frame(height: PopoverMetrics.footerHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Settings (⌘,)"))
    }
}

/// One row of the Companies or Blocked view: a name, a bar and a figure.
private struct SummaryRow: View {
    let symbol: String
    let title: String
    let value: String
    let fraction: Double
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Capsule().fill(color)
                    .frame(width: max(PopoverMetrics.minBarWidth, fraction * 150), height: 3)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 8)
            Text(value).font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
        }
        .frame(height: PopoverMetrics.summaryRowHeight)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
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

/// Companies: who the apps talked to today, then Open Connections.
struct PopoverCompanies: View {
    @ObservedObject var glance: TodayGlance
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if glance.companies.isEmpty {
                    SummaryMessage(title: glance.hasLoaded ? L("No connections yet today") : L("Reading today…"),
                                   detail: L("Connections are counted while NetworkMonitor is running."))
                } else {
                    VStack(spacing: 0) {
                        SummaryCaption(text: caption)
                        let top = max(glance.companies.first?.total ?? 1, 1)
                        ForEach(glance.companies) { item in
                            SummaryRow(symbol: "building.2", title: item.title, value: ByteFormat.bytes(item.total),
                                       fraction: Double(item.total) / Double(top), color: PopoverPalette.companies)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(height: PopoverMetrics.sectionHeight)
            PopoverOpenRow(title: L("Open Connections"), shortcut: "⌘K", action: onOpen)
        }
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

/// Blocked: what the lists stopped today, by site, then Open Ads and Trackers.
struct PopoverBlocked: View {
    @ObservedObject var glance: TodayGlance
    @ObservedObject var firewall: FirewallRules
    @ObservedObject var filter: FilterController
    let pausedText: String?
    let onTurnOn: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if filter.state == .unavailable {
                    SummaryMessage(title: L("Ad blocking isn't in this build"),
                                   detail: L("It needs the content filter, which only the signed app has."))
                } else if firewall.lists.isEmpty {
                    SummaryMessage(title: L("Ad blocking is off"),
                                   detail: L("Turn it on to stop ads, trackers and malware sites in every app."),
                                   action: (L("Turn On"), onTurnOn))
                } else if glance.ads.sites.isEmpty {
                    SummaryMessage(title: pausedText ?? L("Nothing blocked yet today"),
                                   detail: L("Sites the lists stop show here, busiest first."))
                } else {
                    VStack(spacing: 0) {
                        SummaryCaption(text: pausedText ?? L("Today · by site"))
                        let sites = Array(glance.ads.sites.prefix(TodayGlance.rows))
                        let top = max(sites.first?.count ?? 1, 1)
                        ForEach(sites) { site in
                            SummaryRow(symbol: "shield.lefthalf.filled", title: site.title,
                                       value: site.count.formatted(),
                                       fraction: Double(site.count) / Double(top), color: PopoverPalette.blocked)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(height: PopoverMetrics.sectionHeight)
            PopoverOpenRow(title: L("Open Ads and Trackers"), shortcut: "⌘B", action: onOpen)
        }
    }
}

/// Connection: what the Mac is on, and on every kind of network a switch to
/// say it's a hotspot, since a phone isn't always recognised (#436).
struct PopoverConnection: View {
    @ObservedObject var metering: MeteringController
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
                                                                     set: setHotspot))
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(height: PopoverMetrics.sectionHeight)
            PopoverOpenRow(title: L("Hotspot Settings"), shortcut: "", action: onHotspotSettings)
        }
    }

    private var isHotspot: Bool { metering.verdict.isMetered }

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
            : L("Stopping app updates on hotspots is off in Hotspot Settings.")
        return metering.override == nil ? what : what + "\n" + L("Marked by you for this network.")
    }

    /// On: a hotspot, by your say. Off: back to detecting it, unless it was
    /// detected as one, which needs your say that it isn't.
    private func setHotspot(_ on: Bool) {
        if on {
            metering.setOverride(true)
        } else if metering.override == true, !metering.detectsHotspot {
            metering.setOverride(nil)
        } else {
            metering.setOverride(false)
        }
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
