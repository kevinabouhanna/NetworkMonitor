import AppKit
import SwiftUI
import NetworkMonitorCore

/// Pausing ad blocking from the menu bar (#600): the popover's Ads blocked
/// bar and the right-click menu share the window's pause, one setting.
func runPauseAdsTests() {
    Check.suite("Pause ad blocking from the menu bar (#600)") {
        let office = FirewallRules.CurrentNetwork(id: "router-office", name: "Office")

        func rules(_ name: String) -> FirewallRules {
            let rules = FirewallRules(defaults: Check.defaults(name), teamOf: { _ in nil })
            rules.lists = [.ads]
            return rules
        }

        Check.test("blocking, paused until a time, or off on this network") {
            let firewall = rules("pause-600-state")
            Check.expectEqual(firewall.listsState(on: office), .blocking)
            let now = Date()
            firewall.pauseListsForAnHour(now: now)
            Check.expectEqual(firewall.listsState(on: office), .paused(until: now.addingTimeInterval(3600)))
            firewall.resumeLists(on: office)
            Check.expectEqual(firewall.listsState(on: office), .blocking)

            firewall.pauseLists(on: office, true)
            Check.expectEqual(firewall.listsState(on: office), .offHere(network: "Office"))
            Check.expectEqual(firewall.listsState(on: nil), .blocking, "off on Office, not everywhere")
            firewall.resumeLists(on: office)
            Check.expectEqual(firewall.listsState(on: office), .blocking)
        }

        Check.test("a pause for a time is said first, and Resume ends it before the network's") {
            let firewall = rules("pause-600-both")
            firewall.pauseLists(on: office, true)
            firewall.pauseListsForAnHour()
            guard case .paused = firewall.listsState(on: office) else {
                Check.expectTrue(false, "a pause for a time wasn't said first: \(firewall.listsState(on: office))")
                return
            }
            firewall.resumeLists(on: office)
            Check.expectEqual(firewall.listsState(on: office), .offHere(network: "Office"))
            firewall.resumeLists(on: office)
            Check.expectEqual(firewall.listsState(on: office), .blocking)
        }

        Check.test("Until Tomorrow ends at the start of the next day") {
            let firewall = rules("pause-600-tomorrow")
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Beirut")!
            let now = Date()
            firewall.pauseListsUntilTomorrow(calendar: calendar, now: now)
            let expected = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            Check.expectEqual(firewall.listsPausedUntil, expected)
            firewall.pauseLists(until: nil)
        }

        Check.test("the bar names everything VoiceOver reads, and Tab reaches its button") {
            OutOfSight.startApp()
            KeyboardTour.start()
            defer { KeyboardTour.stop() }
            let firewall = rules("pause-600-bar")
            let filter = FilterController()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 60),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Pause bar"
            window.contentView = NSHostingView(rootView: PopoverAdsPauseBar(firewall: firewall, filter: filter,
                                                                            network: office))
            window.placeOutOfSight()
            defer { window.orderOut(nil) }
            let symbols: Set<String> = ["pause.fill", "shield.slash", "shield.lefthalf.filled", "exclamationmark.shield"]

            for (state, button) in [("blocking", L("Pause")), ("paused", L("Resume")), ("off here", L("Turn On Here"))] {
                switch state {
                case "paused": firewall.pauseListsForAnHour()
                case "off here":
                    firewall.pauseLists(until: nil)
                    firewall.pauseLists(on: office, true)
                default: break
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                guard let problems = AccessibilityAudit.auditOwnWindow(titled: window.title, symbols: symbols) else {
                    Check.expectTrue(false, "couldn't read the bar's accessibility tree, \(state)")
                    continue
                }
                for problem in problems { Check.expectTrue(false, "\(state): \(problem.description)") }
                let outline = AccessibilityAudit.outlineOwnWindow(titled: window.title)
                Check.expectTrue(outline.contains { $0.contains("name=\(button)") },
                                 "\(state): no \(button) control in \(outline)")
                let tour = KeyboardTour.walk(window)
                for problem in KeyboardTour.problems(in: window, tour) {
                    Check.expectTrue(false, "\(state): \(problem)")
                }
            }
            firewall.resumeLists(on: office)
        }
    }
}
