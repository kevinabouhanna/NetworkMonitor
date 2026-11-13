import AppKit
import SwiftUI
import NetworkMonitorCore

/// The popover is one height in each of its four views (#599): sized to each,
/// it jumped as it moved from Data, Connections or Ads blocked to Network and
/// back, `NSPopover` re-anchoring to every new size.
func runPopoverHeightTests() {
    Check.suite("The popover's height (#599)") {
        Check.test("one height under the header, however many rows the lists have") {
            for rows in [0, 1, 3, 6, 25, 500] {
                Check.expectEqual(PopoverMetrics.sectionAreaHeight(rows: rows),
                                  PopoverMetrics.sectionChrome
                                      + max(PopoverMetrics.listHeight(appRows: rows, expandedChildRows: 0,
                                                                      systemRowCount: 0, systemExpanded: false),
                                            PopoverMetrics.sectionHeight),
                                  "\(rows) rows")
            }
            // Never shorter than a message in place of the list, nor taller
            // than the cap.
            Check.expectEqual(PopoverMetrics.sectionAreaHeight(rows: 0),
                              PopoverMetrics.sectionChrome + PopoverMetrics.sectionHeight)
            Check.expectEqual(PopoverMetrics.sectionAreaHeight(rows: 500),
                              PopoverMetrics.sectionChrome + PopoverMetrics.maxListHeight)
        }

        Check.test("the speed test's card always fits") {
            for rows in [0, 3, 500] {
                Check.expectTrue(PopoverMetrics.sectionAreaHeight(rows: rows, speedCard: true)
                                     >= PopoverMetrics.speedCardHeight, "\(rows) rows")
            }
            Check.expectEqual(PopoverMetrics.sectionAreaHeight(rows: 500, speedCard: true),
                              PopoverMetrics.sectionAreaHeight(rows: 500),
                              "a full list already has room for the card")
        }

        Check.test("Data, Connections, Ads blocked and Network lay out at one height") {
            OutOfSight.startApp()
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("height-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let defaults = Check.defaults("popover-height")
            let store = UsageStore(storeURL: dir.appendingPathComponent("usage.json"))
            let metering = MeteringController(store: store,
                                              journal: SuppressionJournal(url: dir.appendingPathComponent("journal.json")),
                                              suppressors: [], defaults: defaults)
            let model = MonitorViewModel(store: store, metering: metering)
            let hosting = NSHostingView(rootView: MenuBarPopoverView(
                model: model, onSettings: {}, onHistory: {}, onConnections: {}, onAds: {}))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Popover height"
            window.contentView = hosting
            window.placeOutOfSight()
            defer { window.orderOut(nil) }

            func height(_ section: PopoverSection) -> CGFloat {
                model.popoverSection = section
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                return hosting.fittingSize.height
            }
            // With no data: a message in each list's place, where the views
            // differed most.
            let heights = PopoverSection.allCases.map { ($0, height($0)) }
            let first = heights[0].1
            // Measured, not assumed: the header sits above the views' height.
            Check.expectTrue(first > PopoverMetrics.sectionAreaHeight(rows: 0),
                             "the popover measured \(first) pt, less than its views alone")
            for (section, value) in heights {
                Check.expectTrue(abs(value - first) < 0.5,
                                 "\(section.rawValue) is \(value) pt tall, \(heights[0].0.rawValue) \(first)")
            }
            model.popoverSection = .today
        }
    }
}
