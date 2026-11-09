import AppKit
import FirewallPolicy
import SwiftUI

public struct MenuBarPopoverView: View {
    @ObservedObject var model: MonitorViewModel
    /// Observed for its phase only, which changes a few times per test. The
    /// five-a-second readings live on `speedTest.live`, which only the gauges
    /// watch. See `SpeedTestController`.
    @ObservedObject var speedTest: SpeedTestController
    /// Observed for the updates that got through. It publishes rarely — on a
    /// network change, a setting, or a new sighting — and assigns only on
    /// change, so watching it does not re-measure the popover on every sample.
    @ObservedObject var metering: MeteringController
    /// What the ad, tracker and malware lists blocked today (#176).
    @ObservedObject var listBlocks: ListBlockCount
    /// Whether Block Everything is on (#198).
    @ObservedObject var firewall: FirewallRules
    /// Today's companies, for the Companies button and view (#436).
    @ObservedObject var glance: TodayGlance
    @ObservedObject var filter: FilterController
    var onSettings: () -> Void
    var onHistory: () -> Void
    var onConnections: () -> Void
    var onAds: () -> Void
    var onHotspotSettings: () -> Void

    public init(model: MonitorViewModel, onSettings: @escaping () -> Void,
                onHistory: @escaping () -> Void, onConnections: @escaping () -> Void,
                onAds: @escaping () -> Void = {}, onHotspotSettings: @escaping () -> Void = {}) {
        self.model = model
        self.speedTest = model.speedTest
        self.metering = model.metering
        self.listBlocks = model.listBlocks
        self.firewall = model.firewall
        self.glance = model.glance
        self.filter = model.filter
        self.onSettings = onSettings
        self.onHistory = onHistory
        self.onConnections = onConnections
        self.onAds = onAds
        self.onHotspotSettings = onHotspotSettings
    }

    /// Ad blocking paused for a while (#251), or off on this network (#253).
    private var adsPausedText: String? {
        if let until = firewall.listsPausedUntil {
            return L("Ad blocking paused until %@", until.formatted(date: .omitted, time: .shortened))
        }
        guard !firewall.lists.isEmpty, let network = model.adsPausedHere else { return nil }
        return L("Ad blocking off on %@", network)
    }

    /// One line under the total, while metered, when an update came through
    /// anyway: the popover is where someone on a hotspot actually looks, and
    /// Settings is not.
    private var gotThroughSummary: String? {
        let sightings = metering.updatesGotThrough
        guard metering.isSuppressing, let first = sightings.first else { return nil }
        let bytes = ByteFormat.bytes(sightings.reduce(0) { $0 + $1.bytes })
        let total = sightings.contains(where: \.isUpperBound) ? L("up to %@", bytes) : bytes
        if sightings.count == 1 {
            // The app, not its updater's process (#94).
            let what = first.source == .traffic && first.version == nil
                ? L("%@ is updating", first.appName)
                : HotspotSettingsPane.label(for: first)
            return first.bytes > 0 ? "\(what) · \(total)" : what
        }
        return L("%@ updates got through · %@", String(sightings.count), total)
    }

    private var showsCard: Bool {
        speedTest.phase != .idle && speedTest.isPresented && speedTest.style == .card
    }

    /// The compact style: the test above the list rather than instead of it.
    private var showsStrip: Bool {
        speedTest.phase != .idle && speedTest.isPresented && speedTest.style == .compact
    }

    /// The list gives up the strip's height while it is shown, so the popover's
    /// tallest size is the same with a test on screen as without.
    private var listCap: CGFloat {
        showsStrip ? PopoverMetrics.maxListHeight - PopoverMetrics.speedStripHeight - 1
                   : PopoverMetrics.maxListHeight
    }

