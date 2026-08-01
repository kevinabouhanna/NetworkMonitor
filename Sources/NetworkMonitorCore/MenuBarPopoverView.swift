import AppKit
import SwiftUI

public struct MenuBarPopoverView: View {
    @ObservedObject var model: MonitorViewModel
    var onSettings: () -> Void

    public init(model: MonitorViewModel, onSettings: @escaping () -> Void) {
        self.model = model
        self.onSettings = onSettings
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
        PopoverMetrics.listHeight(appRows: model.rows.count,
                                  expandedChildRows: expandedChildRows,
                                  systemRowCount: model.systemRows.count,
                                  systemExpanded: model.systemExpanded)
    }

    /// True only when there are genuinely more rows than fit.
    private var listScrolls: Bool {
        PopoverMetrics.scrolls(appRows: model.rows.count,
                               expandedChildRows: expandedChildRows,
                               systemRowCount: model.systemRows.count,
                               systemExpanded: model.systemExpanded)
    }

    private var expandedChildRows: Int {
        model.rows
            .filter { model.expandedApps.contains($0.id) }
            .reduce(0) { $0 + $1.children.count }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.rows.isEmpty && model.systemRows.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(width: 320)
    }

    // MARK: Header

    /// One combined total. The per-direction split lived here and in every row,
    /// but it was never asked for and doubled the numbers on screen; live
    /// download/upload rates are already in the menu bar.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Total")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                // The badge sits on the figure's row, not the header's: it
                // qualifies the number, and centring it on "Total" left it
                // floating between the two lines.
                HStack(spacing: 8) {
                    Text(ByteFormat.bytes(model.totalBytes))
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .monospacedDigit()
                    if model.isExpensiveNetwork {
                        // Surfaced because metered networks are the case where
                        // this connection's total actually matters.
                        Text("METERED")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            Button(action: onSettings) {
                Image(systemName: "gearshape.fill").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: List

    /// `LazyVStack` is safe again now that the height no longer comes from
    /// measuring this content: laziness cannot influence a number derived from
    /// the row count.
    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.rows) { row in
                    appRow(row)
                }
                if !model.systemRows.isEmpty { systemSection }
            }
            .padding(.vertical, PopoverMetrics.listVerticalPadding / 2)
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
        max(model.rows.reduce(0) { $0 + $1.total } + model.systemTotal, 1)
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
        AppRowView(row: row,
                   icon: model.icon(for: row),
                   fraction: fraction(of: row.total),
                   isExpanded: isExpanded,
                   onToggle: row.hasChildren
                       ? { withAnimation(.easeInOut(duration: 0.15)) {
                             model.toggleExpanded(row.id)
                         } }
                       : nil)
        if isExpanded {
            ForEach(row.children) { child in
                AppRowView(row: child, icon: model.icon(for: child),
                           fraction: fraction(of: child.total), indented: true)
            }
        }
    }

    /// Daemons are collapsed by default. mDNSResponder alone was measured at
    /// 263 MB against a top real app of 6 MB — left inline it would bury
    /// everything the user cares about.
    ///
    /// Rendered through `AppRowView` like any other row, so the group carries a
    /// bar for its share of the total and puts its chevron on the right where
    /// the app rows put theirs. It used to be the one row shaped differently,
    /// which made it read as a different kind of control than it is.
    private var systemSection: some View {
        // Own bytes stay zero and the daemons hang off it as children, so
        // `total` is the group's total without stating it twice.
        let summary = UsageRow(id: "\u{1}system",
                               displayName: "System (\(model.systemRows.count))",
                               bytesIn: 0, bytesOut: 0,
                               bundlePath: nil, isSystem: true,
                               isActive: model.systemRows.contains(where: \.isActive),
                               children: model.systemRows)
        return VStack(alignment: .leading, spacing: 0) {
            AppRowView(row: summary,
                       icon: model.icon(for: summary),
                       fraction: fraction(of: model.systemTotal),
                       isMuted: true,
                       isExpanded: model.systemExpanded,
                       onToggle: {
                           withAnimation(.easeInOut(duration: 0.15)) {
                               model.systemExpanded.toggle()
                           }
                       })
            if model.systemExpanded {
                ForEach(model.systemRows) { row in
                    AppRowView(row: row, icon: model.icon(for: row),
                               fraction: fraction(of: row.total), indented: true)
                }
            }
        }
    }

