import AppKit

/// Where a window sits among every app's windows, front to back, as the window
/// server has them.
///
/// The popover needs it to leave Settings where it was (#71). Activating the app
/// for the popover brings Settings forward over the app the user is in, and
/// putting it back means ordering it below the window that was in front of it,
/// which is usually another app's and so only the window server knows of.
public enum WindowStack {

    /// The window directly in front of `window` on the same layer, or nil when
    /// nothing is: it's frontmost, or not on screen to be covered.
    public static func window(inFrontOf window: Int) -> Int? {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        let stack = info.compactMap { entry -> (number: Int, layer: Int)? in
            guard let number = entry[kCGWindowNumber as String] as? Int,
                  let layer = entry[kCGWindowLayer as String] as? Int else { return nil }
            return (number, layer)
        }
        return Self.window(inFrontOf: window, in: stack)
    }

    /// `stack` runs front to back, as `CGWindowListCopyWindowInfo` lists it.
    /// Other layers don't count: the menu bar, the popover and Notification
    /// Center's windows are all in that list, and none of them covers Settings
    /// in a way ordering could change.
    public static func window(inFrontOf window: Int,
                              in stack: [(number: Int, layer: Int)]) -> Int? {
        guard let index = stack.firstIndex(where: { $0.number == window }) else { return nil }
        let layer = stack[index].layer
        return stack[..<index].last(where: { $0.layer == layer })?.number
    }
}
