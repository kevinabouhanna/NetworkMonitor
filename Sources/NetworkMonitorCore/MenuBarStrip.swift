import CoreGraphics

/// The band across the top of each screen that the menu bar occupies, whether or
/// not it is showing at the moment.
///
/// Two things need it, both because of "Automatically hide and show the menu
/// bar". The settings window keeps its title bar below it, since a revealed menu
/// bar draws over whatever is underneath. And the popover asks whether the
/// pointer is in it, to tell the menu bar being revealed apart from a real switch
/// to another app — see `AppDelegate.appDidResignActive`.
public enum MenuBarStrip {

    /// The menu bar's height, taken from three readings because each one alone
    /// falls short somewhere.
    ///
    /// `NSStatusBar.system.thickness` is the height of a status *item*: 22 pt,
    /// which was also the menu bar's height until macOS 26. On macOS 27 the menu
    /// bar itself is 30 pt — measured from the window server's own menu bar
    /// window and from `NSMenu.menuBarHeight` — while the thickness still says 22.
    /// The status item's window spans the full bar (30 pt, with the 22 pt button
    /// centred in it), so its height is the reading that keeps up.
    /// `safeAreaInsets.top` covers notched displays, where the bar is taller
    /// again around the camera housing.
    public static func height(statusItemThickness: CGFloat,
                              statusItemWindowHeight: CGFloat?,
                              safeAreaTop: CGFloat) -> CGFloat {
        max(statusItemThickness, statusItemWindowHeight ?? 0, safeAreaTop)
    }

    /// Whether `point`, in global screen coordinates, lies in the menu bar strip
    /// of the screen it is on.
    ///
    /// Which screen that is follows `NSMouseInRect` for unflipped coordinates —
    /// the top edge belongs to the screen, the bottom edge does not — because the
    /// pointer pushed against the top of a screen, which is exactly what reveals
    /// a hidden menu bar, reports a y equal to that screen's `maxY`. A plain
    /// `CGRect.contains` would place it on no screen at all.
    public static func contains(_ point: CGPoint,
                                screens: [(frame: CGRect, menuBarHeight: CGFloat)]) -> Bool {
        guard let screen = screens.first(where: { isOnScreen(point, $0.frame) }) else {
            return false
        }
        return point.y >= screen.frame.maxY - screen.menuBarHeight
    }

    private static func isOnScreen(_ point: CGPoint, _ frame: CGRect) -> Bool {
        point.x >= frame.minX && point.x < frame.maxX
            && point.y > frame.minY && point.y <= frame.maxY
    }
}
