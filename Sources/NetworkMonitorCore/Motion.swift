import AppKit
import SwiftUI

/// How the app moves (#436), after Apple's guidance on motion: brief, so it
/// never holds you up; a spring that settles without bouncing; moving from
/// where the change came from, so it says what changed; and, with Reduce
/// Motion on, a short fade in place of any movement.
enum Motion {
    static var isReduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// A choice moving to another: a switch's raised pill, the popover's
    /// raised button, the sidebar's selection.
    static var choice: Animation { isReduced ? .easeInOut(duration: 0.1) : .snappy(duration: 0.21) }

    /// Content changing in place: a list for another period or grouping,
    /// figures, bars, a row opening.
    static var content: Animation { isReduced ? .easeInOut(duration: 0.12) : .smooth(duration: 0.26) }

    /// One view giving way to another: rises a little as it fades in, so the
    /// eye follows it, and only fades with Reduce Motion on.
    static var swap: AnyTransition {
        isReduced ? .opacity
            : .asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity)
    }

    /// The same for AppKit's animations: a window's content and its toolbar.
    static var duration: TimeInterval { isReduced ? 0.1 : 0.19 }
    static var timing: CAMediaTimingFunction {
        // Apple's ease-out for things arriving: quick to start, gentle to settle.
        CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
    }

    /// Runs `changes` animated as content changing in place.
    static func content(_ changes: () -> Void) {
        withAnimation(content) { changes() }
    }
}

extension View {
    /// Focusable as a button is (#452): only through keyboard navigation,
    /// Tab with System Settings › Keyboard › Keyboard navigation on, and
    /// never from a click. Plain `.focusable()` lets a click focus it as a
    /// text field is focused, and the focus ring showed round the sidebar.
    @ViewBuilder
    func keyboardFocusable() -> some View {
        if #available(macOS 14, *) {
            focusable(interactions: .activate)
        } else {
            focusable(NSApp.isFullKeyboardAccessEnabled)
        }
    }
}
