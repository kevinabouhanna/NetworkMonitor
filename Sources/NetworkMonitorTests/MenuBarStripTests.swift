import CoreGraphics
import NetworkMonitorCore

func runMenuBarStripTests() {
    Check.suite("MenuBarStrip") {

        // The readings from macOS 27 on a 1440 × 900 display: a 22 pt status
        // item in a 30 pt window. The 22 pt it used to take left the settings
        // window's title bar 8 pt under a revealed menu bar.
        Check.test("the status item's window outranks its thickness") {
            Check.expectEqual(MenuBarStrip.height(statusItemThickness: 22,
                                                  statusItemWindowHeight: 30,
                                                  safeAreaTop: 0), 30)
        }

        Check.test("a notched display's safe area outranks both") {
            Check.expectEqual(MenuBarStrip.height(statusItemThickness: 22,
                                                  statusItemWindowHeight: 30,
                                                  safeAreaTop: 37), 37)
        }

        // Before the status item has a window, the thickness is all there is.
        Check.test("with no status item window the thickness stands") {
            Check.expectEqual(MenuBarStrip.height(statusItemThickness: 22,
                                                  statusItemWindowHeight: nil,
                                                  safeAreaTop: 0), 22)
        }

        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let screens = [(frame: main, menuBarHeight: CGFloat(30))]

        // What reveals a hidden menu bar, and the case that matters most: the
        // pointer reports y == maxY there, which `CGRect.contains` excludes.
        Check.test("the pointer pressed against the top edge is in it") {
            Check.expectTrue(MenuBarStrip.contains(CGPoint(x: 700, y: 900), screens: screens))
        }

        // The bottom of a 30 pt bar is 8 pt below a 22 pt one. A click on the
        // status item lands there too, and must not read as leaving the bar.
        Check.test("the strip runs the full height of the bar") {
            Check.expectTrue(MenuBarStrip.contains(CGPoint(x: 700, y: 870), screens: screens))
            Check.expectTrue(MenuBarStrip.contains(CGPoint(x: 700, y: 875), screens: screens))
            Check.expectFalse(MenuBarStrip.contains(CGPoint(x: 700, y: 869.5), screens: screens))
        }

        Check.test("the rest of the screen is not") {
            Check.expectFalse(MenuBarStrip.contains(CGPoint(x: 700, y: 450), screens: screens))
            Check.expectFalse(MenuBarStrip.contains(CGPoint(x: 700, y: 0.5), screens: screens))
        }

        Check.test("a point on no screen is not in any strip") {
            Check.expectFalse(MenuBarStrip.contains(CGPoint(x: 2000, y: 900), screens: screens))
            Check.expectFalse(MenuBarStrip.contains(CGPoint(x: 700, y: 950), screens: screens))
        }

        // Each screen has its own menu bar, measured from its own top edge.
        Check.test("a second screen's strip is measured from its own top") {
            let side = CGRect(x: 1440, y: -180, width: 1920, height: 1080)
            let both = screens + [(frame: side, menuBarHeight: CGFloat(30))]
            Check.expectTrue(MenuBarStrip.contains(CGPoint(x: 2000, y: 900), screens: both))
            Check.expectFalse(MenuBarStrip.contains(CGPoint(x: 2000, y: 860), screens: both),
                              "level with the main screen's bar, but well below the side screen's")
        }

        // Stacked screens share an edge. It belongs to the lower one, as it does
        // for `NSMouseInRect`, and the upper screen's menu bar is far above it.
        Check.test("the edge between stacked screens belongs to the lower one") {
            let above = CGRect(x: 0, y: 900, width: 1920, height: 1080)
            let both = screens + [(frame: above, menuBarHeight: CGFloat(30))]
            Check.expectTrue(MenuBarStrip.contains(CGPoint(x: 700, y: 900), screens: both))
            Check.expectFalse(MenuBarStrip.contains(CGPoint(x: 700, y: 901), screens: both))
            Check.expectTrue(MenuBarStrip.contains(CGPoint(x: 700, y: 1980), screens: both))
        }
    }
}