    /// Height the list wants for the rows currently on screen, capped.
    ///
    /// Computed from the row count rather than measured from the laid-out
    /// content, and that distinction is the whole fix. Measuring means feeding a
    /// height back into the view that produced it, so the first layout pass
    /// necessarily runs at the wrong size — zero — and `NSPopover` places its
    /// window from whatever size the controller reports *at show time*. A
    /// popover shown against a zero-height list is positioned for a window that
    /// does not exist yet, which is the same class of bug as the (0, 0)
    /// `preferredContentSize` described in `AppDelegate.setUpPopover`.
    ///
    /// Deriving the height instead makes the very first layout correct, so the
    /// popover is placed once against a size that is already final.
    private var listHeight: CGFloat {
        PopoverMetrics.listHeight(appRows: appRows.count,
                                  expandedChildRows: expandedChildRows,
                                  systemRowCount: systemRows.count,
                                  systemExpanded: model.systemExpanded,
                                  cap: listCap)
    }

    /// True only when there are genuinely more rows than fit.
    private var listScrolls: Bool {
        PopoverMetrics.scrolls(appRows: appRows.count,
                               expandedChildRows: expandedChildRows,
                               systemRowCount: systemRows.count,
                               systemExpanded: model.systemExpanded,
                               cap: listCap)
    }

    /// What the reorder animation watches: the order itself, nothing else.
    ///
    /// The list is rebuilt from scratch on every sample, so there is no
    /// transaction for `withAnimation` to attach to — the animation has to hang
    /// off a value, exactly as each bar's width does. Comparing ids and not rows
    /// is what keeps it honest: a row whose figure merely ticked up redraws in
    /// place, and only an app actually overtaking another makes the list move.
    private var rowOrderKey: [String] {
        appRows.map(\.id)
    }

