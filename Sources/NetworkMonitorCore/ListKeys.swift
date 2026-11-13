import SwiftUI

/// A list the keyboard moves through as one stop (#546), as Ads and
/// Trackers' is (#536): Tab reaches the list, ↑ and ↓ move a ring from row to
/// row, → and ← open and close one (← from a row inside goes back up to the
/// one it's in), Space does what a click on the row does (opens or closes
/// it), and Return what its Filter button does (#593). Moving never filters:
/// the keyboard has a row of its own, marked while the list has focus, and
/// VoiceOver reads it as the list's value.
struct KeyRow: Equatable {
    /// The row's `.id` in the list, which `ScrollViewReader` scrolls to.
    let id: String
    /// What VoiceOver says for it: its name and figure.
    let spoken: String
    /// The row it's inside, if any.
    var parent: String? = nil
    /// nil for a row with nothing to open; otherwise whether it's open.
    var isOpen: Bool? = nil
    /// Its name alone, for what VoiceOver hears as a filter goes on or off.
    var name: String = ""
    /// nil for a row that can't filter (a heading: System); otherwise
    /// whether the window is filtered to it.
    var isFiltered: Bool? = false
}

/// The row the keyboard is on, and whether the list has focus, which the
/// rows read to mark it.
final class ListCursor: ObservableObject {
    @Published var id: String?
    @Published var hasFocus = false

    func marks(_ id: String) -> Bool { hasFocus && self.id == id }
}

extension View {
    /// Makes the list one stop the keys move through. `rows` are the rows
    /// shown, in order; `name` is what VoiceOver calls the list. `open` opens
    /// or closes a row; `filter` filters the window to it, or lets go.
    func listKeys(_ rows: [KeyRow], cursor: ListCursor, name: String, proxy: ScrollViewProxy,
                  open: @escaping (KeyRow, Bool) -> Void,
                  filter: @escaping (KeyRow) -> Void) -> some View {
        modifier(ListKeys(rows: rows, cursor: cursor, name: name, proxy: proxy, open: open, filter: filter))
    }
}

private struct ListKeys: ViewModifier {
    let rows: [KeyRow]
    @ObservedObject var cursor: ListCursor
    let name: String
    let proxy: ScrollViewProxy
    let open: (KeyRow, Bool) -> Void
    let filter: (KeyRow) -> Void
    /// A property wrapper, not a macro like `@State`, so it builds with
    /// Command Line Tools.
    @FocusState private var isFocused: Bool

    private var index: Int? { rows.firstIndex { $0.id == cursor.id } }

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused($isFocused)
            .modifier(NoFocusRing())
            .onChange(of: isFocused) { cursor.hasFocus = $0 }
            .onMoveCommand(perform: move)
            .modifier(RowKeys(space: { if let index { toggle(rows[index]) } else { goFirst() } },
                              return: { if let index { filterRow(rows[index]) } else { goFirst() } }))
            .accessibilityLabel(name)
            .accessibilityValue(index.map { rows[$0].spoken } ?? "")
            // The ring's row offers its Filter and its ▸ as actions too
            // (VO-⌘-Space), as its buttons do under the pointer.
            .modifier(RowActions(row: index.map { rows[$0] }, open: toggle, filter: filterRow))
    }

    private func goFirst() {
        if let first = rows.first { go(first.id) }
    }

    /// Space: what a click on the row does. A row with nothing inside only
    /// keeps the ring.
    private func toggle(_ row: KeyRow) {
        guard let isOpen = row.isOpen else { return }
        withAnimation(.easeInOut(duration: 0.15)) { open(row, !isOpen) }
    }

    /// Return: what the row's Filter button does, said aloud.
    private func filterRow(_ row: KeyRow) {
        guard let isFiltered = row.isFiltered else { return }
        filter(row)
        ListAnnouncement.filter(row.name.isEmpty ? row.spoken : row.name, isOn: !isFiltered)
    }

    private func go(_ id: String) {
        cursor.id = id
        proxy.scrollTo(id)
    }

    private func move(_ direction: MoveCommandDirection) {
        guard !rows.isEmpty else { return }
        switch direction {
        case .down:
            go(rows[index.map { min($0 + 1, rows.count - 1) } ?? 0].id)
        case .up:
            go(rows[index.map { max($0 - 1, 0) } ?? 0].id)
        case .right:
            guard let index, rows[index].isOpen == false else { return }
            withAnimation(.easeInOut(duration: 0.15)) { open(rows[index], true) }
        case .left:
            guard let index else { return }
            if let parent = rows[index].parent {
                go(parent)
            } else if rows[index].isOpen == true {
                withAnimation(.easeInOut(duration: 0.15)) { open(rows[index], false) }
            }
        @unknown default:
            break
        }
    }
}

/// The keyboard's row, marked as a focus ring marks a control.
struct CursorMark: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if isOn {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// No focus ring round the whole list: the row the keyboard is on shows
/// where it is, as in a sidebar.
struct NoFocusRing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14, *) { content.focusEffectDisabled() } else { content }
    }
}

/// Space and Return, each its own (#593), where macOS has `onKeyPress` (14
/// on).
struct RowKeys: ViewModifier {
    let space: () -> Void
    let `return`: () -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content
                .onKeyPress(.space) { space(); return .handled }
                .onKeyPress(.return) { self.return(); return .handled }
        } else {
            content
        }
    }
}

/// The ring's row's Filter and ▸, as VoiceOver actions on the list (macOS
/// 14 on, where actions can come and go with the row).
private struct RowActions: ViewModifier {
    let row: KeyRow?
    let open: (KeyRow) -> Void
    let filter: (KeyRow) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content.accessibilityActions {
                if let row, let isFiltered = row.isFiltered {
                    Button(isFiltered ? L("Remove Filter") : L("Filter")) { filter(row) }
                }
                if let row, let isOpen = row.isOpen {
                    Button(isOpen ? L("Collapse") : L("Expand")) { open(row) }
                }
            }
        } else {
            content
        }
    }
}
