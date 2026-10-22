import Foundation
import NetworkMonitorCore

func runUsageHistoryTests() {
    func temporaryURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("history-test-\(UUID().uuidString).sqlite")
    }

    func remove(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    func calendar(_ zone: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.firstWeekday = 2   // Monday, so week tests do not depend on locale
        return calendar
    }

    /// 2026-10-21 09:10 UTC, a Wednesday.
    let reference = Date(timeIntervalSince1970: 1_792_573_800)

    func network(_ id: String, kind: NetworkFingerprint.Kind = .wifi) -> NetworkFingerprint {
        NetworkFingerprint(id: id, kind: kind, gatewayMAC: id, defaultLabel: "Net \(id)",
                           isExpensive: kind == .hotspot, isConstrained: false)
    }

    func app(_ name: String, parent: String? = nil, isSystem: Bool = false) -> AppIdentity {
        AppIdentity(key: name, displayName: name,
                    bundlePath: isSystem || parent != nil ? nil : "/Applications/\(name).app",
                    isSystem: isSystem,
                    parent: parent.map { ParentApp(key: $0, displayName: $0,
                                                   bundlePath: "/Applications/\($0).app") })
    }

    func day(_ date: Date, _ calendar: Calendar) -> HistoryPeriod {
        HistoryPeriod(scale: .day, containing: date, calendar: calendar)
    }

    Check.suite("UsageHistory — recording") {

        // The figure the popover shows: the kernel's count, less what nettop
        // proved stayed on the LAN, clamped to what the app rows account for.
        Check.test("an hour reads back as the same internet figure the popover shows") {
            let url = temporaryURL(); defer { remove(url) }
            let cal = calendar()
            let history = UsageHistory(databaseURL: url, calendar: cal)
            history.join(network("A"), label: "Net A", switched: false, now: reference)
            history.recordInterface(bytesIn: 1_000, bytesOut: 200, now: reference)
            history.recordApps([(app("Safari"), 600, 100)],
                               localBytesIn: 300, localBytesOut: 50, now: reference)

            let report = history.report(for: day(reference, cal))
            Check.expectEqual(report.bytesIn, 700)
            Check.expectEqual(report.bytesOut, 150)
            Check.expectEqual(report.apps.map(\.displayName), ["Safari"])
            Check.expectEqual(report.apps.first?.total, 700)
        }

        // A mirrored screen is LAN, and must not turn into a day of internet.
        Check.test("LAN-only traffic never counts") {
            let url = temporaryURL(); defer { remove(url) }
            let cal = calendar()
            let history = UsageHistory(databaseURL: url, calendar: cal)
            history.join(network("A"), label: "Net A", switched: false, now: reference)
            history.recordInterface(bytesIn: 5_000, bytesOut: 5_000, now: reference)
            history.recordApps([], localBytesIn: 5_000, localBytesOut: 5_000, now: reference)
            Check.expectEqual(history.report(for: day(reference, cal)).total, 0)
        }

        Check.test("traffic lands in the hour it happened") {
            let url = temporaryURL(); defer { remove(url) }
            let cal = calendar()
            let history = UsageHistory(databaseURL: url, calendar: cal)
            history.join(network("A"), label: "Net A", switched: false, now: reference)
            history.recordInterface(bytesIn: 100, bytesOut: 0, now: reference)               // 09:10
            history.recordInterface(bytesIn: 40, bytesOut: 0, now: reference + 5 * 60)       // 09:15
            history.recordInterface(bytesIn: 7, bytesOut: 0, now: reference + 20 * 60)      // 09:30

            let report = history.report(for: day(reference, cal))
            Check.expectEqual(report.bins.count, 24)
            Check.expectEqual(report.bins[9].total, 147)
            Check.expectEqual(report.bins.filter { $0.total > 0 }.count, 1)
            Check.expectEqual(report.peakBin, 147)
        }

        Check.test("a week's bars are its days, Monday first") {
            let url = temporaryURL(); defer { remove(url) }
            let cal = calendar()
            let history = UsageHistory(databaseURL: url, calendar: cal)
            history.join(network("A"), label: "Net A", switched: false, now: reference)
            history.recordInterface(bytesIn: 10, bytesOut: 0, now: reference)
            history.recordInterface(bytesIn: 20, bytesOut: 0, now: reference + 10 * 60)

            let report = history.report(for: HistoryPeriod(scale: .week, containing: reference,
                                                           calendar: cal))
            Check.expectEqual(report.bins.count, 7)
            Check.expectEqual(cal.component(.weekday, from: report.bins[0].interval.start), 2)
            Check.expectEqual(report.bins[2].total, 30, "Wednesday")
        }

        Check.test("what was written survives a relaunch") {
            let url = temporaryURL(); defer { remove(url) }
            let cal = calendar()
            do {
                let history = UsageHistory(databaseURL: url, calendar: cal)
                history.join(network("A"), label: "Net A", switched: false, now: reference)
                history.recordInterface(bytesIn: 900, bytesOut: 100, now: reference)
                history.recordApps([(app("Mail"), 900, 100)], now: reference)
                history.flush()
            }
            let reopened = UsageHistory(databaseURL: url, calendar: cal)
            let report = reopened.report(for: day(reference, cal))
            Check.expectEqual(report.total, 1_000)
            Check.expectEqual(report.apps.first?.displayName, "Mail")
            Check.expectEqual(report.recordingSince,
                              cal.dateInterval(of: .hour, for: reference)?.start)
        }

        Check.test("an unreadable file is moved aside, not deleted") {
            let url = temporaryURL(); defer { remove(url) }
            try? Data("not a database".utf8).write(to: url)
            let history = UsageHistory(databaseURL: url, calendar: calendar())
            Check.expectTrue(history.isAvailable)
            let directory = url.deletingLastPathComponent()
            let stem = url.deletingPathExtension().lastPathComponent
            let aside = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
                .filter { $0.hasPrefix(stem + ".unreadable-") } ?? []
            Check.expectEqual(aside.count, 1)
            for name in aside {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    Check.suite("UsageHistory — sessions") {

        Check.test("joining a different network starts a new session") {
            let url = temporaryURL(); defer { remove(url) }
            let cal = calendar()
            let history = UsageHistory(databaseURL: url, calendar: cal)
            history.join(network("A"), label: "Net A", switched: false, now: reference)
            history.recordInterface(bytesIn: 100, bytesOut: 0, now: reference)
            history.join(network("B", kind: .hotspot), label: "Net B", switched: true,
                         now: reference + 60)
            history.recordInterface(bytesIn: 30, bytesOut: 0, now: reference + 61)

            let report = history.report(for: day(reference, cal))
            Check.expectEqual(report.sessions.map(\.session.networkID), ["B", "A"])
            Check.expectEqual(report.sessions.map(\.bytes), [30, 100])
            Check.expectEqual(report.byKind[.wifi], 100)
            Check.expectEqual(report.byKind[.hotspot], 30)
            Check.expectEqual(report.networks.map(\.id), ["A", "B"])
        }

        // Offline is a gap, not a place — the store's rule, §4.2.
        Check.test("an offline blip and a rejoin continue the same session") {
            let url = temporaryURL(); defer { remove(url) }
            let cal = calendar()
            let history = UsageHistory(databaseURL: url, calendar: cal)
            history.join(network("A"), label: "Net A", switched: false, now: reference)
            history.recordInterface(bytesIn: 100, bytesOut: 0, now: reference)
            history.join(.offline, label: "No Connection", switched: false, now: reference + 10)
            history.recordInterface(bytesIn: 5, bytesOut: 0, now: reference + 11)
            history.join(network("A"), label: "Net A", switched: false, now: reference + 20)
            history.recordInterface(bytesIn: 50, bytesOut: 0, now: reference + 21)

            let report = history.report(for: day(reference, cal))
            Check.expectEqual(report.sessions.count, 1)
            Check.expectEqual(report.sessions.first?.bytes, 155)
        }

        // A lid closed for lunch and opened on the same hotspot is a new visit.
        Check.test("a long silence makes the next traffic a new visit") {
            let url = temporaryURL(); defer { remove(url) }
            let cal = calendar()
            let history = UsageHistory(databaseURL: url, calendar: cal)
            history.join(network("A"), label: "Net A", switched: false, now: reference)
            history.recordInterface(bytesIn: 100, bytesOut: 0, now: reference)
            history.recordInterface(bytesIn: 20, bytesOut: 0, now: reference + 31 * 60)

            let sessions = history.report(for: day(reference, cal)).sessions
            Check.expectEqual(sessions.count, 2)
            Check.expectEqual(sessions.map(\.session.networkID), ["A", "A"])
            Check.expectEqual(sessions.map(\.bytes), [20, 100])
        }

        // Woken somewhere new: the first packets arrive before the path monitor
        // names the network, and belong to the network it then names.
        Check.test("a visit opened by traffic adopts the network joined right after") {
            let url = temporaryURL(); defer { remove(url) }
            let cal = calendar()
            let history = UsageHistory(databaseURL: url, calendar: cal)
            history.join(network("A"), label: "Net A", switched: false, now: reference)
            history.recordInterface(bytesIn: 100, bytesOut: 0, now: reference)
            let wake = reference + 2 * 3600
            history.recordInterface(bytesIn: 7, bytesOut: 0, now: wake)
            history.join(network("B"), label: "Net B", switched: true, now: wake + 3)
            history.recordInterface(bytesIn: 3, bytesOut: 0, now: wake + 4)

            let sessions = history.report(for: day(reference, cal)).sessions
            Check.expectEqual(sessions.map(\.session.networkID), ["B", "A"])
            Check.expectEqual(sessions.map(\.bytes), [10, 100])
        }

        Check.test("adoption is only for the first moments of a visit") {
            let url = temporaryURL(); defer { remove(url) }
            let cal = calendar()
            let history = UsageHistory(databaseURL: url, calendar: cal)
            history.join(network("A"), label: "Net A", switched: false, now: reference)
            history.recordInterface(bytesIn: 100, bytesOut: 0, now: reference)
            let wake = reference + 2 * 3600
            history.recordInterface(bytesIn: 7, bytesOut: 0, now: wake)
            history.join(network("B"), label: "Net B", switched: true, now: wake + 120)

            let sessions = history.report(for: day(reference, cal)).sessions
            Check.expectEqual(sessions.map(\.session.networkID), ["A", "A"])
        }

        Check.test("a relaunch on the same network continues the session") {
            let url = temporaryURL(); defer { remove(url) }
            let cal = calendar()
            do {
                let history = UsageHistory(databaseURL: url, calendar: cal)
                history.join(network("A"), label: "Net A", switched: false, now: reference)
                history.recordInterface(bytesIn: 100, bytesOut: 0, now: reference)
                history.flush()
            }
            let relaunched = UsageHistory(databaseURL: url, calendar: cal)
            // Traffic during the path monitor's debounce, then the network.
            relaunched.recordInterface(bytesIn: 1, bytesOut: 0, now: reference + 300)
            relaunched.join(network("A"), label: "Net A", switched: false, now: reference + 302)
            relaunched.recordInterface(bytesIn: 9, bytesOut: 0, now: reference + 303)

            let sessions = relaunched.report(for: day(reference, cal)).sessions
            Check.expectEqual(sessions.count, 1)
            Check.expectEqual(sessions.first?.bytes, 110)
        }

        Check.test("a session ends at its last traffic, not at the next join") {
            let url = temporaryURL(); defer { remove(url) }
            let cal = calendar()
            let history = UsageHistory(databaseURL: url, calendar: cal)
            history.join(network("A"), label: "Net A", switched: false, now: reference)
            history.recordInterface(bytesIn: 1, bytesOut: 0, now: reference + 600)
            history.join(network("B"), label: "Net B", switched: true, now: reference + 1_200)

            let a = history.report(for: day(reference, cal)).sessions.first?.session
            Check.expectEqual(a?.start, reference)
            Check.expectEqual(a?.end, reference + 600)
        }

        // The store reports the new network before metering re-evaluates, so at
        // the moment of the join the verdict still describes the session ending.
        Check.test("each session keeps the metered verdict of its own network") {
            let url = temporaryURL(); defer { remove(url) }
            let cal = calendar()
            let history = UsageHistory(databaseURL: url, calendar: cal)
            var metered = true
            history.isMetered = { metered }
            history.join(network("H", kind: .hotspot), label: "Hotspot", switched: false,
                         now: reference)
            history.recordInterface(bytesIn: 500, bytesOut: 0, now: reference)
            history.join(network("W"), label: "Wi-Fi", switched: true, now: reference + 60)
            metered = false
            history.recordInterface(bytesIn: 80, bytesOut: 0, now: reference + 61)

            let report = history.report(for: day(reference, cal))
            Check.expectEqual(report.meteredBytes, 500)
            Check.expectEqual(report.sessions.map(\.session.isMetered), [false, true])
            Check.expectEqual(report.networks.first { $0.id == "H" }?.isMetered, true)
        }
    }

    Check.suite("UsageHistory — filters") {

        /// Two networks, two apps, one of which launched a child.
        func populated(_ url: URL, _ cal: Calendar) -> UsageHistory {
            let history = UsageHistory(databaseURL: url, calendar: cal)
            var metered = false
            history.isMetered = { metered }
            history.join(network("A"), label: "Net A", switched: false, now: reference)
            history.recordInterface(bytesIn: 1_000, bytesOut: 0, now: reference)
            history.recordApps([(app("Terminal"), 100, 0),
                                (app("node", parent: "Terminal"), 300, 0),
                                (app("Safari"), 600, 0)], now: reference)
            // In the order the app sees them: the store joins the hotspot, then
            // metering re-evaluates.
            history.join(network("B", kind: .hotspot), label: "Net B", switched: true,
                         now: reference + 60)
            metered = true
            history.recordInterface(bytesIn: 50, bytesOut: 0, now: reference + 61)
            history.recordApps([(app("Safari"), 50, 0)], now: reference + 61)
            history.flush()
            return history
        }

        Check.test("a network filter narrows everything to that network") {
            let url = temporaryURL(); defer { remove(url) }
            let cal = calendar()
            let report = populated(url, cal).report(for: day(reference, cal),
                                                    filter: HistoryFilter(networkID: "B"))
            Check.expectEqual(report.total, 50)
            Check.expectEqual(report.apps.map(\.displayName), ["Safari"])
            Check.expectEqual(report.sessions.count, 1)
        }

        Check.test("an app filter counts the app and everything it launched") {
            let url = temporaryURL(); defer { remove(url) }
            let cal = calendar()
            let report = populated(url, cal).report(for: day(reference, cal),
                                                    filter: HistoryFilter(appKey: "Terminal"))
            Check.expectEqual(report.total, 400)
            Check.expectEqual(report.apps.map(\.displayName), ["Terminal"])
            Check.expectEqual(report.apps.first?.children.map(\.displayName), ["node"])
            Check.expectEqual(report.bins[9].total, 400)
        }

        Check.test("an app filter splits that app's bytes by network") {
            let url = temporaryURL(); defer { remove(url) }
            let cal = calendar()
            let report = populated(url, cal).report(for: day(reference, cal),
                                                    filter: HistoryFilter(appKey: "Safari"))
            Check.expectEqual(report.total, 650)
            Check.expectEqual(report.networks.map(\.bytes), [600, 50])
        }

        Check.test("metered only keeps the metered sessions") {
            let url = temporaryURL(); defer { remove(url) }
            let cal = calendar()
            let report = populated(url, cal).report(for: day(reference, cal),
                                                    filter: HistoryFilter(meteredOnly: true))
            Check.expectEqual(report.total, 50)
            Check.expectEqual(report.networks.map(\.id), ["B"])
        }

        Check.test("a session filter is that one visit") {
            let url = temporaryURL(); defer { remove(url) }
            let cal = calendar()
            let history = populated(url, cal)
            let all = history.report(for: day(reference, cal))
            let first = all.sessions.last!.session
            let report = history.report(for: day(reference, cal),
                                        filter: HistoryFilter(sessionID: first.id))
            Check.expectEqual(report.total, 1_000)
            Check.expectEqual(report.apps.map(\.displayName), ["Safari", "Terminal"])
        }

        Check.test("app rows nest children and group system processes as the popover does") {
            let url = temporaryURL(); defer { remove(url) }
            let cal = calendar()
            let history = UsageHistory(databaseURL: url, calendar: cal)
            history.join(network("A"), label: "Net A", switched: false, now: reference)
            history.recordInterface(bytesIn: 1_000, bytesOut: 0, now: reference)
            history.recordApps([(app("mDNSResponder", isSystem: true), 200, 0),
                                (app("Code"), 10, 0),
                                (app("claude", parent: "Code"), 90, 0)], now: reference)
            let report = history.report(for: day(reference, cal))
            Check.expectEqual(report.apps.map(\.displayName), ["Code"])
            Check.expectEqual(report.apps.first?.total, 100)
            Check.expectEqual(report.systemRows.map(\.displayName), ["mDNSResponder"])
            Check.expectEqual(report.systemTotal, 200)
        }
    }

    Check.suite("UsageHistory — retention, clearing, export") {

        Check.test("retention deletes what is older than the window, and nothing newer") {
            let url = temporaryURL(); defer { remove(url) }
            let cal = calendar()
            let now = Date()
            let history = UsageHistory(databaseURL: url, calendar: cal)
            history.retention = .oneMonth
            let old = now - 40 * 86_400, recent = now - 2 * 86_400
            history.join(network("A"), label: "Net A", switched: false, now: old)
            history.recordInterface(bytesIn: 111, bytesOut: 0, now: old)
            history.recordApps([(app("Old"), 111, 0)], now: old)
            history.join(network("B"), label: "Net B", switched: true, now: recent)
            history.recordInterface(bytesIn: 222, bytesOut: 0, now: recent)
            history.flush(now: old)
            history.prune(now: now)

            let year = HistoryPeriod(scale: .year, containing: now, calendar: cal)
            let lastYear = year.shifted(by: -1, calendar: cal)
            let total = history.report(for: year).total + history.report(for: lastYear).total
            Check.expectEqual(total, 222)
            Check.expectEqual(history.report(for: year).apps.count, 0)
        }

        Check.test("clearing deletes everything, and the current visit carries on") {
            let url = temporaryURL(); defer { remove(url) }
            let cal = calendar()
            let history = UsageHistory(databaseURL: url, calendar: cal)
            history.join(network("A"), label: "Net A", switched: false, now: reference)
            history.recordInterface(bytesIn: 500, bytesOut: 0, now: reference)
            history.flush()
            history.clear(now: reference + 60)
            Check.expectEqual(history.report(for: day(reference, cal)).total, 0)
            Check.expectNil(history.report(for: day(reference, cal)).recordingSince)

            history.recordInterface(bytesIn: 9, bytesOut: 0, now: reference + 61)
            let report = history.report(for: day(reference, cal))
            Check.expectEqual(report.total, 9)
            Check.expectEqual(report.sessions.first?.session.start, reference + 60)
            Check.expectEqual(report.sessions.first?.session.networkID, "A")
        }

        Check.test("CSV adds up to the window's total, with the unattributed rest") {
            let url = temporaryURL(); defer { remove(url) }
            let cal = calendar()
            let history = UsageHistory(databaseURL: url, calendar: cal)
            history.join(network("A"), label: "Net A", switched: false, now: reference)
            history.recordInterface(bytesIn: 1_000, bytesOut: 100, now: reference)
            history.recordApps([(app("Safari"), 600, 60), (app("Mail, Calendar"), 100, 10)],
                               now: reference)
            let csv = history.exportCSV(for: day(reference, cal),
                                        networkName: { $0 == "A" ? "Home" : nil })
            let lines = csv.split(separator: "\n").map(String.init)
            Check.expectEqual(lines.count, 4)
            Check.expectEqual(lines[0],
                              "Hour,Network,Network Type,Metered,App,Downloaded (bytes),Uploaded (bytes)")
            Check.expectEqual(lines[1], "2026-10-21 09:00,Home,Wi-Fi,No,Safari,600,60")
            Check.expectEqual(lines[2], "2026-10-21 09:00,Home,Wi-Fi,No,\"Mail, Calendar\",100,10")
            Check.expectEqual(lines[3], "2026-10-21 09:00,Home,Wi-Fi,No,Not attributed to an app,300,30")
        }

        Check.test("CSV quotes only what needs quoting") {
            Check.expectEqual(UsageHistory.csvField("Safari"), "Safari")
            Check.expectEqual(UsageHistory.csvField("a,b"), "\"a,b\"")
            Check.expectEqual(UsageHistory.csvField("say \"hi\""), "\"say \"\"hi\"\"\"")
        }
    }

    Check.suite("UsageStore → history") {

        Check.test("the store forwards every byte and every network change") {
            let historyURL = temporaryURL(); defer { remove(historyURL) }
            let storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("usage-history-test-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: storeURL) }
            let history = UsageHistory(databaseURL: historyURL)
            let store = UsageStore(storeURL: storeURL, history: history)
            let now = Date()

            store.setCurrentNetwork(network("A"), now: now)
            store.recordInterface(bytesIn: 400, bytesOut: 40, now: now)
            store.recordApps([(app("Safari"), 400, 40)], now: now)
            store.setCurrentNetwork(network("B"), now: now + 1)
            store.recordInterface(bytesIn: 10, bytesOut: 0, now: now + 2)
            store.save()

            let report = history.report(for: HistoryPeriod(scale: .day, containing: now))
            Check.expectEqual(report.total, 450)
            Check.expectEqual(report.sessions.count, 2)
            // Reset Now clears the counter, never the history.
            store.resetCurrentNetwork(now: now + 3)
            Check.expectEqual(history.report(for: HistoryPeriod(scale: .day, containing: now)).total,
                              450)
        }
    }

    Check.suite("HistoryPeriod") {

        Check.test("a day has 24 hourly bars, 23 and 25 at the daylight saving changes") {
            let york = calendar("America/New_York")
            let ordinary = york.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))!
            let spring = york.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
            let autumn = york.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!
            Check.expectEqual(day(ordinary, york).bins(calendar: york).count, 24)
            Check.expectEqual(day(spring, york).bins(calendar: york).count, 23)
            Check.expectEqual(day(autumn, york).bins(calendar: york).count, 25)
        }

        Check.test("months have a bar per day, years a bar per month") {
            let cal = calendar()
            let february = cal.date(from: DateComponents(year: 2026, month: 2, day: 10))!
            Check.expectEqual(HistoryPeriod(scale: .month, containing: february, calendar: cal)
                .bins(calendar: cal).count, 28)
            Check.expectEqual(HistoryPeriod(scale: .year, containing: february, calendar: cal)
                .bins(calendar: cal).count, 12)
        }

        Check.test("stepping back crosses the year") {
            let cal = calendar()
            let january = cal.date(from: DateComponents(year: 2026, month: 1, day: 5))!
            let previous = HistoryPeriod(scale: .month, containing: january, calendar: cal)
                .shifted(by: -1, calendar: cal)
            Check.expectEqual(previous.start, cal.date(from: DateComponents(year: 2025, month: 12, day: 1)))
            Check.expectEqual(previous.end, cal.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        }

        Check.test("titles name the period the way a person would") {
            let cal = calendar()
            let english = Locale(identifier: "en_US")
            func title(_ scale: HistoryScale, _ steps: Int) -> String {
                HistoryPeriod(scale: scale, containing: reference, calendar: cal)
                    .shifted(by: steps, calendar: cal)
                    .title(now: reference, calendar: cal, locale: english)
            }
            Check.expectEqual(title(.day, 0), "Today")
            Check.expectEqual(title(.day, -1), "Yesterday")
            Check.expectEqual(title(.day, -2), "Monday, Oct 19")
            Check.expectEqual(title(.day, -365), "Oct 21, 2025")
            Check.expectEqual(title(.week, 0), "This Week")
            Check.expectEqual(title(.week, -1), "Last Week")
            // DateIntervalFormatter sets the dash between thin spaces.
            Check.expectEqual(title(.week, -2).replacingOccurrences(of: "\u{2009}", with: " "),
                              "Oct 5 – 11")
            Check.expectEqual(title(.month, 0), "October 2026")
            Check.expectEqual(title(.year, -1), "2025")
        }

        Check.test("a daily average divides by the days that have happened") {
            let cal = calendar()
            let month = HistoryPeriod(scale: .month, containing: reference, calendar: cal)
            Check.expectEqual(month.elapsedDays(now: reference, calendar: cal), 21)
            Check.expectEqual(month.shifted(by: -1, calendar: cal)
                .elapsedDays(now: reference, calendar: cal), 30)
            Check.expectEqual(month.shifted(by: 1, calendar: cal)
                .elapsedDays(now: reference, calendar: cal), 0)
        }
    }

    Check.suite("HistoryAxis") {

        Check.test("gridlines fall on round 1024-based values") {
            let gib: Int64 = 1 << 30
            let ticks = HistoryAxis.ticks(forMaximum: gib * 335 / 100)
            Check.expectEqual(ticks, [0, gib, 2 * gib, 3 * gib, 4 * gib])
            Check.expectEqual(ticks.map { HistoryAxis.label($0, inUnitOf: ticks.last!) },
                              ["0", "1 GB", "2 GB", "3 GB", "4 GB"])
        }

        Check.test("every label on an axis uses the top value's unit") {
            let gib: Int64 = 1 << 30
            let ticks = HistoryAxis.ticks(forMaximum: gib * 3 / 2)
            Check.expectEqual(ticks.map { HistoryAxis.label($0, inUnitOf: ticks.last!) },
                              ["0", "0.5 GB", "1 GB", "1.5 GB"])
        }

        Check.test("an empty period still has an axis") {
            Check.expectEqual(HistoryAxis.ticks(forMaximum: 0), [0, 1024])
        }

        Check.test("the bar a moment falls in is found at the edges too") {
            let starts = (0..<4).map { Date(timeIntervalSince1970: TimeInterval($0 * 10)) }
            Check.expectNil(UsageHistory.binIndex(of: Date(timeIntervalSince1970: -1), in: starts))
            Check.expectEqual(UsageHistory.binIndex(of: Date(timeIntervalSince1970: 0), in: starts), 0)
            Check.expectEqual(UsageHistory.binIndex(of: Date(timeIntervalSince1970: 19), in: starts), 1)
            Check.expectEqual(UsageHistory.binIndex(of: Date(timeIntervalSince1970: 99), in: starts), 3)
        }
    }
}
