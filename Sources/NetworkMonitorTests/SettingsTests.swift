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

            // The sidebar button (#436): in every section's toolbar, and
            // answered by the window itself, so it works with nothing focused.
            for section in MainSection.allCases {
                main.show(section)
                let buttons = main.window.toolbar?.items.filter { $0.itemIdentifier.rawValue == "sidebarButton" } ?? []
                Check.expectEqual(buttons.count, 1, "\(section.rawValue) has the sidebar button")
                // AppKit's own button greyed itself out once the sidebar
                // couldn't hide away entirely; this one goes to the window.
                if let action = buttons.first?.action {
                    Check.expectTrue(main.window.responds(to: action), "\(section.rawValue): the window takes its action")
                } else {
                    Check.expectTrue(false, "\(section.rawValue): the sidebar button has an action")
                }
            }

            // Search (#436): the glass gives way to the field and comes back
            // once it's left empty; a search keeps the field.
            main.show(.connections)
            let search = main.connections.search
            Check.expectTrue(!search.isOpen, "search starts as the glass")
            search.begin()
            Check.expectTrue(search.isOpen, "⌘F opens the field")
            search.finish()
            Check.expectTrue(!search.isOpen, "left empty, it's the glass again")
            search.show("goo")
            Check.expectTrue(search.isOpen, "a search keeps the field open")
            search.finish()
            Check.expectTrue(search.isOpen, "holding a search, it doesn't close")
            search.show("")
            Check.expectTrue(!search.isOpen, "cleared, it closes")
            main.window.makeFirstResponder(nil)
            let before = main.sidebarIsCollapsed
            Check.expectTrue(NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)),
                                              to: main.window, from: nil), "the window takes toggleSidebar:")
            Check.expectTrue(main.sidebarIsCollapsed != before, "the button folds the sidebar")
            main.toggleSidebar()
            let collapsed = main.sidebarIsCollapsed
            main.toggleSidebar()
            Check.expectTrue(main.sidebarIsCollapsed != collapsed, "the sidebar folds and unfolds")
            main.toggleSidebar()

            // Search (#436): a magnifying glass until it holds a search.
            for search in [main.history.search, main.connections.search, main.ads.search] {
                Check.expectTrue(!search.isOpen, "search rests as the glass")
            }
        }

        // Day, Week, Month and Year, each segment as wide as the widest (#436).
        Check.test("the period's segments are all one width") {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("settings-period-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let defaults = UserDefaults(suiteName: "settings-period-\(UUID().uuidString)")!
            let store = UsageStore(storeURL: dir.appendingPathComponent("usage.json"))
            let model = MonitorViewModel(store: store,
                                         metering: MeteringController(
                                            store: store,
                                            journal: SuppressionJournal(url: dir.appendingPathComponent("j.json")),
                                            suppressors: [], defaults: defaults))
            let main = MainWindowController(model: model, history: HistoryViewModel(monitor: model),
                                            connections: ConnectionsViewModel(monitor: model, defaults: defaults),
                                            ads: AdsViewModel(monitor: model))
            for section in [MainSection.history, .connections, .ads] {
                main.show(section)
                let item = main.window.toolbar?.items.first { $0.itemIdentifier.rawValue == "scale" }
                guard let control = item?.view as? NSSegmentedControl else {
                    Check.expectTrue(false, "\(section.rawValue) has the period")
                    continue
                }
                let widths = (0..<control.segmentCount).map { control.width(forSegment: $0) }
                Check.expectEqual(Set(widths).count, 1, "\(section.rawValue): \(widths)")
                Check.expectTrue((widths.first ?? 0) >= 64, "\(section.rawValue): wide enough")
            }
        }
    }
}
