import AppKit
import Foundation
import NetworkMonitorCore

/// Menu bar, Dock or both (#69), and the Dock icon that is the speeds (#523).
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

        // The speeds are drawn on the Dock icon only where there's one all
        // the time, and it's to show them (#523).
        Check.test("Dock and Both draw the speeds on the Dock icon with Speeds") {
            Check.expectEqual(AppPlacement.allCases.filter { $0.drawsSpeedsOnDock(.speeds) }, [.dock, .both])
            Check.expectEqual(AppPlacement.allCases.filter { $0.drawsSpeedsOnDock(.appIcon) }, [])
        }

        // Each mode keeps its own choice: Speeds to begin with in Dock, where
        // the speeds are nowhere else, and the app's icon in Both, as it was
        // before there was a choice.
        Check.test("the Dock icon's choice, per mode, with its own default") {
            let name = "AppPlacementTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }

            let setting = AppPlacementSetting(defaults: defaults)
            Check.expectEqual(setting.dockIcon, .appIcon, "Menu bar mode's Dock icon is the app's")
            Check.expectFalse(setting.drawsSpeedsOnDock)
            setting.placement = .dock
            Check.expectEqual(setting.dockIcon, .speeds)
            Check.expectTrue(setting.drawsSpeedsOnDock)
            setting.placement = .both
            Check.expectEqual(setting.dockIcon, .appIcon, "existing Both users see no change")
            Check.expectFalse(setting.drawsSpeedsOnDock)

            setting.dockIcon = .speeds
            Check.expectTrue(setting.drawsSpeedsOnDock)
            setting.placement = .dock
            setting.dockIcon = .appIcon
            Check.expectFalse(setting.drawsSpeedsOnDock)
            let reread = AppPlacementSetting(defaults: defaults)
            Check.expectEqual(reread.dockIconInDock, .appIcon)
            Check.expectEqual(reread.dockIconInBoth, .speeds, "choosing in Dock leaves Both's alone")

            reread.dockIconInDock = .speeds
            reread.dockIconInBoth = .appIcon
            for mode in [AppPlacement.dock, .both] {
                Check.expectNil(defaults.object(forKey: AppPlacementSetting.dockIconKey(mode)),
                                "a default isn't saved, so a future default reaches everyone")
            }
            defaults.set("sideways", forKey: AppPlacementSetting.dockIconKey(.dock))
            Check.expectEqual(AppPlacementSetting(defaults: defaults).dockIconInDock, .speeds,
                              "an unknown value falls back to the default")
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
        // icon's squircle across and down at every tile size, never overlap,
        // sit on whole pixels, and stay big enough to read in the Dock (#523).
        Check.test("the Dock icon's speeds fit its square") {
            let widest = [
                SpeedReadout(down: MenuBarTitle.downLine(999_000_000, unit: .bytes),
                             up: MenuBarTitle.upLine(0, unit: .bytes), tints: .live),
                SpeedReadout(down: MenuBarTitle.downLine(99_960, unit: .bits),
                             up: MenuBarTitle.upLine(123_456, unit: .bits), tints: .live),
                SpeedReadout(down: "↓ \(ByteFormat.menuBarSpeed(950_000_000, unit: .bits))",
                             up: "↑ \(ByteFormat.menuBarSpeed(45_000_000, unit: .bits))",
                             tints: MenuBarTints.testChoices[0]),
            ]
            for side in [CGFloat(32), 64, 128, 256] {
                let bounds = NSRect(x: 0, y: 0, width: side, height: side)
                let square = DockSpeedView.squareRect(in: bounds)
                let quiet = DockSpeedView.layout(for: SpeedReadout(down: MenuBarTitle.downLine(0),
                                                                   up: MenuBarTitle.upLine(0), tints: .live),
                                                 in: bounds)
                for readout in widest {
                    let layout = DockSpeedView.layout(for: readout, in: bounds)
                    let boxes = layout.lines.flatMap { [$0.arrowFrame, $0.figureFrame, $0.unitFrame] }
                    Check.expectEqual(layout.lines.map(\.unit).filter(\.isEmpty), [],
                                      "\(readout.down) has no unit")
                    Check.expectTrue(boxes.allSatisfy { square.contains($0) },
                                     "\(readout.down) goes outside the square at \(side) pt")
                    for (index, box) in boxes.enumerated() {
                        for other in boxes[(index + 1)...] {
                            Check.expectFalse(box.intersects(other),
                                              "\(readout.down): two boxes overlap at \(side) pt")
                        }
                    }
                    // Baselines, arrows and left edges are whole pixels at 2x.
                    let edges = boxes.map(\.minY) + layout.lines.flatMap {
                        [$0.arrowFrame.maxY, $0.arrowFrame.minX, $0.arrowFrame.maxX,
                         $0.figureFrame.minX, $0.unitFrame.minX] }
                    Check.expectTrue(edges.allSatisfy { ($0 * 2).rounded() == $0 * 2 },
                                     "an edge between pixels at \(side) pt")
                    Check.expectTrue(layout.figureFont.pointSize >= side * 0.22,
                                     "\(layout.figureFont.pointSize) pt is too small to read on a \(side) pt tile")
                    // The same size and edges whatever the figures, so it never jumps.
                    Check.expectEqual(Double(quiet.figureFont.pointSize), Double(layout.figureFont.pointSize))
                    Check.expectEqual(Double(quiet.lines[0].arrowFrame.minX), Double(layout.lines[0].arrowFrame.minX))
                    Check.expectTrue(abs(quiet.lines[1].figureFrame.maxX - layout.lines[1].figureFrame.maxX) <= 0.5,
                                     "the figures' right edge moves at \(side) pt")
                }
            }
        }

        // Three significant figures: what the Dock has room to show large.
        Check.test("the Dock icon shows three significant figures") {
            let cases: [(String, String, String)] = [
                ("↓  0.00 B/s ", "0", "B/s"), ("↑  1.23 KB/s", "1.23", "KB/s"), ("↓ 12.34 MB/s", "12.3", "MB/s"),
                ("↓ 99.96 MB/s", "100", "MB/s"), ("↑ 948.2 Mb/s", "948", "Mb/s"), ("↓ 999.7 KB/s", "999", "KB/s"),
            ]
            for (line, figure, unit) in cases {
                let layout = DockSpeedView.layout(for: SpeedReadout(down: line, up: line, tints: .live),
                                                  in: NSRect(x: 0, y: 0, width: 128, height: 128))
                Check.expectEqual(layout.lines[0].figure, figure, line)
                Check.expectEqual(layout.lines[0].unit, unit, line)
            }
        }

        // The square follows light and dark, so the speed colors, made for a
        // dark menu bar, are drawn darker on light, and any chosen too dark,
        // lighter on dark: at least 3:1 against the square either way.
        Check.test("the Dock icon's speeds read on light and on dark") {
            func luminance(_ color: NSColor) -> Double {
                let c = color.usingColorSpace(.sRGB)!
                func linear(_ v: CGFloat) -> Double {
                    let v = Double(v)
                    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
                }
                return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent)
                    + 0.0722 * linear(c.blueComponent)
            }
            func contrast(_ a: NSColor, _ b: NSColor) -> Double {
                let (x, y) = (luminance(a), luminance(b))
                return (max(x, y) + 0.05) / (min(x, y) + 0.05)
            }
            let chosenDark = MenuBarTints(down: MenuBarColors.color(hex: "#0A2A8A")!,
                                          up: MenuBarColors.color(hex: "#333333")!)
            for tints in [MenuBarTints.live, .blockingEverything, chosenDark] + MenuBarTints.testChoices {
                for dark in [false, true] {
                    for tint in [tints.down, tints.up] {
                        let drawn = MenuBarColors.readable(tint, onDark: dark)
                        let (top, bottom) = DockSpeedView.background(dark: dark)
                        Check.expectTrue(min(contrast(drawn, top), contrast(drawn, bottom)) >= 3,
                                         "\(MenuBarColors.hex(tint)) doesn't read on \(dark ? "dark" : "light")")
                    }
                }
            }
            // On dark, the defaults are drawn as chosen.
            Check.expectEqual(MenuBarColors.hex(MenuBarColors.readable(MenuBarTints.live.down, onDark: true)),
                              MenuBarColors.hex(MenuBarTints.live.down))
            Check.expectEqual(MenuBarColors.hex(MenuBarColors.readable(MenuBarTints.live.up, onDark: true)),
                              MenuBarColors.hex(MenuBarTints.live.up))
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
