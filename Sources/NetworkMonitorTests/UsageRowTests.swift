import Foundation
import NetworkMonitorCore

private func totals(_ name: String, _ bytesIn: Int64, _ bytesOut: Int64,
                    system: Bool = false) -> AppTotals {
    AppTotals(displayName: name, bundlePath: system ? nil : "/Applications/\(name).app",
              isSystem: system, bytesIn: bytesIn, bytesOut: bytesOut)
}

private func row(_ id: String, _ total: Int64, name: String? = nil) -> UsageRow {
    UsageRow(id: id, displayName: name ?? id, bytesIn: total, bytesOut: 0,
             bundlePath: nil, isSystem: false, isActive: false)
}

func runUsageRowPartitionTests() {
    Check.suite("UsageRow — partitioning a bucket") {

        Check.test("system processes are separated from real apps") {
            let result = UsageRow.partition(
                apps: ["Chrome": totals("Chrome", 500, 100),
                       "mDNSResponder": totals("mDNSResponder", 40, 10, system: true),
                       "Slack": totals("Slack", 200, 50)],
                lastActivity: [:], now: Date())

            Check.expectEqual(result.apps.map(\.id), ["Chrome", "Slack"])
            Check.expectEqual(result.system.map(\.id), ["mDNSResponder"])
        }

        // The collapsed system summary shows this number, so it must count the
        // hidden rows only — adding the visible apps in would double-count.
        Check.test("the system total counts only system rows") {
            let result = UsageRow.partition(
                apps: ["Chrome": totals("Chrome", 500, 100),
                       "mDNSResponder": totals("mDNSResponder", 40, 10, system: true),
                       "nsurlsessiond": totals("nsurlsessiond", 30, 20, system: true)],
                lastActivity: [:], now: Date())

            Check.expectEqual(result.systemTotal, 100)
            Check.expectEqual(result.system.count, 2)
        }

        Check.test("both lists are sorted biggest first") {
            let result = UsageRow.partition(
                apps: ["Small": totals("Small", 1, 1),
                       "Big": totals("Big", 900, 100),
                       "Middle": totals("Middle", 50, 50),
                       "SysBig": totals("SysBig", 80, 0, system: true),
                       "SysSmall": totals("SysSmall", 2, 0, system: true)],
                lastActivity: [:], now: Date())

            Check.expectEqual(result.apps.map(\.id), ["Big", "Middle", "Small"])
            Check.expectEqual(result.system.map(\.id), ["SysBig", "SysSmall"])
        }

        /// Dictionary iteration order is not stable between runs, so equal totals
        /// would otherwise put the list in a different order on every rebuild —
        /// visible as two rows swapping places for no reason.
        Check.test("equal totals are ordered by name, not by dictionary order") {
            let apps = ["Zulu": totals("Zulu", 100, 0),
                        "Alpha": totals("Alpha", 100, 0),
                        "Mike": totals("Mike", 100, 0)]
            for _ in 0..<20 {
                let result = UsageRow.partition(apps: apps, lastActivity: [:], now: Date())
                Check.expectEqual(result.apps.map(\.id), ["Alpha", "Mike", "Zulu"])
            }
        }

        Check.test("bytes and metadata survive the transformation") {
            let result = UsageRow.partition(
                apps: ["Chrome": totals("Chrome", 500, 100)],
                lastActivity: [:], now: Date())

            guard let chrome = result.apps.first else {
                return Check.expectNotNil(result.apps.first, "no row built")
            }
            Check.expectEqual(chrome.bytesIn, 500)
            Check.expectEqual(chrome.bytesOut, 100)
            Check.expectEqual(chrome.total, 600)
            Check.expectEqual(chrome.displayName, "Chrome")
            Check.expectEqual(chrome.bundlePath, "/Applications/Chrome.app")
            Check.expectFalse(chrome.isSystem)
        }

        Check.test("an empty bucket produces nothing rather than failing") {
            let result = UsageRow.partition(apps: [:], lastActivity: [:], now: Date())
            Check.expectTrue(result.apps.isEmpty)
            Check.expectTrue(result.system.isEmpty)
            Check.expectEqual(result.systemTotal, 0)
        }
    }

    Check.suite("UsageRow — nesting adopted processes") {

        let code = ParentApp(key: "/Applications/Visual Studio Code.app",
                             displayName: "Visual Studio Code",
                             bundlePath: "/Applications/Visual Studio Code.app")

        func child(_ name: String, _ bytes: Int64, of parent: ParentApp) -> AppTotals {
            AppTotals(displayName: name, bundlePath: nil, isSystem: false,
                      parent: parent, bytesIn: bytes, bytesOut: 0)
        }

        Check.test("an adopted process nests instead of joining the System group") {
            let result = UsageRow.partition(
                apps: [code.key: totals("Visual Studio Code", 20, 0),
                       "vscode\u{1}claude": child("claude", 900, of: code)],
                lastActivity: [:], now: Date())

            Check.expectTrue(result.system.isEmpty, "a child must never be filed as a daemon")
            Check.expectEqual(result.apps.count, 1)
            Check.expectEqual(result.apps.first?.children.map(\.displayName), ["claude"])
        }

        /// The rows on screen have to add up to the headline, so a parent shows
        /// its own bytes plus everything it launched.
        Check.test("the parent total combines its own bytes with its children's") {
            let result = UsageRow.partition(
                apps: [code.key: totals("Visual Studio Code", 20, 5),
                       "vscode\u{1}claude": child("claude", 900, of: code),
                       "vscode\u{1}node": child("node", 75, of: code)],
                lastActivity: [:], now: Date())

            guard let parent = result.apps.first else {
                return Check.expectNotNil(result.apps.first, "no parent row built")
            }
            Check.expectEqual(parent.ownTotal, 25)
            Check.expectEqual(parent.total, 1000)
            Check.expectEqual(parent.children.map(\.displayName), ["claude", "node"])
        }

        /// A terminal whose only traffic is the dev server it started has no row
        /// of its own; without synthesising one the child has nowhere to nest.
        Check.test("a parent with no traffic of its own still gets a row") {
            let result = UsageRow.partition(
                apps: ["vscode\u{1}claude": child("claude", 900, of: code)],
                lastActivity: [:], now: Date())

            Check.expectEqual(result.apps.map(\.displayName), ["Visual Studio Code"])
            Check.expectEqual(result.apps.first?.ownTotal, 0)
            Check.expectEqual(result.apps.first?.total, 900)
            Check.expectEqual(result.apps.first?.bundlePath,
                              "/Applications/Visual Studio Code.app")
        }

        /// Sorting compares combined totals, so an app that is small on its own
        /// but launched something large must not sink to the bottom.
        Check.test("parents sort by their combined total") {
            let result = UsageRow.partition(
                apps: [code.key: totals("Visual Studio Code", 1, 0),
                       "vscode\u{1}claude": child("claude", 900, of: code),
                       "Chrome": totals("Chrome", 500, 0)],
                lastActivity: [:], now: Date())

            Check.expectEqual(result.apps.map(\.displayName), ["Visual Studio Code", "Chrome"])
        }

        Check.test("an app with no children reports none") {
            let result = UsageRow.partition(apps: ["Chrome": totals("Chrome", 500, 0)],
                                            lastActivity: [:], now: Date())
            Check.expectFalse(result.apps.first?.hasChildren ?? true)
        }

        // The dot answers "is this app on the network"; a process it launched
        // counts, and the child is hidden behind a closed chevron by default.
        Check.test("a busy child lights the parent's active dot") {
            let now = Date()
            let result = UsageRow.partition(
                apps: [code.key: totals("Visual Studio Code", 20, 0),
                       "vscode\u{1}claude": child("claude", 900, of: code)],
                lastActivity: ["vscode\u{1}claude": now], now: now)

            Check.expectTrue(result.apps.first?.isActive ?? false)
        }

        /// The breakdown is a summary, not a process list. A build tool that
        /// launches a dozen helpers must not turn one row into a wall of them.
        Check.test("a long tail of children is rolled up into one Other row") {
            var apps: [String: AppTotals] = [:]
            for i in 1...10 { apps["vscode\u{1}p\(i)"] = child("p\(i)", Int64(i) * 100, of: code) }
            let result = UsageRow.partition(apps: apps, lastActivity: [:], now: Date())

            guard let parent = result.apps.first else {
                return Check.expectNotNil(result.apps.first, "no parent row built")
            }
            Check.expectEqual(parent.children.count, UsageRow.maxChildrenShown)
            Check.expectEqual(parent.children.map(\.displayName),
                              ["p10", "p9", "p8", "Other (7)"])
        }

        /// Rolling up must summarise, never discard — the children still have to
        /// add up to the parent, or the list stops reconciling with the headline.
        Check.test("the rolled-up total is preserved exactly") {
            var apps: [String: AppTotals] = [:]
            for i in 1...10 { apps["vscode\u{1}p\(i)"] = child("p\(i)", Int64(i) * 100, of: code) }
            let result = UsageRow.partition(apps: apps, lastActivity: [:], now: Date())

            // 100 + 200 + … + 1000
            Check.expectEqual(result.apps.first?.total, 5500)
            Check.expectEqual(result.apps.first?.children.last?.total, 5500 - 1000 - 900 - 800)
        }

        Check.test("a short list is left alone rather than rolled up") {
            var apps: [String: AppTotals] = [:]
            for i in 1...UsageRow.maxChildrenShown {
                apps["vscode\u{1}p\(i)"] = child("p\(i)", Int64(i) * 100, of: code)
            }
            let result = UsageRow.partition(apps: apps, lastActivity: [:], now: Date())
            Check.expectEqual(result.apps.first?.children.count, UsageRow.maxChildrenShown)
            Check.expectFalse(
                result.apps.first?.children.contains { $0.displayName.hasPrefix("Other") } ?? true,
                "nothing to roll up at exactly the cap")
        }

        Check.test("children are sorted biggest first") {
            let result = UsageRow.partition(
                apps: ["vscode\u{1}small": child("small", 5, of: code),
                       "vscode\u{1}big": child("big", 900, of: code),
                       "vscode\u{1}mid": child("mid", 50, of: code)],
                lastActivity: [:], now: Date())

            Check.expectEqual(result.apps.first?.children.map(\.displayName),
                              ["big", "mid", "small"])
        }
    }

    Check.suite("UsageRow — the active-now dot") {

        let now = Date()

        Check.test("an app that moved bytes just now is active") {
            let result = UsageRow.partition(
                apps: ["Chrome": totals("Chrome", 500, 100)],
                lastActivity: ["Chrome": now.addingTimeInterval(-0.5)], now: now)
            Check.expectTrue(result.apps.first?.isActive ?? false)
        }

        Check.test("an app that has gone quiet is not active") {
            let result = UsageRow.partition(
                apps: ["Chrome": totals("Chrome", 500, 100)],
                lastActivity: ["Chrome": now.addingTimeInterval(-30)], now: now)
            Check.expectFalse(result.apps.first?.isActive ?? true)
        }

        /// The boundary is where an off-by-one would leave the dot stuck on.
        Check.test("the window ends exactly where it says it does") {
            let justInside = now.addingTimeInterval(-(UsageRow.activityWindow - 0.1))
            let justOutside = now.addingTimeInterval(-(UsageRow.activityWindow + 0.1))

            let inside = UsageRow.partition(apps: ["A": totals("A", 1, 0)],
                                            lastActivity: ["A": justInside], now: now)
            let outside = UsageRow.partition(apps: ["A": totals("A", 1, 0)],
                                             lastActivity: ["A": justOutside], now: now)
            Check.expectTrue(inside.apps.first?.isActive ?? false, "just inside the window")
            Check.expectFalse(outside.apps.first?.isActive ?? true, "just outside the window")
        }

        // An app with a day total but no traffic this second — the common case
        // for most rows in the list.
        Check.test("an app with no activity record is not active") {
            let result = UsageRow.partition(
                apps: ["Chrome": totals("Chrome", 500, 100)],
                lastActivity: [:], now: now)
            Check.expectFalse(result.apps.first?.isActive ?? true)
        }

        Check.test("activity is tracked per app, not shared") {
            let result = UsageRow.partition(
                apps: ["Chrome": totals("Chrome", 500, 0),
                       "Slack": totals("Slack", 400, 0)],
                lastActivity: ["Chrome": now], now: now)
            Check.expectTrue(result.apps.first { $0.id == "Chrome" }?.isActive ?? false)
            Check.expectFalse(result.apps.first { $0.id == "Slack" }?.isActive ?? true)
        }
    }
}

