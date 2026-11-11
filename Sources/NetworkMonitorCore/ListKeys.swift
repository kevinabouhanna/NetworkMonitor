import SwiftUI

/// A list the keyboard moves through as one stop (#546), as Ads and
/// Trackers' is (#536): Tab reaches the list, ↑ and ↓ move from row to row,
/// → and ← open and close one (← from a row inside goes back up to the one
/// it's in), and Space or Return does what a click on the row does.
///
/// Usage History's and Connections' lists, where a click narrows the window
/// to the row, so moving can't choose as it does in Ads and Trackers: the
/// list would narrow to the first row. The keyboard has a row of its own,
/// marked while the list has focus, and VoiceOver reads it as the list's
/// value.
struct KeyRow: Equatable {
    /// The row's `.id` in the list, which `ScrollViewReader` scrolls to.
    let id: String
    /// What VoiceOver says for it: its name and figure.
    let spoken: String
    /// The row it's inside, if any.
    var parent: String? = nil
    /// nil for a row with nothing to open; otherwise whether it's open.
    var isOpen: Bool? = nil
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
    /// shown, in order; `name` is what VoiceOver calls the list.
    func listKeys(_ rows: [KeyRow], cursor: ListCursor, name: String, proxy: ScrollViewProxy,
                  open: @escaping (KeyRow, Bool) -> Void,
                  choose: @escaping (KeyRow) -> Void) -> some View {
        modifier(ListKeys(rows: rows, cursor: cursor, name: name, proxy: proxy, open: open, choose: choose))
    }
}

private struct ListKeys: ViewModifier {
    let rows: [KeyRow]
    @ObservedObject var cursor: ListCursor
    let name: String
    let proxy: ScrollViewProxy
    let open: (KeyRow, Bool) -> Void
    let choose: (KeyRow) -> Void
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
            .modifier(ActivateKeys { if let index { choose(rows[index]) } else if let first = rows.first { go(first.id) } })
            .accessibilityLabel(name)
            .accessibilityValue(index.map { rows[$0].spoken } ?? "")
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

/// Space and Return, where macOS has `onKeyPress` (14 on).
struct ActivateKeys: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content.onKeyPress(keys: [.space, .return]) { _ in
                action()
                return .handled
            }
        } else {
            content
        }
    }
}