    private var expandedChildRows: Int {
        appRows
            .filter { model.expandedApps.contains($0.id) }
            .reduce(0) { $0 + $1.children.count }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            switch model.popoverSection {
            case .today:
                today
            case .companies:
                PopoverCompanies(glance: glance, icon: model.icon(forApp:name:bundlePath:), onOpen: onConnections)
            case .blocked:
                PopoverBlocked(glance: glance, firewall: firewall, filter: filter, pausedText: adsPausedText,
                               icon: model.icon(forApp:name:bundlePath:),
                               onTurnOn: turnOnAdBlocking, onOpen: onAds)
            case .connection:
                connection
            }
        }
        .frame(width: 320)
    }

    // MARK: Data

    /// The period's apps, from Usage History on every network (#449), or the
    /// live list until History has answered for the first time.
    private var appRows: [UsageRow] { glance.report?.apps ?? model.rows }
    private var systemRows: [UsageRow] { glance.report?.systemRows ?? model.systemRows }
    private var systemTotal: Int64 { glance.report?.systemTotal ?? model.systemTotal }

    /// The apps moving bytes right now, which History can't know: their rows
    /// keep the live dot.
    private var activeApps: Set<String> {
        Set((model.rows + model.systemRows).flatMap { [$0] + $0.children }.filter(\.isActive).map(\.id))
    }

    private var dataTotal: String {
        guard let report = glance.report else {
            return glance.period == .today ? ByteFormat.bytes(model.totalBytes) : "–"
        }
        return ByteFormat.bytes(report.bytesIn + report.bytesOut)
    }

    /// Data: the apps or the networks, and the way to Usage History (#436, #449).
    private var today: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverGroupingRow(options: PopoverDataGrouping.allCases, selection: $glance.dataGrouping,
                               label: { $0.label }, count: dataCount)
            if glance.dataGrouping == .networks {
                networks
            } else if appRows.isEmpty && systemRows.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            PopoverOpenRow(title: L("Open Usage History"), shortcut: "⌘Y", action: onHistory)
        }
    }

    /// Connection: the network, the hotspot switch and the speed test, which
    /// tests this connection and so runs here (#436). A test shown as a card
    /// takes the view's place while it runs; the compact one sits above it.
    @ViewBuilder
    private var connection: some View {
        if showsCard {
            SpeedTestCard(speedTest: speedTest)
        } else {
            VStack(spacing: 0) {
                if showsStrip {
                    SpeedTestStrip(speedTest: speedTest)
                    Divider()
                }
                PopoverConnection(metering: metering, speedTest: speedTest, status: model.connection,
                                  onHotspotSettings: onHotspotSettings)
            }
        }
    }

    /// As Ads and Trackers' Turn On: every built-in list, and the filter.
    private func turnOnAdBlocking() {
        firewall.lists = Set(BlocklistTopic.allCases)
        switch filter.state {
        case .off, .failed: filter.turnOn()
        default: break
        }
    }

    private var dataCount: String {
        if glance.dataGrouping == .networks {
            let count = glance.report?.networks.count ?? 0
            return count == 1 ? L("1 network") : L("%@ networks", String(count))
        }
        let count = appRows.count
        return count == 1 ? L("1 app") : L("%@ apps", String(count))
    }

    /// What each network used in the period, biggest first (#449): in place
    /// of the counter that started over on joining a network.
    @ViewBuilder
    private var networks: some View {
        let rows = glance.report?.networks ?? []
        if rows.isEmpty {
            emptyState
        } else {
            let total = max(rows.reduce(0) { $0 + $1.bytes }, 1)
            PopoverList(rows: rows.count) {
                ForEach(rows) { network in
                    PopoverRow(title: model.store.displayLabel(for: network.id, defaultLabel: network.defaultLabel),
                               value: ByteFormat.bytes(network.bytes),
                               icon: .symbol(Self.symbol(network), network.isMetered ? PopoverPalette.hotspot
                                                                                    : PopoverPalette.data),
                               fraction: Double(network.bytes) / Double(total),
                               barColor: network.isMetered ? PopoverPalette.hotspot : PopoverPalette.data)
                }
            }
        }
    }

    /// Today's count is the filter's own, which moves as it blocks; a week's
    /// or a month's is read from History.
    private var blockedTotal: String {
        if firewall.lists.isEmpty { return L("Off") }
        if glance.period == .today { return max(Int64(listBlocks.today), glance.ads.total).formatted() }
        return glance.hasLoaded ? glance.ads.total.formatted() : "–"
    }

    private static func symbol(_ network: HistoryReport.NetworkTotal) -> String {
        if network.isMetered { return "personalhotspot" }
        switch network.kind {
        case .ethernet: return "cable.connector"
        case .offline:  return "wifi.slash"
        default:        return "wifi"
        }
    }

    // MARK: Header

    /// The period, with Settings' gear beside it; the four buttons; then
    /// anything that needs saying (#436, #449). One combined total: live
    /// download/upload rates are already in the menu bar.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                PopoverSwitch(name: L("Period"), options: PopoverPeriod.allCases, selection: $glance.period,
                              label: { $0.label })
                    .help(L("What Data, Connections and Ads blocked count: today, this week or this month so far, on every network"))
                Spacer(minLength: 0)
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Settings (⌘,)"))
                .accessibilityLabel(L("Settings"))
            }
            .padding(.leading, PopoverMetrics.edge)
            .padding(.trailing, 6)
            .padding(.top, 8)
            .padding(.bottom, 4)
            PopoverButtons(selection: Binding(get: { model.popoverSection },
                                              set: { section in
                                                  model.popoverSection = section
                                                  if section == .companies || section == .blocked { glance.refresh() }
                                              }),
                           period: glance.period,
                           data: dataTotal,
                           connections: glance.hasLoaded ? glance.connections.formatted() : "–",
                           blocked: blockedTotal,
                           blockedIsOn: !firewall.lists.isEmpty,
                           connection: PopoverConnection.word(model.connection, metering: metering),
                           isHotspot: metering.verdict.isMetered)
                .padding(.horizontal, PopoverMetrics.edge)
            VStack(alignment: .leading, spacing: 2) {
                    if let standby = metering.standbyHotspot {
                        StandbyHotspotLine(message: standby.message,
                                           explanation: standby.explanation(inUse: model.connection))
                    }
                    if let summary = gotThroughSummary {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle.fill")
                            Text(summary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help(L("Downloaded over this connection anyway. Settings › Hotspot lists what NetworkMonitor can't stop."))
                    }
                    if firewall.blocksEverything {
                        HStack(spacing: 6) {
                            Image(systemName: "hand.raised.fill")
                            Text(L("Everything is blocked"))
                            Button(L("Turn Off")) { model.setBlocksEverything(false) }
                                .buttonStyle(.link)
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.red)
                        .help(L("Block Everything is on: every app's new connections stop, apart from looking up names, the clock and your own network"))
                    }
                    if let paused = adsPausedText {
                        Button(action: onAds) {
                            HStack(spacing: 4) {
                                Image(systemName: "shield.slash")
                                Text(paused).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help(L("Open Ads and Trackers to resume"))
                    }
                    if let failure = model.perAppFailure {
                        // Grey, not orange: the total above is still right. Only the
                        // list has stopped, and saying so beats a list gone quiet.
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle")
                            Text(L("Per-app figures paused"))
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help(L("macOS's nettop isn't reporting per-app figures (%@). The total is still counted, and NetworkMonitor keeps trying.", failure))
                    }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    // MARK: List

    /// `LazyVStack` is safe again now that the height no longer comes from
    /// measuring this content: laziness cannot influence a number derived from
    /// the row count.
    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(appRows) { row in
                    appRow(row)
                }
                if !systemRows.isEmpty { systemSection }
            }
            .padding(.vertical, PopoverMetrics.listVerticalPadding / 2)
            // Applied here rather than to the ScrollView so it animates the rows
            // sliding past each other and never the frame below, which sets the
            // popover's size — animating that would re-anchor the window on every
            // overtake. See `PopoverMetrics.maxListHeight`.
            .animation(.easeInOut(duration: 0.3), value: rowOrderKey)
        }
        .frame(height: listHeight)
        // Stated, not inferred. Left to AppKit, a list that exactly fits its
        // frame is scrollable-or-not depending on rounding, and the overlay bar
        // flickered on every republish.
        .scrollIndicators(listScrolls ? .automatic : .never)
    }

    /// What every bar is measured against: everything the rows account for.
    ///
    /// The sum of the top-level rows rather than the header figure, so the bars
    /// tile the width exactly. The two differ by the traffic the kernel counted
    /// but could not attribute to any process, and a set of bars that visibly
    /// fails to fill the row reads as a bug rather than as that distinction.
    private var barTotal: Int64 {
        max(appRows.reduce(0) { $0 + $1.total } + systemTotal, 1)
    }

    private func fraction(of bytes: Int64) -> Double {
        Double(bytes) / Double(barTotal)
    }

    /// One app, plus its breakdown when opened.
    ///
    /// Most apps have no children and are an ordinary row: the disclosure
    /// affordance only exists where there is something behind it, so the list
    /// does not advertise a breakdown that would turn out to be empty.
    @ViewBuilder
    private func appRow(_ row: UsageRow) -> some View {
        let isExpanded = model.expandedApps.contains(row.id)
        let active = activeApps
        PopoverRow(row: row,
                   icon: model.icon(for: row),
                   fraction: fraction(of: row.total),
                   isActive: active.contains(row.id) || row.children.contains { active.contains($0.id) },
                   isExpanded: isExpanded,
                   onToggle: row.hasChildren
                       ? { withAnimation(.easeInOut(duration: 0.15)) {
                             model.toggleExpanded(row.id)
                         } }
                       : nil)
        if isExpanded {
            ForEach(row.children) { child in
                PopoverRow(row: child, icon: model.icon(for: child),
                           fraction: fraction(of: child.total), isActive: active.contains(child.id),
                           indented: true)
            }
        }
    }

    /// Daemons are collapsed by default. mDNSResponder alone was measured at
    /// 263 MB against a top real app of 6 MB — left inline it would bury
    /// everything the user cares about.
    ///
    /// Rendered through `PopoverRow` like any other row, so the group carries a
    /// bar for its share of the total and puts its chevron on the right where
    /// the app rows put theirs. It used to be the one row shaped differently,
    /// which made it read as a different kind of control than it is.
    private var systemSection: some View {
        // Own bytes stay zero and the daemons hang off it as children, so
        // `total` is the group's total without stating it twice.
        let summary = UsageRow(id: "\u{1}system",
                               displayName: L("System (%@)", String(systemRows.count)),
                               bytesIn: 0, bytesOut: 0,
                               bundlePath: nil, isSystem: true,
                               isActive: false,
                               children: systemRows)
        let active = activeApps
        return VStack(alignment: .leading, spacing: 0) {
            PopoverRow(row: summary,
                       icon: model.icon(for: summary),
                       fraction: fraction(of: systemTotal),
                       isActive: systemRows.contains { active.contains($0.id) },
                       isMuted: true,
                       isExpanded: model.systemExpanded,
                       onToggle: {
                           withAnimation(.easeInOut(duration: 0.15)) {
                               model.systemExpanded.toggle()
                           }
                       })
            if model.systemExpanded {
                ForEach(systemRows) { row in
                    PopoverRow(row: row, icon: model.icon(for: row),
                               fraction: fraction(of: row.total), isActive: active.contains(row.id),
                               indented: true)
                }
            }
        }
    }

    /// Sized to its own text now that the list is sized to its content: a short
    /// message in a 320 pt window was mostly empty space.
    private var emptyState: some View {
        VStack(spacing: 4) {
            Text(L("No network activity yet"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text(L("Counted while NetworkMonitor is running, on every network"))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

/// A hotspot is connected but the Mac isn't using it (#355). Warned about here,
/// where someone who just joined one looks, with the why and how behind an ⓘ.
private struct StandbyHotspotLine: View {
    let message: String
    let explanation: String
    /// Not `@State`; see `SettingsPaneState`. Over a row in Settings the ⓘ
    /// appears on hover, but this line has no other way to say there's more.
    @StateObject private var info: RowInfoState = {
        let state = RowInfoState()
        state.isHovering = true
        return state
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
            // One line, as the lines around it are: the wording is kept short
            // enough to fit, and a long phone name gives way in the middle.
            Text(message)
                .lineLimit(1)
                .truncationMode(.middle)
            RowInfoButton(help: explanation, state: info) { Text(explanation) }
        }
        .font(.system(size: 10))
        .foregroundStyle(.orange)
        .accessibilityElement(children: .combine)
        .accessibilityHint(explanation)
    }
}

/// Fixed row geometry of the popover list, so its height can be derived from
/// the row count instead of measured from the laid-out result.
///
/// The constants are calibrated against what SwiftUI actually lays out — see
/// `runPopoverMetricsTests`, which pins every one of them. They are only correct
/// as long as the row views keep their current padding, so a change to
/// `PopoverRow`'s insets is a change here too, and the tests say so.
public enum PopoverMetrics {

    /// Every row in the list, whatever its level.
    ///
    /// One height for all of them: an app, an adopted child and a system daemon
    /// are the same shape, differing only in indent and icon size, and the two
    /// icon sizes were chosen so the name-over-bar stack is what sets the
    /// height in both cases. That keeps the arithmetic below to one term.
    public static let rowHeight: CGFloat = 42
    /// 4 pt above the first row and below the last.
    public static let listVerticalPadding: CGFloat = 8

    /// Icon beside a top-level row, and beside an indented one.
    ///
    /// Each is sized to contain the name-over-bar stack that sits next to it, so
    /// the text never runs taller than the icon it belongs to — see
    /// `detailStackHeight(indented:)` and the test that pins the relationship.
    public static let iconSize: CGFloat = 32
    public static let childIconSize: CGFloat = 28

    /// Height every row's content occupies, whatever its level.
    ///
    /// Stated rather than derived from the tallest thing in the row. Without it
    /// the row height would follow the icon, so the smaller child icon would make
    /// child rows shorter than app rows and `rowHeight` could no longer be a
    /// single number.
    public static let rowContentHeight: CGFloat = 32

    /// Gap between an app's name and its bar.
    ///
    /// Tight on purpose: the two lines are one unit describing one app, and the
    /// pair has to fit inside the icon's height.
    public static let detailSpacing: CGFloat = 2

    /// Type sizes for the name and the byte figure, at each level.
    public static let nameFontSize: CGFloat = 12
    public static let totalFontSize: CGFloat = 11
    public static let childNameFontSize: CGFloat = 11
    public static let childTotalFontSize: CGFloat = 10

    /// Width of a bar at 100%.
    ///
    /// One value for every row, indented or not, so a child's bar is directly
    /// comparable with its parent's — and small enough that the byte figure
    /// following it still fits on the most indented row.
    public static let maxBarWidth: CGFloat = 150
    /// A row with a real but tiny share still gets a visible mark, rather than
    /// rounding away to nothing and reading as zero.
    public static let minBarWidth: CGFloat = 3
    public static let barHeight: CGFloat = 5

    /// Height of the name-over-bar stack, from the fonts it is actually drawn in.
    ///
    /// Derived rather than guessed, so shrinking the child type or tightening the
    /// spacing cannot silently push the text past its icon.
    public static func detailStackHeight(indented: Bool) -> CGFloat {
        let name = lineHeight(indented ? childNameFontSize : nameFontSize)
        let figure = lineHeight(indented ? childTotalFontSize : totalFontSize)
        return name + detailSpacing + max(figure, barHeight)
    }

    /// The icon a row of this level sits beside.
    public static func iconSize(indented: Bool) -> CGFloat {
        indented ? childIconSize : iconSize
    }

    static func lineHeight(_ size: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size)
        return font.ascender - font.descender + font.leading
    }
    /// Indent applied to a child row.
    public static let childIndent: CGFloat = 18
    /// Leading inset shared by every row.
    public static let rowHorizontalPadding: CGFloat = 12
    /// Vertical inset above and below a row's content.
    public static let rowVerticalPadding: CGFloat = 5
    /// Gap between the icon and the name-over-bar stack.
    public static let iconSpacing: CGFloat = 10

    /// Width of the name-over-bar stack, fixed so the bars all start at the same
    /// x and a long app name truncates instead of shoving the row about.
    public static let detailWidth: CGFloat = 220

    /// The same, less what an indented row gives to its indent and keeps
    /// back of its smaller icon, so an opened row is no wider than the
    /// popover: at 220 it was 340 pt wide in a 320 pt popover (#436).
    public static func detailWidth(indented: Bool) -> CGFloat {
        indented ? detailWidth - childIndent - (iconSize - childIconSize) - 2 : detailWidth
    }

    /// Tallest the list may grow before it scrolls instead.
    ///
    /// A ceiling rather than a fixed height. `NSPopover` re-anchors itself
    /// whenever its content size changes, so every resize is a chance to be
    /// placed against a menu bar item that has since shifted — capping means a
    /// list long enough to reach it, which is where a day's traffic ends up,
    /// stops resizing altogether.
    ///
    /// Sized so the popover stands about as tall as it did before its header
    /// gained the four buttons, the Open Usage History row and the Settings
    /// footer (#436). That holds six rows whole and part of a seventh, which
    /// is deliberate: a row cut off at the bottom edge is what says there is
    /// more below without spending a whole row saying it.
    public static let maxListHeight: CGFloat = 290

    /// Kept between the content and the frame that holds it, so a list that fits
    /// is never *exactly* the height of its own content.
    ///
    /// Sizing the frame to the content precisely put the scroll view on a knife
    /// edge: measured at content 201.0 in a frame of 201.0, where whether the
    /// thing scrolls comes down to sub-pixel rounding. The model republishes
    /// twice a second, so that coin was flipped twice a second and the overlay
    /// scrollbar strobed in and out. One point of slack settles it, and is not
    /// visible.
    public static let fitSlack: CGFloat = 1

    /// The speed test card, which stands in for the list while it is shown.
    public static let speedCardHeight: CGFloat = 344

    /// The compact speed test, which sits above the list, in every phase.
    public static let speedStripHeight: CGFloat = 76

    /// Height the rows actually occupy, uncapped. Calibrated against SwiftUI's
    /// layout — see `runPopoverMetricsTests`.
    public static func contentHeight(appRows: Int,
                                     expandedChildRows: Int,
                                     systemRowCount: Int,
                                     systemExpanded: Bool) -> CGFloat {
        var rows = appRows + expandedChildRows
        if systemRowCount > 0 {
            rows += 1                                            // the summary
            if systemExpanded { rows += systemRowCount }
        }
        return listVerticalPadding + rowHeight * CGFloat(rows)
    }

    /// Height to give the list's frame: its content plus slack, up to the cap.
    /// `cap` is `maxListHeight` unless something else shares the popover with
    /// the list, as the compact speed test does.
    public static func listHeight(appRows: Int,
                                 expandedChildRows: Int,
                                 systemRowCount: Int,
                                 systemExpanded: Bool,
                                 cap: CGFloat = maxListHeight) -> CGFloat {
        let content = contentHeight(appRows: appRows, expandedChildRows: expandedChildRows,
                                    systemRowCount: systemRowCount,
                                    systemExpanded: systemExpanded)
        return min(content + fitSlack, cap)
    }

    /// Whether the list genuinely has more rows than fit.
    ///
    /// Drives the scrollbar's visibility directly, rather than leaving AppKit to
    /// infer it from a comparison that may be a rounding error either way.
    public static func scrolls(appRows: Int,
                               expandedChildRows: Int,
                               systemRowCount: Int,
                               systemExpanded: Bool,
                               cap: CGFloat = maxListHeight) -> Bool {
        contentHeight(appRows: appRows, expandedChildRows: expandedChildRows,
                      systemRowCount: systemRowCount, systemExpanded: systemExpanded)
            > listHeight(appRows: appRows, expandedChildRows: expandedChildRows,
                         systemRowCount: systemRowCount, systemExpanded: systemExpanded,
                         cap: cap)
    }
}

/// What a row of the popover's lists shows beside its name: an app's icon, or
/// a symbol in a tinted square for a company or a site.
enum PopoverRowIcon {
    case image(NSImage)
    case symbol(String, Color)
    /// A country's flag (#449).
    case text(String)
}

/// One row of the popover's lists, Today's apps, Companies and Ads blocked
/// alike (#436): an icon, the name over a bar, the figure, and a chevron
/// where there's something to open, so all three read and open the same way.
struct PopoverRow: View {
    let title: String
    let value: String
    var isActive = false
    let icon: PopoverRowIcon
    /// This row's share of everything the list accounts for, 0...1.
    let fraction: Double
    var barColor: Color = .accentColor
    var indented = false
    /// The System group, which is a heading over other rows rather than an app.
    var isMuted = false
    var isExpanded = false
    /// Non-nil only when the row has a breakdown to show.
    var onToggle: (() -> Void)?

    init(title: String, value: String, isActive: Bool = false, icon: PopoverRowIcon, fraction: Double,
         barColor: Color = .accentColor, indented: Bool = false, isMuted: Bool = false, isExpanded: Bool = false,
         onToggle: (() -> Void)? = nil) {
        self.title = title
        self.value = value
        self.isActive = isActive
        self.icon = icon
        self.fraction = fraction
        self.barColor = barColor
        self.indented = indented
        self.isMuted = isMuted
        self.isExpanded = isExpanded
        self.onToggle = onToggle
    }

    /// An app's row in Today.
    /// `isActive` overrides the row's own, for a row read from History, which
    /// can't know what's moving now (#449).
    init(row: UsageRow, icon: NSImage, fraction: Double, isActive: Bool? = nil, indented: Bool = false,
         isMuted: Bool = false, isExpanded: Bool = false, onToggle: (() -> Void)? = nil) {
        self.init(title: row.displayName, value: ByteFormat.bytes(row.total), isActive: isActive ?? row.isActive,
                  icon: .image(icon), fraction: fraction, indented: indented, isMuted: isMuted,
                  isExpanded: isExpanded, onToggle: onToggle)
    }

    /// Not `@State`, which needs Xcode from the macOS 27 SDK on — see
    /// `SettingsPaneState`.
    @StateObject private var hover = HoverState()

    /// Width held for the disclosure chevron on *every* row, expandable or not,
    /// so a chevron fading in never nudges the row's contents.
    private static let chevronWidth: CGFloat = 10

    var body: some View {
        if let onToggle {
            Button(action: onToggle) { content }
                .buttonStyle(.plain)
                .onHover { hover.isHovering = $0 }
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: PopoverMetrics.iconSpacing) {
            if indented { Spacer().frame(width: PopoverMetrics.childIndent) }
            iconView
                // The name is beside it.
                .accessibilityHidden(true)

            // Name over bar, vertically centred against the icon.
            VStack(alignment: .leading, spacing: PopoverMetrics.detailSpacing) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: indented ? PopoverMetrics.childNameFontSize
                                                     : PopoverMetrics.nameFontSize))
                        // Dimmer than a top-level app: a child is a part of the
                        // row above it, not a peer of the rows around it.
                        .foregroundStyle(indented || isMuted
                                         ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .lineLimit(1).truncationMode(.tail)

                    // Live indicator: moved bytes within the last 2 seconds.
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .opacity(isActive ? 1 : 0)
                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    bar
                    Text(value)
                        .font(.system(size: indented ? PopoverMetrics.childTotalFontSize
                                                     : PopoverMetrics.totalFontSize,
                                      weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(isMuted ? AnyShapeStyle(.secondary)
                                                 : AnyShapeStyle(.primary))
                    Spacer(minLength: 0)
                }
            }
            // Held to the stack's own height and centred, so the name and the bar
            // stay vertically centred on the icon beside them.
            .frame(width: PopoverMetrics.detailWidth(indented: indented),
                   height: PopoverMetrics.detailStackHeight(indented: indented),
                   alignment: .leading)

            Spacer(minLength: 0)

            // Faint at rest, full strength when pointed at or open. Only rows
            // with something behind them get one, so the chevron doubles as the
            // answer to "which of these can I open?" — invisible until hover,
            // that question could only be answered by sweeping the whole list.
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .opacity(chevronOpacity)
                .frame(width: Self.chevronWidth)
        }
        .frame(height: PopoverMetrics.rowContentHeight)
        .padding(.horizontal, PopoverMetrics.rowHorizontalPadding)
        .padding(.vertical, PopoverMetrics.rowVerticalPadding)
        // Drawn as a background rather than inside the HStack so it spans the
        // row's vertical padding too, making one continuous line down a run of
        // children instead of a dashed stack of segments.
        .background(alignment: .leading) { rail }
        // The whole row is the hit target, not just the chevron.
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var iconView: some View {
        let size = PopoverMetrics.iconSize(indented: indented)
        switch icon {
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .frame(width: size, height: size)
        case .symbol(let name, let color):
            Image(systemName: name)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(color)
                .frame(width: size - 4, height: size - 4)
                .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.15)))
                .frame(width: size, height: size)
        case .text(let text):
            Text(text)
                .font(.system(size: size * 0.6))
                .frame(width: size, height: size)
        }
    }

    /// This row's share of the total, drawn to scale.
    ///
    /// Animated on width so a figure ticking up slides the bar out rather than
    /// snapping it. The rows are rebuilt from scratch on every sample, so the
    /// animation is attached to the value and not to the transaction that
    /// produced it — `withAnimation` at the call site would not survive a row
    /// being replaced.
    private var bar: some View {
        Capsule()
            .fill(barColor.opacity(isMuted ? 0.5 : 1))
            .frame(width: barWidth, height: PopoverMetrics.barHeight)
            .animation(.easeOut(duration: 0.45), value: barWidth)
    }

    private var barWidth: CGFloat {
        guard fraction.isFinite else { return PopoverMetrics.minBarWidth }
        let share = min(max(fraction, 0), 1)
        return max(PopoverMetrics.minBarWidth, PopoverMetrics.maxBarWidth * share)
    }

    /// Absent on rows with no breakdown, dim at rest, solid on hover or when open.
    private var chevronOpacity: Double {
        guard onToggle != nil else { return 0 }
        return (hover.isHovering || isExpanded) ? 1 : 0.35
    }

    /// Vertical line tying a child to the app it belongs to.
    ///
    /// Indentation alone carried the whole relationship, and 16 pt of it is easy
    /// to miss in a list where every other row is flush — the breakdown looked
    /// like more top-level apps that happened to sit slightly to the right.
    @ViewBuilder
    private var rail: some View {
        if indented {
            Rectangle()
                .fill(.secondary.opacity(0.25))
                .frame(width: 1)
                // Centred under the parent's icon, so the line appears to
                // descend from the app it belongs to.
                .padding(.leading, PopoverMetrics.rowHorizontalPadding
                         + PopoverMetrics.iconSize / 2)
        }
    }
}

/// Whether the pointer is over one row. A class so that `PopoverRow` can own it
/// with `@StateObject`; see its `hover` property.
private final class HoverState: ObservableObject {
    @Published var isHovering = false
}