    /// Sized to its own text now that the list is sized to its content: a short
    /// message in a 320 pt window was mostly empty space.
    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("No network activity yet")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text("Counting since you joined this network")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

/// Fixed row geometry of the popover list, so its height can be derived from
/// the row count instead of measured from the laid-out result.
///
/// The constants are calibrated against what SwiftUI actually lays out — see
/// `runPopoverMetricsTests`, which pins every one of them. They are only correct
/// as long as the row views keep their current padding, so a change to
/// `AppRowView`'s insets is a change here too, and the tests say so.
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

    /// Tallest the list may grow before it scrolls instead.
    ///
    /// A ceiling rather than a fixed height. `NSPopover` re-anchors itself
    /// whenever its content size changes, so every resize is a chance to be
    /// placed against a menu bar item that has since shifted — capping means a
    /// list long enough to reach it, which is where a day's traffic ends up,
    /// stops resizing altogether.
    ///
    /// Sized so the popover stands 428.5 pt overall — the list plus 56.5 of
    /// header and divider. That holds eight rows whole and part of a ninth,
    /// which is deliberate: a row cut off at the bottom edge is what says there
    /// is more below without spending a whole row saying it.
    public static let maxListHeight: CGFloat = 372

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
    public static func listHeight(appRows: Int,
                                 expandedChildRows: Int,
                                 systemRowCount: Int,
                                 systemExpanded: Bool) -> CGFloat {
        let content = contentHeight(appRows: appRows, expandedChildRows: expandedChildRows,
                                    systemRowCount: systemRowCount,
                                    systemExpanded: systemExpanded)
        return min(content + fitSlack, maxListHeight)
    }

    /// Whether the list genuinely has more rows than fit.
    ///
    /// Drives the scrollbar's visibility directly, rather than leaving AppKit to
    /// infer it from a comparison that may be a rounding error either way.
    public static func scrolls(appRows: Int,
                               expandedChildRows: Int,
                               systemRowCount: Int,
                               systemExpanded: Bool) -> Bool {
        contentHeight(appRows: appRows, expandedChildRows: expandedChildRows,
                      systemRowCount: systemRowCount, systemExpanded: systemExpanded)
            > listHeight(appRows: appRows, expandedChildRows: expandedChildRows,
                         systemRowCount: systemRowCount, systemExpanded: systemExpanded)
    }
}

private struct AppRowView: View {
    let row: UsageRow
    let icon: NSImage
    /// This row's share of everything the list accounts for, 0...1.
    let fraction: Double
    var indented = false
    /// The System group, which is a heading over other rows rather than an app.
    var isMuted = false
    var isExpanded = false
    /// Non-nil only when the row has a breakdown to show.
    var onToggle: (() -> Void)?

    @State private var isHovering = false

    /// Width held for the disclosure chevron on *every* row, expandable or not,
    /// so a chevron fading in never nudges the row's contents.
    private static let chevronWidth: CGFloat = 10

    var body: some View {
        if let onToggle {
            Button(action: onToggle) { content }
                .buttonStyle(.plain)
                .onHover { isHovering = $0 }
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: PopoverMetrics.iconSpacing) {
            if indented { Spacer().frame(width: PopoverMetrics.childIndent) }
            Image(nsImage: icon)
                .resizable()
                .frame(width: PopoverMetrics.iconSize(indented: indented),
                       height: PopoverMetrics.iconSize(indented: indented))

            // Name over bar, vertically centred against the icon.
            VStack(alignment: .leading, spacing: PopoverMetrics.detailSpacing) {
                HStack(spacing: 6) {
                    Text(row.displayName)
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
                        .opacity(row.isActive ? 1 : 0)
                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    bar
                    Text(ByteFormat.bytes(row.total))
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
            .frame(width: PopoverMetrics.detailWidth,
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

    /// This row's share of the total, drawn to scale.
    ///
    /// Animated on width so a figure ticking up slides the bar out rather than
    /// snapping it. The rows are rebuilt from scratch on every sample, so the
    /// animation is attached to the value and not to the transaction that
    /// produced it — `withAnimation` at the call site would not survive a row
    /// being replaced.
    private var bar: some View {
        Capsule()
            .fill(Color.accentColor.opacity(isMuted ? 0.5 : 1))
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
        return (isHovering || isExpanded) ? 1 : 0.35
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
