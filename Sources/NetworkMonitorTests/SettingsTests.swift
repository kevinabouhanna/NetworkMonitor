import AppKit
import Foundation
import NetworkMonitorCore
import SwiftUI

func runSettingsTests() {
    Check.suite("Settings — in the main window") {

        // One window (#436): the four sections in the popover's order, and
        // Settings at the bottom of the sidebar, in place of a Settings window.
        Check.test("the sidebar runs the four sections, then Settings") {
            Check.expectEqual(MainSection.allCases.map(\.rawValue),
                              ["history", "connections", "ads", "network", "settings"])
            Check.expectEqual(MainSection.features, [.history, .connections, .ads, .network])
        }

        // A missing symbol draws an empty sidebar row, silently.
        Check.test("every section's symbol exists on this system") {
            for section in MainSection.allCases {
                Check.expectNotNil(NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil),
                                   "\(section.symbol) for \(section.title)")
            }
        }

        Check.test("Settings opens on its page, and a section's settings go back to where they came from") {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("settings-main-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let defaults = UserDefaults(suiteName: "settings-main-\(UUID().uuidString)")!
            let store = UsageStore(storeURL: dir.appendingPathComponent("usage.json"))
            let metering = MeteringController(store: store,
                                              journal: SuppressionJournal(url: dir.appendingPathComponent("journal.json")),
                                              suppressors: [], defaults: defaults)
            let model = MonitorViewModel(store: store, metering: metering)
            let main = MainWindowController(model: model, history: HistoryViewModel(monitor: model),
                                            connections: ConnectionsViewModel(monitor: model, defaults: defaults),
                                            ads: AdsViewModel(monitor: model))
            main.show(.settings)
            Check.expectEqual(main.window.title, "Settings")

            // From Settings' row: Connections' settings, and back to Settings.
            main.showSettings(for: .connections, from: .settings)
            Check.expectEqual(main.window.title, "Connections Settings")
            main.closeSettings()
            Check.expectEqual(main.window.title, "Settings")

            // From Connections' gear: back to Connections.
            main.show(.connections)
            main.showSettings()
            main.closeSettings()
            Check.expectEqual(main.window.title, "Connections")
        }
    }
}