func runRowOrderTests() {
    Check.suite("RowOrder — frozen while the popover is open") {

        Check.test("the first pass sorts biggest first") {
            var order = RowOrder()
            let result = order.apply(to: [row("b", 50), row("a", 900), row("c", 100)])
            Check.expectEqual(result.map(\.id), ["a", "c", "b"])
        }

        /// The whole point. Without this, a row you are reaching for slides away
        /// as another app overtakes it mid-click.
        Check.test("a row overtaking another does not move") {
            var order = RowOrder()
            _ = order.apply(to: [row("a", 900), row("c", 100), row("b", 50)])

            // "b" balloons past both others; the displayed order must not change.
            let after = order.apply(to: [row("a", 900), row("c", 100), row("b", 5000)])
            Check.expectEqual(after.map(\.id), ["a", "c", "b"])
        }

        Check.test("a row appearing later is appended, not slotted in") {
            var order = RowOrder()
            _ = order.apply(to: [row("a", 900), row("b", 100)])

            // Big enough to sort first, but it must not push the others down.
            let after = order.apply(to: [row("a", 900), row("b", 100), row("new", 99_999)])
            Check.expectEqual(after.map(\.id), ["a", "b", "new"])
        }

        Check.test("several new rows are appended in size order") {
            var order = RowOrder()
            _ = order.apply(to: [row("a", 900)])
            let after = order.apply(to: [row("a", 900), row("small", 10), row("large", 500)])
            Check.expectEqual(after.map(\.id), ["a", "large", "small"])
        }

        /// Once appended, a new row has been drawn on screen — so from the next
        /// rebuild on it is subject to the same freeze as everything else.
        Check.test("an appended row keeps its slot afterwards") {
            var order = RowOrder()
            _ = order.apply(to: [row("a", 900), row("b", 100)])
            _ = order.apply(to: [row("a", 900), row("b", 100), row("new", 10)])

            let after = order.apply(to: [row("a", 900), row("b", 100), row("new", 99_999)])
            Check.expectEqual(after.map(\.id), ["a", "b", "new"])
        }

        Check.test("a row disappearing leaves the survivors in order") {
            var order = RowOrder()
            _ = order.apply(to: [row("a", 900), row("b", 500), row("c", 100)])
            let after = order.apply(to: [row("a", 900), row("c", 100)])
            Check.expectEqual(after.map(\.id), ["a", "c"])
        }

        /// Closing and reopening the popover is when a re-sort is expected and
        /// wanted — nothing is under the pointer at that moment.
        Check.test("reset re-sorts by size again") {
            var order = RowOrder()
            _ = order.apply(to: [row("a", 900), row("b", 50)])
            order.reset()

            let after = order.apply(to: [row("a", 900), row("b", 5000)])
            Check.expectEqual(after.map(\.id), ["b", "a"])
        }

        Check.test("repeated passes with unchanged input are stable") {
            var order = RowOrder()
            let rows = [row("a", 900), row("b", 500), row("c", 100)]
            let first = order.apply(to: rows)
            for _ in 0..<10 {
                Check.expectEqual(order.apply(to: rows).map(\.id), first.map(\.id))
            }
        }

        Check.test("an empty list is handled") {
            var order = RowOrder()
            Check.expectTrue(order.apply(to: []).isEmpty)
            Check.expectEqual(order.apply(to: [row("a", 1)]).map(\.id), ["a"])
        }

        // A fresh RowOrder must not inherit anything from another instance.
        Check.test("two orders are independent") {
            var first = RowOrder()
            var second = RowOrder()
            _ = first.apply(to: [row("a", 10), row("b", 900)])
            let result = second.apply(to: [row("a", 10), row("b", 900)])
            Check.expectEqual(result.map(\.id), ["b", "a"])
        }
    }
}
