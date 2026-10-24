import AppKit
import Foundation
import NetworkMonitorCore
import SwiftUI

func runSettingsTests() {
    Check.suite("Settings — panes") {

        // The toolbar's order: what people open most first, About last.
        Check.test("the toolbar runs General, Speed Test, History, Hotspot, About") {
            Check.expectEqual(SettingsPane.allCases.map(\.title),
                              ["General", "Speed Test", "History", "Hotspot", "About"])
        }

        // A missing symbol draws an empty toolbar button, silently.
        Check.test("every pane's symbol exists on this system") {
            for pane in SettingsPane.allCases {
                Check.expectNotNil(NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil),
                                   "\(pane.symbol) for \(pane.title)")
            }
        }

        // Without it a tab clicked while the last pane change was still
        // animating was ignored, and needed a second click (#55).
        Check.test("the toolbar takes clicks while a pane is changing") {
            Check.expectTrue(SettingsWindowController.paneTransition.contains(.allowUserInteraction))
        }

        // The HIG's "restore the most recently viewed pane".
        Check.test("Settings reopens on the last pane viewed, General the first time") {
            let defaults = UserDefaults(suiteName: "settings-pane-\(UUID().uuidString)")!
            Check.expectEqual(SettingsPane.last(in: defaults), .general)
            SettingsPane.hotspot.remember(in: defaults)
            Check.expectEqual(SettingsPane.last(in: defaults), .hotspot)
            defaults.set("preferences", forKey: "settingsPane")
            Check.expectEqual(SettingsPane.last(in: defaults), .general,
                              "an unknown pane falls back to General")
        }

        // Building the window selects the first pane by itself. Taken for a
        // choice, it overwrote the last pane, so after every relaunch Settings
        // opened on General (#14). About, because Hotspot refreshes the real
        // metering state when it appears.
        Check.test("a new Settings window reopens on the last pane, not General") {
            let defaults = UserDefaults(suiteName: "settings-window-\(UUID().uuidString)")!
            SettingsPane.about.remember(in: defaults)
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("settings-window-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = UsageStore(storeURL: dir.appendingPathComponent("usage.json"))
            let metering = MeteringController(store: store,
                                              journal: SuppressionJournal(url: dir.appendingPathComponent("journal.json")),
                                              suppressors: [], defaults: defaults)
            let model = MonitorViewModel(store: store, metering: metering)
            let settings = SettingsWindowController(model: model, history: HistoryViewModel(monitor: model),
                                                    onUninstall: {}, defaults: defaults)
            Check.expectEqual(SettingsPane.last(in: defaults), .about,
                              "building the window must not overwrite the last pane")
            settings.select(nil)
            Check.expectEqual(settings.window.title, "About")
        }
    }

    Check.suite("Settings — window size") {
        // A screen below a 30 pt menu bar, and a window whose top sits under it.
        let usable = NSRect(x: 0, y: 0, width: 1440, height: 870)
        let current = NSRect(x: 450, y: 370, width: 540, height: 500)

        Check.test("a pane that fits keeps the top edge where it is") {
            let frame = SettingsWindowController.frame(for: NSSize(width: 540, height: 300),
                                                       current: current, usable: usable)
            Check.expectEqual(frame, NSRect(x: 450, y: 570, width: 540, height: 300))
        }

        Check.test("a pane that would run off the bottom moves up instead") {
            let lower = NSRect(x: 450, y: 100, width: 540, height: 500)
            let frame = SettingsWindowController.frame(for: NSSize(width: 540, height: 800),
                                                       current: lower, usable: usable)
            Check.expectEqual(frame.minY, 0)
            Check.expectEqual(frame.height, 800)
        }

        // #57: Auto Layout resizes keeping the left edge, which walked the
        // window left 60 pt each time History gave way to a narrower pane.
        Check.test("a resize that kept the left edge goes back to the old centre") {
            let history = NSRect(x: 336, y: 40, width: 768, height: 820)
            let shrunk = NSRect(x: 336, y: 90, width: 648, height: 770)
            Check.expectEqual(SettingsWindowController.centred(shrunk, after: history),
                              NSRect(x: 396, y: 90, width: 648, height: 770))
            let grown = NSRect(x: 396, y: 40, width: 768, height: 820)
            Check.expectEqual(SettingsWindowController.centred(grown, after: shrunk.offsetBy(dx: 60, dy: 0)),
                              NSRect(x: 336, y: 40, width: 768, height: 820), "growing too")
        }

        Check.test("a centred resize, a taller pane and a drag are left alone") {
            let general = NSRect(x: 396, y: 90, width: 648, height: 770)
            let fitted = NSRect(x: 336, y: 40, width: 768, height: 820)
            Check.expectEqual(SettingsWindowController.centred(fitted, after: general), fitted)
            let taller = NSRect(x: 396, y: 40, width: 648, height: 820)
            Check.expectEqual(SettingsWindowController.centred(taller, after: general), taller)
            let dragged = general.offsetBy(dx: -200, dy: 30)
            Check.expectEqual(SettingsWindowController.centred(dragged, after: general), dragged)
        }

        // #46: with both Hotspot lists open, the window ran off the screen.
        Check.test("a pane taller than the screen is capped at the screen, and scrolls") {
            let frame = SettingsWindowController.frame(for: NSSize(width: 540, height: 1600),
                                                       current: current, usable: usable)
            Check.expectEqual(frame, NSRect(x: 450, y: 0, width: 540, height: 870))
        }

        // The window grows with the pane up to the cap, so the scroll view has
        // to pass the pane's full height on, and keep the pane's width whatever
        // the pane measures.
        Check.test("a pane in its scroll view reports its full height, at the pane's width") {
            let host = SettingsWindowController.paneHost(Color.clear.frame(width: 300, height: 1200),
                                                         width: 540)
            _ = host.view
            Check.expectEqual(host.preferredContentSize, NSSize(width: 540, height: 1200))
        }
    }
}
