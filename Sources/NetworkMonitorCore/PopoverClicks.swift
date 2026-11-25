import AppKit

/// Which clicks in the app's own windows close the popover (#728). Clicks in
/// other apps always do; `AppDelegate` hears those apart.
public enum PopoverClicks {

    /// A click in any of the app's windows but the popover's own: itself, and
    /// what opens from it, an ⓘ's popover or a sheet, however deep. Nor the
    /// status item's windows (it toggles, #6, and each screen's menu bar has
    /// its own), the invisible window the popover is anchored to, or a menu:
    /// all of them at the menu bar's level or above, where no window that
    /// holds anything else is.
    public static func closes(clickIn window: NSWindow?, popover: NSWindow?) -> Bool {
        guard let window, let popover else { return false }
        if isIn(window, anyOf: [popover]) { return false }
        return window.level.rawValue < NSWindow.Level.statusBar.rawValue
    }

    /// Whether `window` is one of `windows`, or opened from one, however deep.
    public static func isIn(_ window: NSWindow?, anyOf windows: [NSWindow]) -> Bool {
        var next = window
        while let current = next {
            if windows.contains(where: { $0 === current }) { return true }
            next = current.parent ?? current.sheetParent
        }
        return false
    }
}
