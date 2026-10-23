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
    }
}
