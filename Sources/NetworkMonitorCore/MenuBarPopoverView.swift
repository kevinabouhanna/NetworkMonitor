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
                   isExpanded: isExpanded,
                   onToggle: row.hasChildren
                       ? { withAnimation(.easeInOut(duration: 0.15)) {
                             model.toggleExpanded(row.id)
                         } }
                       : nil)
        if isExpanded {
            ForEach(row.children) { child in
                AppRowView(row: child, icon: model.icon(for: child), indented: true)
            }
        }
    }

    /// Daemons are collapsed by default. mDNSResponder alone was measured at
    /// 263 MB against a top real app of 6 MB — left inline it would bury
    /// everything the user cares about.
    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { model.systemExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.systemExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Image(systemName: "gearshape.2.fill")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("System (\(model.systemRows.count))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(ByteFormat.bytes(model.systemTotal))
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(.secondary)
                    // Matches the app rows' reserved chevron slot, so every
                    // total in the list shares one right edge.
                    Spacer().frame(width: 10)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if model.systemExpanded {
                ForEach(model.systemRows) { row in
                    AppRowView(row: row, icon: model.icon(for: row), indented: true)
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

    /// An app row, a child row and a system daemon row: a 16 pt icon between
    /// 4 pt insets.
    public static let rowHeight: CGFloat = 24
    /// The "System (n)" summary, which uses 5 pt insets rather than 4.
    public static let systemSummaryHeight: CGFloat = 25
    /// 4 pt above the first row and below the last.
    public static let listVerticalPadding: CGFloat = 8

    /// Tallest the list may grow before it scrolls instead.
    ///
    /// A ceiling rather than a fixed height. `NSPopover` re-anchors itself
    /// whenever its content size changes, so every resize is a chance to be
    /// placed against a menu bar item that has since shifted — capping means a
    /// list long enough to reach it, which is where a day's traffic ends up,
    /// stops resizing altogether.
    public static let maxListHeight: CGFloat = 320

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
        var height = listVerticalPadding
        height += rowHeight * CGFloat(appRows + expandedChildRows)
        if systemRowCount > 0 {
            height += systemSummaryHeight
            if systemExpanded { height += rowHeight * CGFloat(systemRowCount) }
        }
        return height
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
    var indented = false
    var isExpanded = false
    /// Non-nil only when the row has a breakdown to show.
    var onToggle: (() -> Void)?

    @State private var isHovering = false

    /// Width held for the disclosure chevron on *every* row, expandable or not.
    ///
    /// Reserved rather than laid out on demand so the byte totals stay in one
    /// column: sizing this slot to its contents would shift the numbers left on
    /// the rows without children, and shift them again as the chevron faded in.
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
        HStack(spacing: 8) {
            if indented { Spacer().frame(width: 16) }
            Image(nsImage: icon)
                .resizable().frame(width: 16, height: 16)

            Text(row.displayName)
                .font(.system(size: 12))
                // Dimmer than a top-level app: a child is a part of the row
                // above it, not a peer of the rows around it.
                .foregroundStyle(indented ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1).truncationMode(.tail)

            // Live indicator: this app moved bytes within the last 2 seconds.
            Circle()
                .fill(Color.accentColor)
                .frame(width: 5, height: 5)
                .opacity(row.isActive ? 1 : 0)

            Spacer(minLength: 8)

            Text(ByteFormat.bytes(row.total))
                .font(.system(size: 11, weight: .medium)).monospacedDigit()

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
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        // Drawn as a background rather than inside the HStack so it spans the
        // row's vertical padding too, making one continuous line down a run of
        // children instead of a dashed stack of 16 pt segments.
        .background(alignment: .leading) { rail }
        // The whole row is the hit target, not just the chevron.
        .contentShape(Rectangle())
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
                .padding(.leading, 20)
        }
    }
}
