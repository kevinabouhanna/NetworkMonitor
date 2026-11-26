import AppKit
import SwiftUI
import NetworkMonitorCore

/// The popover's list keeps one height while it scrolls (#660). A lazy stack
/// guessed the height of the rows it hadn't drawn from those it had, and an
/// opened entry's rows changed the guess as the list scrolled past it: the
/// scroll bar's knob grew and shrank, and jumped.
func runPopoverScrollTests() {
    Check.suite("The popover's list while it scrolls (#660)") {
        Check.test("an opened entry keeps the list one height at every scroll position") {
            OutOfSight.startApp()
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scroll-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let defaults = Check.defaults("popover-scroll")
            let store = UsageStore(storeURL: dir.appendingPathComponent("usage.json"))
            store.setCurrentNetwork(NetworkFingerprint(id: "home", kind: .wifi, gatewayMAC: "home",
                                                       defaultLabel: "Home", isExpensive: false,
                                                       isConstrained: false))
            // Twenty apps, one of them in the middle with twelve parts of its
            // own, and fifteen daemons under System: far more than fit.
            func app(_ name: String) -> AppIdentity {
                AppIdentity(key: "/Applications/\(name).app", displayName: name,
                            bundlePath: "/Applications/\(name).app", isSystem: false)
            }
            var entries: [(identity: AppIdentity, bytesIn: Int64, bytesOut: Int64)] = []
            for i in 0..<20 { entries.append((app("App \(i)"), Int64(100_000 - i * 1_000), 0)) }
            let parent = ParentApp(key: "/Applications/App 10.app", displayName: "App 10",
                                   bundlePath: "/Applications/App 10.app")
            for i in 0..<12 {
                let part = AppIdentity(key: "/usr/libexec/part\(i)", displayName: "part \(i)",
                                       bundlePath: nil, isSystem: false)
                entries.append((AppIdentityResolver.adopted(part, by: parent), Int64(500 - i), 0))
            }
            for i in 0..<15 {
                entries.append((AppIdentity(key: "/usr/sbin/daemon\(i)", displayName: "daemon \(i)",
                                            bundlePath: nil, isSystem: true), Int64(300 - i), 0))
            }
            store.recordApps(entries)
            let metering = MeteringController(store: store,
                                              journal: SuppressionJournal(url: dir.appendingPathComponent("journal.json")),
                                              suppressors: [], defaults: defaults)
            let model = MonitorViewModel(store: store, metering: metering)
            let glance = model.glance
            let saved = (glance.period, glance.dataGrouping)
            (glance.period, glance.dataGrouping) = (.today, .apps)
            defer { (glance.period, glance.dataGrouping) = saved }
            model.setPopoverOpen(true)
            defer { model.setPopoverOpen(false) }
            // Data's list: the popover opens on Live (#802).
            model.popoverSection = .today
            // The live rows, which the list shows until History has a report.
            Check.expectNil(glance.report, "the list would show History's rows, not these")
            guard let opened = model.rows.first(where: { !$0.children.isEmpty }) else {
                Check.expectTrue(false, "no app with parts to open: \(model.rows.map(\.displayName))")
                return
            }

            let hosting = NSHostingView(rootView: MenuBarPopoverView(
                model: model, onSettings: {}, onHistory: {}, onConnections: {}, onAds: {}))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Popover scroll"
            window.contentView = hosting
            window.placeOutOfSight()
            defer { window.orderOut(nil) }
            func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }

            func scrollView(in view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView { return scroll }
                for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
                return nil
            }

            /// The list's height at the top, scrolled down past the opened
            /// entry to the end, and back up again, with the knob's size at each.
            func heights(_ state: String) -> [(y: CGFloat, height: CGFloat, knob: CGFloat)] {
                settle()
                guard let scroll = scrollView(in: hosting), let document = scroll.documentView else {
                    Check.expectTrue(false, "\(state): no scrolling list in the popover")
                    return []
                }
                let visible = scroll.contentView.bounds.height
                var seen: [(CGFloat, CGFloat, CGFloat)] = []
                let steps = 8
                let positions = (0...steps).map { CGFloat($0) / CGFloat(steps) }
                for fraction in positions + positions.reversed() {
                    let end = max(document.frame.height - visible, 0)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: (end * fraction).rounded()))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    settle()
                    seen.append((scroll.contentView.bounds.origin.y, document.frame.height,
                                 scroll.verticalScroller?.knobProportion ?? -1))
                }
                return seen
            }

            func expectSteady(_ state: String, rows: Int) {
                let seen = heights(state)
                guard let first = seen.first else { return }
                // A list with no scroll bar would pass the knob's check at
                // every position without testing it.
                Check.expectTrue(first.knob > 0 && first.knob < 1,
                                 "\(state): the knob is \(first.knob) of the bar, not a list that scrolls")
                let expected = PopoverMetrics.contentHeight(appRows: rows, expandedChildRows: 0,
                                                            systemRowCount: 0, systemExpanded: false)
                for (y, height, knob) in seen {
                    Check.expectTrue(abs(height - expected) < 1,
                                     "\(state): the list is \(height) pt tall scrolled to \(y), \(expected) with every row drawn")
                    Check.expectTrue(abs(knob - first.knob) < 0.001,
                                     "\(state): the knob is \(knob) of the bar scrolled to \(y), \(first.knob) at the top")
                }
            }

            let apps = model.rows.count
            let system = model.systemRows.count
            expectSteady("every entry closed", rows: apps + 1)
            withAnimation(nil) { model.toggleExpanded(opened.id) }
            expectSteady("\(opened.displayName) open", rows: apps + opened.children.count + 1)
            withAnimation(nil) { model.systemExpanded = true }
            defer { model.systemExpanded = false }
            expectSteady("\(opened.displayName) and System open",
                         rows: apps + opened.children.count + 1 + system)
        }
    }
}
