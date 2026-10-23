import AppKit
import Foundation
import NetworkMonitorCore

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
}
