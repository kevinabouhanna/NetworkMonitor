import AppKit
import SwiftUI

// What every row of the main window's lists shares (#593, Kevin's revised
// option B): a click anywhere on a row opens or closes it, as its ▸ does,
// and filtering is a button of its own at the end of the row, Filter, never
// a click on the row. Usage History, Connections and Ads and Trackers use
// these, and so does any list added to them, so a row behaves the same
// wherever it is.

/// A row's Filter button: the only way a list narrows the window to a row.
/// A faint funnel at rest, so every row that can filter says so; its word
/// when the pointer is on the row or the keyboard's ring is; solid, reading
/// "Filtered ✕", once on. It sits in a slot of its own width at the end of
/// the row, so the figures before it never move.
struct RowFilterButton: View {
    /// What it filters to, for VoiceOver and the tooltip.
    let name: String
    let isOn: Bool
    /// The pointer is on the row, or the keyboard's ring.
    let isLit: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: RowFilterMetrics.gap) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: RowFilterMetrics.iconSize, weight: .semibold))
                if isOn || isLit {
                    Text(isOn ? L("Filtered") : L("Filter"))
                        .font(.system(size: RowFilterMetrics.fontSize, weight: isOn ? .semibold : .regular))
                        .lineLimit(1)
                        .fixedSize()
                }
                if isOn {
                    Image(systemName: "xmark")
                        .font(.system(size: RowFilterMetrics.iconSize - 2, weight: .bold))
                }
            }
            .padding(.horizontal, RowFilterMetrics.padding)
            .frame(height: 18)
            .foregroundStyle(isOn ? AnyShapeStyle(Color.white)
                             : isLit ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isOn ? Color.accentColor
                          : isLit ? Color(nsColor: .controlBackgroundColor) : Color.clear))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isLit && !isOn ? Color.secondary.opacity(0.35) : Color.clear))
            .opacity(isOn || isLit ? 1 : 0.55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The list is the stop; Return filters the row the ring is on (#546).
        .focusable(false)
        .frame(width: RowFilterMetrics.slot, alignment: .trailing)
        .help(isOn ? L("Show everything again") : L("Filter to %@", name))
        .accessibilityLabel(isOn ? L("Remove filter, %@", name) : L("Filter to %@", name))
    }
}

enum RowFilterMetrics {
    static let fontSize: CGFloat = 11
    static let iconSize: CGFloat = 10
    static let gap: CGFloat = 3
    static let padding: CGFloat = 6
    /// The slot's width: the button's widest state, "Filtered ✕", in the
    /// app's language, so a row's figure stays put as the button changes.
    static let slot: CGFloat = {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        let words = max(width(L("Filtered")), width(L("Filter")))
        // The funnel, the ✕, two gaps and the padding either side.
        return ceil(words + iconSize + 2 + (iconSize - 2) + 2 + 2 * gap + 2 * padding)
    }()
    /// What the slot adds to a row: itself and the gap before it.
    static let rowWidth: CGFloat = slot + 8
}

extension View {
    /// A row of the main window's lists (#593): marked while the window is
    /// filtered to it, ringed while the keyboard is on it, lit under the
    /// pointer; a click anywhere on it does `onClick`, which opens or closes
    /// a row with something inside and puts the ring on any other.
    func listRow(isFiltered: Bool, isCurrent: Bool, hover: HistoryRowHover,
                 help: String?, onClick: @escaping () -> Void) -> some View {
        modifier(ListRow(isFiltered: isFiltered, isCurrent: isCurrent, hover: hover, help: help, onClick: onClick))
    }
}

private struct ListRow: ViewModifier {
    let isFiltered: Bool
    let isCurrent: Bool
    @ObservedObject var hover: HistoryRowHover
    let help: String?
    let onClick: () -> Void

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isFiltered ? Color.accentColor.opacity(0.18)
                          : hover.isHovering ? Color.secondary.opacity(0.08) : Color.clear))
            .modifier(CursorMark(isOn: isCurrent))
            .contentShape(Rectangle())
            .onHover { hover.isHovering = $0 }
            .onTapGesture(perform: onClick)
            .modifier(OptionalHelp(text: help))
    }
}

private struct OptionalHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text { content.help(text) } else { content }
    }
}

/// What a row's tooltip says a click does: only for a row that opens.
enum ListRowHelp {
    static func click(opens isOpen: Bool?) -> String? {
        isOpen.map { $0 ? L("Click to close") : L("Click to open") }
    }
}

/// What VoiceOver hears when a filter goes on or off from the keyboard
/// (#593): the list's value is the row, which doesn't change.
enum ListAnnouncement {
    static func filter(_ name: String, isOn: Bool) {
        say(isOn ? L("Filtered to %@", name) : L("Filter removed"))
    }

    static func say(_ text: String) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
