import SwiftUI

public struct MenuBarPopoverView: View {
    @ObservedObject var model: MonitorViewModel
    var onReset: () -> Void
    var onRename: () -> Void
    var onQuit: () -> Void

    public init(model: MonitorViewModel,
                onReset: @escaping () -> Void,
                onRename: @escaping () -> Void,
                onQuit: @escaping () -> Void) {
        self.model = model
        self.onReset = onReset
        self.onRename = onRename
        self.onQuit = onQuit
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
            Divider()
            footer
        }
        .frame(width: 340)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: networkSymbol)
                    .foregroundStyle(.secondary)
                Text(model.networkLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if model.isExpensiveNetwork {
                    // Surfaced because metered networks are the case where the
                    // day's total actually matters.
                    Text("METERED")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button(action: onRename) {
                    Image(systemName: "pencil").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Rename this network")
            }

            HStack(alignment: .firstTextBaseline, spacing: 14) {
                totalColumn(symbol: "arrow.down", bytes: model.totalBytesIn,
                            rate: model.downBytesPerSecond, tint: .blue)
                totalColumn(symbol: "arrow.up", bytes: model.totalBytesOut,
                            rate: model.upBytesPerSecond, tint: .green)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func totalColumn(symbol: String, bytes: Int64, rate: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
                Text(ByteFormat.bytes(bytes))
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
            Text(ByteFormat.rate(rate))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 120, alignment: .leading)
    }

    private var networkSymbol: String {
        switch model.store.currentNetwork.kind {
        case .wifi:     return "wifi"
        case .ethernet: return "cable.connector"
        case .hotspot:  return "personalhotspot"
        case .other:    return "network"
        case .offline:  return "wifi.slash"
        }
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
        .frame(maxHeight: 320)
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
                    Image(systemName: "gearshape.fill")
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

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("No network activity yet")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text("Totals reset at midnight")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Since \(model.dayStart, format: .dateTime.hour().minute())")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            Button("Reset", action: onReset)
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            Button("Quit", action: onQuit)
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
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

            VStack(alignment: .trailing, spacing: 0) {
                Text(ByteFormat.bytes(row.total))
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                Text("↓\(ByteFormat.bytes(row.bytesIn))  ↑\(ByteFormat.bytes(row.bytesOut))")
                    .font(.system(size: 9)).monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .help("\(row.displayName) — ↓\(ByteFormat.bytes(row.bytesIn)) ↑\(ByteFormat.bytes(row.bytesOut))")
    }
}
