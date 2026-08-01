import SwiftUI

public struct MenuBarPopoverView: View {
    @ObservedObject var model: MonitorViewModel
    var onSettings: () -> Void

    public init(model: MonitorViewModel, onSettings: @escaping () -> Void) {
        self.model = model
        self.onSettings = onSettings
    }

    /// Height of the area below the header, held constant on purpose.
    ///
    /// `NSPopover` re-positions itself against the status item every time its
    /// content size changes, and expanding the System group animates that size a
    /// dozen times in 150 ms — a dozen chances to be re-anchored against a menu
    /// bar item that has just shifted (a crowded or notched menu bar moves items
    /// whenever another app adds one). A constant height means the popover is
    /// placed once, when it opens: rows arriving, the System group expanding and
    /// a network switch zeroing the list all scroll inside instead of resizing
    /// the window.
    static let contentHeight: CGFloat = 320

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

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.rows) { row in
                    AppRowView(row: row, icon: model.icon(for: row))
                }
                if !model.systemRows.isEmpty { systemSection }
            }
            .padding(.vertical, 4)
        }
        .frame(height: Self.contentHeight)
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

    /// Occupies the same height as the list, so the popover is not resized when
    /// the first rows arrive — the case that used to leave the list clipped to the
    /// empty state's height.
    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("No network activity yet")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text("Counting since you joined this network")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.contentHeight)
    }
}

private struct AppRowView: View {
    let row: UsageRow
    let icon: NSImage
    var indented = false

    var body: some View {
        HStack(spacing: 8) {
            if indented { Spacer().frame(width: 16) }
            Image(nsImage: icon)
                .resizable().frame(width: 16, height: 16)

            Text(row.displayName)
                .font(.system(size: 12))
                .lineLimit(1).truncationMode(.tail)

            // Live indicator: this app moved bytes within the last 2 seconds.
            Circle()
                .fill(Color.accentColor)
                .frame(width: 5, height: 5)
                .opacity(row.isActive ? 1 : 0)

            Spacer(minLength: 8)

            Text(ByteFormat.bytes(row.total))
                .font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
