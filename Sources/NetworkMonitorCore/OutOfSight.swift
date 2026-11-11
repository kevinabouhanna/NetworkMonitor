import AppKit

/// Windows the tests and DesignShots put up while Kevin works (#553). An
/// invisible window still takes a click: AppKit puts a titled window ordered
/// to (-20000, -20000) back on a display (x -1920, y 750 on Kevin's left one),
/// and a click on it brought the test process to the front while its main
/// thread was busy, beachballing the Mac (21 times in 30 hours). So the
/// process can never be frontmost, and its windows let clicks through.
public enum OutOfSight {
    /// Starts AppKit in a process that is never frontmost (`.prohibited`, not
    /// `.accessory`, which activates on launch and on a click). Accessibility
    /// still lists its windows, and `makeFirstResponder` still works.
    public static func startApp() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        // The Accessibility API only answers a process that has finished
        // launching.
        NSApp.finishLaunching()
    }
}

extension NSWindow {
    /// Transparent, letting every click through, and as far off the screens
    /// as AppKit allows; treat it as on screen all the same. Ordered in front
    /// unless `order` is false.
    public func placeOutOfSight(order: Bool = true) {
        alphaValue = 0
        ignoresMouseEvents = true
        setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        if order { orderFrontRegardless() }
    }
}
