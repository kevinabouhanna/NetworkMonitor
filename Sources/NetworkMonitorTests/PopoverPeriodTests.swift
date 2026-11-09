import Foundation
import NetworkMonitorCore

/// The popover's period and groupings (#449).
func runPopoverPeriodTests() {
    func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2   // Monday, so week tests do not depend on locale
        return calendar
    }

    /// 2026-10-21 09:10 UTC, a Wednesday.
    let reference = Date(timeIntervalSince1970: 1_792_573_800)

    func network(_ id: String) -> NetworkFingerprint {
        NetworkFingerprint(id: id, kind: .wifi, gatewayMAC: id, defaultLabel: "Net \(id)",
                           isExpensive: false, isConstrained: false)
    }

    func app(_ name: String) -> AppIdentity {
        AppIdentity(key: name, displayName: name, bundlePath: "/Applications/\(name).app",
                    isSystem: false, parent: nil)
    }

    func defaults() -> UserDefaults {
        let name = "popover-period-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func waitForReport(_ glance: TodayGlance) {
        let deadline = Date() + 2
        while glance.report == nil && Date() < deadline { RunLoop.main.run(until: Date() + 0.01) }
    }

    Check.suite("Popover — period") {
        Check.test("the popover remembers its period and groupings") {
            let store = defaults()
            let glance = TodayGlance(history: { nil }, defaults: store)
            Check.expectEqual(glance.period, .today)
            glance.period = .month
            glance.dataGrouping = .networks
            glance.connectionsGrouping = .countries
            glance.adsGrouping = .apps
            let reopened = TodayGlance(history: { nil }, defaults: store)
            Check.expectEqual(reopened.period, .month)
            Check.expectEqual(reopened.dataGrouping, .networks)
            Check.expectEqual(reopened.connectionsGrouping, .countries)
            Check.expectEqual(reopened.adsGrouping, .apps)
        }

        Check.test("Settings' glance always reads today") {
            let glance = TodayGlance(history: { nil })
            Check.expectEqual(glance.period, .today)
        }

        Check.test("each period is the calendar one the windows show") {
            let cal = calendar()
            Check.expectEqual(PopoverPeriod.today.period(containing: reference, calendar: cal).start,
                              cal.startOfDay(for: reference))
            // Monday the 19th.
            Check.expectEqual(PopoverPeriod.week.period(containing: reference, calendar: cal).start,
                              Date(timeIntervalSince1970: 1_792_368_000))
            Check.expectEqual(PopoverPeriod.month.period(containing: reference, calendar: cal).scale, .month)
        }

        // The data total used to start over on joining a network: Today has to
        // mean since midnight on every network, as the other numbers do.
        Check.test("Data counts every network since the period began") {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("popover-period-\(UUID().uuidString).sqlite")
            defer {
                for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
            }
            let cal = calendar()
            let history = UsageHistory(databaseURL: url, calendar: cal)
            let monday = reference - 2 * 86_400
            history.join(network("A"), label: "Net A", switched: false, now: monday)
            history.recordInterface(bytesIn: 4_000, bytesOut: 0, now: monday)
            history.recordApps([(app("Xcode"), 4_000, 0)], localBytesIn: 0, localBytesOut: 0, now: monday)
            let early = reference - 3 * 3600
            history.recordInterface(bytesIn: 1_000, bytesOut: 0, now: early)
            history.recordApps([(app("Safari"), 1_000, 0)], localBytesIn: 0, localBytesOut: 0, now: early)
            history.join(network("B"), label: "Net B", switched: true, now: reference)
            history.recordInterface(bytesIn: 500, bytesOut: 0, now: reference)
            history.recordApps([(app("Mail"), 500, 0)], localBytesIn: 0, localBytesOut: 0, now: reference)

            let glance = TodayGlance(history: { history }, calendar: cal)
            glance.refresh(now: reference)
            waitForReport(glance)
            Check.expectEqual(glance.report.map { $0.bytesIn + $0.bytesOut }, 1_500)
            Check.expectEqual(Set(glance.report?.apps.map(\.displayName) ?? []), ["Safari", "Mail"])
            Check.expectEqual(glance.report?.networks.count, 2)

            // Choosing it reads the real week; read the test's own again.
            glance.period = .week
            glance.refresh(now: reference)
            let deadline = Date() + 2
            while !(glance.report.map { $0.period.scale == .week && $0.period.contains(reference) } ?? false)
                    && Date() < deadline {
                RunLoop.main.run(until: Date() + 0.01)
            }
            Check.expectEqual(glance.report.map { $0.bytesIn + $0.bytesOut }, 5_500)
        }
    }
}
