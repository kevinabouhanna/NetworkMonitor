import AppKit
import Foundation
import NetworkMonitorCore

func runMenuBarColorsTests() {
    Check.suite("MenuBarColors") {

        func hex(_ value: String) -> NSColor { MenuBarColors.color(hex: value)! }
        func freshDefaults() -> UserDefaults {
            UserDefaults(suiteName: "menu-bar-colors-\(UUID().uuidString)")!
        }

        // Nobody who keeps the defaults should see anything new, the test's
        // cyan included.
        Check.test("with the default colours, the readout and the test look as before") {
            let colors = MenuBarColors(defaults: freshDefaults())
            Check.expectEqual(MenuBarColors.hex(colors.download), "#51FF70")
            Check.expectEqual(MenuBarColors.hex(colors.upload), "#E5E5E5")
            Check.expectEqual(MenuBarColors.hex(colors.test.down), "#64D2FF")
            Check.expectEqual(MenuBarColors.hex(colors.test.up), "#B4E9FF")
            Check.expectTrue(colors.isDefault)
        }

        // The issue's one condition (#45): picking the test's own cyan for the
        // live rates must not make a test look like live rates.
        Check.test("a live colour too close to the test's moves the test to other colours") {
            let colors = MenuBarColors(defaults: freshDefaults())
            colors.download = hex("#64D2FF")
            Check.expectFalse(colors.test == MenuBarTints.testChoices[0], "still cyan")
            for live in [colors.download, colors.upload] {
                Check.expectTrue(MenuBarColors.distance(colors.test.down, live) >= MenuBarTints.clearDown)
                Check.expectTrue(MenuBarColors.distance(colors.test.up, live) >= MenuBarTints.clearUp)
            }
        }

        Check.test("the upload colour counts too") {
            let test = MenuBarTints.test(clearOf: MenuBarTints(down: hex("#51FF70"), up: hex("#64D2FF")))
            Check.expectFalse(test == MenuBarTints.testChoices[0],
                              "a cyan test download would match the live upload line")
        }

        // Whatever two colours someone picks, the download line changes plainly
        // when a test takes over. The odd pair that blocks every choice gets
        // the nearest, which falls short of the line by less than 0.005.
        Check.test("whatever the colours, a test's download line looks different") {
            var palette = [hex("#000000"), hex("#808080"), hex("#E5E5E5"), hex("#FFFFFF")]
            for hue in stride(from: 0.0, to: 1.0, by: 1.0 / 18) {
                for (saturation, brightness) in [(1.0, 1.0), (0.5, 1.0), (1.0, 0.6), (0.3, 0.9)] {
                    palette.append(MenuBarColors.normalized(
                        NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)))
                }
            }
            var worst = Double.infinity
            for down in palette {
                for up in palette {
                    let test = MenuBarTints.test(clearOf: MenuBarTints(down: down, up: up))
                    worst = min(worst, MenuBarColors.distance(test.down, down),
                                MenuBarColors.distance(test.down, up))
                }
            }
            Check.expectTrue(worst >= MenuBarTints.clearDown - 0.005, "closest was \(worst)")
        }

        // Saved only while it differs from the default, so a future default
        // reaches everyone who never picked one.
        Check.test("a picked colour is kept, and putting the defaults back forgets it") {
            let defaults = freshDefaults()
            let colors = MenuBarColors(defaults: defaults)
            colors.upload = hex("#FF9500")
            Check.expectEqual(defaults.string(forKey: "menuBarUploadColor"), "#FF9500")
            Check.expectNil(defaults.string(forKey: "menuBarDownloadColor"))
            Check.expectEqual(MenuBarColors.hex(MenuBarColors(defaults: defaults).upload), "#FF9500",
                              "a relaunch keeps it")
            Check.expectFalse(colors.isDefault)

            colors.reset()
            Check.expectNil(defaults.string(forKey: "menuBarUploadColor"))
            Check.expectTrue(colors.isDefault)
        }

        Check.test("a change redraws the menu bar") {
            let colors = MenuBarColors(defaults: freshDefaults())
            var redraws = 0
            colors.didChange = { redraws += 1 }
            colors.download = hex("#FF3B30")
            Check.expectEqual(redraws, 1)
        }

        // The colour panel hands back colours in whatever space it likes.
        Check.test("a colour from any colour space is saved as sRGB") {
            let p3 = NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1)
            let saved = MenuBarColors.hex(p3)
            Check.expectEqual(saved, "#FF0000", "out of gamut is clamped")
            Check.expectEqual(MenuBarColors.hex(MenuBarColors.normalized(hex("#12AB34"))), "#12AB34")
            Check.expectNil(MenuBarColors.color(hex: "red"))
            Check.expectNil(MenuBarColors.color(hex: "#12345"))
        }

        Check.test("the readout is drawn in the colours it's given") {
            let tints = MenuBarTints(down: hex("#FF3B30"), up: hex("#0A84FF"))
            let attributed = MenuBarTitle.attributed(down: 1024, up: 1024, tints: tints)
            let newline = attributed.string.distance(from: attributed.string.startIndex,
                                                     to: attributed.string.firstIndex(of: "\n")!)
            Check.expectTrue(attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil)
                             as? NSColor == tints.down)
            Check.expectTrue(attributed.attribute(.foregroundColor, at: newline + 1, effectiveRange: nil)
                             as? NSColor == tints.up)
        }

        Check.test("distance runs from 0 for the same colour to 1 for black to white") {
            Check.expectEqual(MenuBarColors.distance(hex("#51FF70"), hex("#51FF70")), 0)
            let blackToWhite = MenuBarColors.distance(hex("#000000"), hex("#FFFFFF"))
            Check.expectTrue(abs(blackToWhite - 1) < 0.001, "got \(blackToWhite)")
        }
    }
}
