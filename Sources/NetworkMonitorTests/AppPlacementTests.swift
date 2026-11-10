import AppKit
import Foundation
import NetworkMonitorCore

/// Menu bar, Dock or both (#69), and the speeds drawn on the Dock icon.
func runAppPlacementTests() {
    Check.suite("AppPlacement") {

        // Never neither: with no status item and no Dock icon there'd be no
        // way back to the app.
        Check.test("every choice shows the app somewhere") {
            for placement in AppPlacement.allCases {
                Check.expectTrue(placement.showsMenuBar || placement.showsDock,
                                 "\(placement.rawValue) shows the app nowhere")
            }
            Check.expectFalse(AppPlacement.dock.showsMenuBar, "Dock mode has nothing in the menu bar")
            Check.expectTrue(AppPlacement.both.showsMenuBar && AppPlacement.both.showsDock)
            Check.expectFalse(AppPlacement.menuBar.showsDock,
                              "Menu bar mode has a Dock icon only while a window is open")
        }

        // The speeds are drawn on the Dock icon only where they aren't in the
        // menu bar.
        Check.test("only Dock mode draws the speeds on the Dock icon") {
            Check.expectEqual(AppPlacement.allCases.filter(\.drawsSpeedsOnDock), [.dock])
        }

        Check.test("the menu bar by default, and the choice kept") {
            let name = "AppPlacementTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }

            Check.expectEqual(AppPlacementSetting(defaults: defaults).placement, .menuBar)
            AppPlacementSetting(defaults: defaults).placement = .dock
            Check.expectEqual(AppPlacementSetting(defaults: defaults).placement, .dock)
            AppPlacementSetting(defaults: defaults).placement = .menuBar
            Check.expectNil(defaults.object(forKey: AppPlacementSetting.key),
                            "the default isn't saved, so a future default reaches everyone")
            defaults.set("nowhere", forKey: AppPlacementSetting.key)
            Check.expectEqual(AppPlacementSetting(defaults: defaults).placement, .menuBar,
                              "an unknown value falls back to the menu bar")
        }

        // The widest figures there are, live and a speed test's, fit the
        // plate across and down at every tile size, and stay big enough to
        // read in the Dock.
        Check.test("the Dock icon's speeds fit its plate") {
            let widest = [
                SpeedReadout(down: MenuBarTitle.downLine(999_000_000, unit: .bytes),
                             up: MenuBarTitle.upLine(0, unit: .bytes), tints: .live),
                SpeedReadout(down: MenuBarTitle.downLine(999_000_000, unit: .bits),
                             up: MenuBarTitle.upLine(123_456, unit: .bits), tints: .live),
                SpeedReadout(down: "↓ \(ByteFormat.menuBarSpeed(950_000_000, unit: .bits))",
                             up: "↑ \(ByteFormat.menuBarSpeed(45_000_000, unit: .bits))",
                             tints: MenuBarTints.testChoices[0]),
            ]
            for side in [CGFloat(128), 256] {
                let bounds = NSRect(x: 0, y: 0, width: side, height: side)
                let plate = NSRect(x: 0, y: 0, width: side * 824 / 1024, height: side * 0.42)
                for readout in widest {
                    let font = DockSpeedView.font(for: readout, in: bounds)
                    let lines = [readout.down, readout.up]
                        .map { NSAttributedString(string: $0.replacingOccurrences(of: " ", with: "\u{2007}"),
                                                  attributes: [.font: font]).size() }
                    Check.expectTrue(lines.allSatisfy { $0.width <= plate.width },
                                     "\(readout.down) is wider than the plate at \(side) pt")
                    Check.expectTrue(lines.map(\.height).reduce(0, +) <= plate.height,
                                     "two lines are taller than the plate at \(side) pt")
                    Check.expectTrue(font.pointSize >= side * 0.11,
                                     "\(font.pointSize) pt is too small to read on a \(side) pt tile")
                }
            }
        }

        // The menu bar draws what the readout says, so the two never differ.
        Check.test("the menu bar's picture is the readout's") {
            let readout = SpeedReadout(down: MenuBarTitle.downLine(1_234_567), up: MenuBarTitle.upLine(4_321),
                                       tints: .live)
            let fromReadout = MenuBarTitle.image(readout)
            let direct = MenuBarTitle.image(down: 1_234_567, up: 4_321)
            Check.expectEqual(Double(fromReadout.size.width), Double(direct.size.width))
            Check.expectEqual(Double(fromReadout.size.height), Double(direct.size.height))
        }
    }
}
