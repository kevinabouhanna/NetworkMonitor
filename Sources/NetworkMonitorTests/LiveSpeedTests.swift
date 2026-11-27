import Foundation
import NetworkMonitorCore

/// The popover's Live line and view, and the order of its views (#802).
func runLiveSpeedTests() {
    Check.suite("Popover — Live (#802)") {
        Check.test("keeps one sample a second, the latest in each") {
            let live = LiveSpeed()
            live.record(down: 100, up: 10, at: 1000.1)
            live.record(down: 200, up: 20, at: 1000.6)
            live.record(down: 300, up: 30, at: 1001.2)
            Check.expectEqual(live.samples.count, 2)
            Check.expectEqual(live.samples[0].down, 200)
            Check.expectEqual(live.latest?.up, 30)
        }

        Check.test("keeps 15 minutes and no more") {
            let live = LiveSpeed()
            for second in 0...1000 { live.record(down: Double(second), up: 0, at: Double(second)) }
            Check.expectEqual(live.samples.first?.time, 100)
            Check.expectEqual(live.samples.last?.time, 1000)
            Check.expectEqual(live.samples(in: .oneMinute, now: 1000).count, 61)
            Check.expectEqual(live.samples(in: .fiveMinutes, now: 1000).count, 301)
            Check.expectEqual(live.samples(in: .fifteenMinutes, now: 1000).count, 901)
        }

        Check.test("a clock that goes back starts the graph again") {
            let live = LiveSpeed()
            live.record(down: 1, up: 1, at: 50)
            live.record(down: 2, up: 2, at: 10)
            Check.expectEqual(live.samples.count, 1)
            Check.expectEqual(live.latest?.time, 10)
        }

        Check.test("the apps' rates are their bytes over the time since the sample before, fastest first") {
            let live = LiveSpeed()
            let start = Date(timeIntervalSince1970: 1_000_000)
            live.recordApps([("safari", "Safari", nil, 9_000, 1_000)], at: start)
            Check.expectTrue(live.apps.isEmpty, "the first sample only sets the clock")
            live.recordApps([("music", "Music", nil, 2_000, 0), ("safari", "Safari", nil, 8_000, 2_000),
                             ("idle", "Idle", nil, 0, 0)], at: start + 2)
            Check.expectEqual(live.apps.map(\.id), ["safari", "music"])
            Check.expectEqual(live.apps[0].down, 4_000)
            Check.expectEqual(live.apps[0].up, 1_000)
            live.recordApps([("safari", "Safari", nil, 8_000, 2_000)], at: start + 120)
            Check.expectTrue(live.apps.isEmpty, "a long gap says nothing about now")
        }

        Check.test("the apps list empties when no app sample has come for a while") {
            let live = LiveSpeed()
            let start = Date(timeIntervalSince1970: 1_000_000)
            live.recordApps([("safari", "Safari", nil, 1, 1)], at: start)
            live.recordApps([("safari", "Safari", nil, 9_000, 1_000)], at: start + 1)
            live.record(down: 1, up: 1, at: 10, now: start + 5)
            Check.expectEqual(live.apps.count, 1)
            live.record(down: 1, up: 1, at: 50, now: start + 60)
            Check.expectTrue(live.apps.isEmpty, "a minute without an app sample")
        }

        Check.test("the window's list keeps an app that went quiet for a few seconds, at nothing (#812)") {
            let live = LiveSpeed()
            let start = Date(timeIntervalSince1970: 1_000_000)
            live.recordApps([("safari", "Safari", nil, 1, 1), ("music", "Music", nil, 1, 1)], at: start)
            live.recordApps([("safari", "Safari", nil, 9_000, 0), ("music", "Music", nil, 2_000, 0)], at: start + 1)
            live.recordApps([("safari", "Safari", nil, 9_000, 0)], at: start + 2)
            Check.expectEqual(live.apps.map(\.id), ["safari"])
            Check.expectEqual(live.recentApps.map(\.id), ["safari", "music"])
            Check.expectEqual(live.recentApps.last?.total, 0)
            live.recordApps([("safari", "Safari", nil, 9_000, 0)], at: start + 1 + LiveSpeed.lingers + 1)
            Check.expectEqual(live.recentApps.map(\.id), ["safari"], "gone once it has been quiet a while")
            live.recordApps([], at: start + 120)
            Check.expectTrue(live.recentApps.isEmpty, "a long gap clears it too")
        }

        Check.test("the window's Live page redraws the graph while it's shown (#812)") {
            let model = MonitorViewModel()
            model.setLiveShownInWindow(true)
            Check.expectTrue(model.live.isWatched)
            model.setPopoverOpen(true)
            model.setPopoverOpen(false)
            Check.expectTrue(model.live.isWatched, "closing the popover leaves the window's page watching")
            model.setLiveShownInWindow(false)
            Check.expectFalse(model.live.isWatched)
        }

        Check.test("a skipped sample still starts the next one's interval") {
            let live = LiveSpeed()
            let start = Date(timeIntervalSince1970: 1_000_000)
            live.recordApps([("safari", "Safari", nil, 1, 1)], at: start)
            live.skipAppSample(at: start + 2)
            live.recordApps([("safari", "Safari", nil, 4_000, 0)], at: start + 4)
            Check.expectEqual(live.apps.first?.down, 2_000)
        }

        Check.test("the graph's span is remembered") {
            let defaults = Check.defaults("live-span")
            let live = LiveSpeed(defaults: defaults)
            Check.expectEqual(live.span, .oneMinute)
            live.span = .fifteenMinutes
            Check.expectEqual(LiveSpeed(defaults: defaults).span, .fifteenMinutes)
        }

        Check.test("the graph's top is a round step over the peak") {
            Check.expectEqual(LiveSpeed.scale(peak: 0, unit: .bytes).label, "1 KB/s")
            Check.expectEqual(LiveSpeed.scale(peak: 1_500, unit: .bytes).label, "2 KB/s")
            Check.expectEqual(LiveSpeed.scale(peak: 3.2 * 1_048_576, unit: .bytes).label, "5 MB/s")
            Check.expectEqual(LiveSpeed.scale(peak: 600 * 1024, unit: .bytes).label, "1 MB/s")
            Check.expectEqual(LiveSpeed.scale(peak: 5 * 1_048_576, unit: .bytes).top, 5 * 1_048_576)
            // 12.5 MB/s is 100 Mbps.
            Check.expectEqual(LiveSpeed.scale(peak: 12_500_000, unit: .bits).label, "100 Mbps")
            Check.expectEqual(LiveSpeed.scale(peak: 12_600_000, unit: .bits).label, "200 Mbps")
            Check.expectEqual(LiveSpeed.scale(peak: 12_600_000, unit: .bits).top, 25_000_000)
            for peak in [10.0, 3_000, 900_000, 70_000_000] {
                for unit in SpeedUnit.allCases {
                    Check.expectTrue(LiveSpeed.scale(peak: peak, unit: unit).top >= peak, "\(peak) in \(unit)")
                }
            }
        }
    }

    Check.suite("Popover — which views show, and their order (#802)") {
        Check.test("Live, then Data, Connections, Ads blocked and Network, to begin with") {
            let layout = PopoverLayout(defaults: Check.defaults("layout-default"))
            Check.expectEqual(layout.rows, [.live, .today, .companies, .blocked, .connection])
            Check.expectEqual(layout.buttons, PopoverLayout.defaultOrder)
            Check.expectEqual(layout.opening, .live)
            Check.expectEqual(layout.speedTestSection, .live)
            Check.expectTrue(layout.isDefault)
        }

        Check.test("the order and what's hidden survive a restart") {
            let defaults = Check.defaults("layout-saved")
            let layout = PopoverLayout(defaults: defaults)
            layout.move(.connection, to: 0)
            layout.move(.today, by: 1)
            layout.setShown(.blocked, false)
            let reopened = PopoverLayout(defaults: defaults)
            Check.expectEqual(reopened.order, [.connection, .companies, .today, .blocked])
            Check.expectEqual(reopened.buttons, [.connection, .companies, .today])
            Check.expectFalse(reopened.isShown(.blocked))
        }

        Check.test("opens on the first view shown while Live is hidden, and the speed test goes to Network") {
            let layout = PopoverLayout(defaults: Check.defaults("layout-live-hidden"))
            layout.setShown(.live, false)
            layout.move(.companies, to: 0)
            Check.expectEqual(layout.opening, .companies)
            Check.expectEqual(layout.speedTestSection, .connection)
        }

        Check.test("the last view shown can't be hidden") {
            let layout = PopoverLayout(defaults: Check.defaults("layout-last"))
            for section in PopoverSection.allCases { layout.setShown(section, false) }
            Check.expectEqual(PopoverSection.allCases.filter(layout.isShown), [.connection])
            Check.expectFalse(layout.canHide(.connection))
            Check.expectEqual(layout.opening, .connection)
        }

        Check.test("Live and Network can't both be hidden: one of them has the speed test") {
            let layout = PopoverLayout(defaults: Check.defaults("layout-speed-test"))
            layout.setShown(.live, false)
            Check.expectFalse(layout.canHide(.connection))
            layout.setShown(.connection, false)
            Check.expectTrue(layout.isShown(.connection))
            Check.expectNotNil(layout.whyShown(.connection))
            layout.setShown(.live, true)
            layout.setShown(.connection, false)
            Check.expectFalse(layout.canHide(.live))
            let defaults = Check.defaults("layout-speed-test-saved")
            defaults.set(["live", "connection"], forKey: "popoverHidden")
            Check.expectTrue(PopoverLayout(defaults: defaults).isShown(.connection), "a saved pair is mended")
        }

        Check.test("Live doesn't move, and a move stays among the four") {
            let layout = PopoverLayout(defaults: Check.defaults("layout-moves"))
            layout.move(.live, to: 2)
            layout.move(.today, by: -1)
            Check.expectEqual(layout.order, PopoverLayout.defaultOrder)
            Check.expectFalse(layout.canMove(.today, by: -1))
            Check.expectFalse(layout.canMove(.connection, by: 1))
            Check.expectTrue(layout.canMove(.blocked, by: 1))
            layout.move(.today, to: 99)
            Check.expectEqual(layout.order.last, .today)
        }

        Check.test("a saved order with unknown, repeated or missing views is mended") {
            let defaults = Check.defaults("layout-mended")
            defaults.set(["blocked", "nonsense", "blocked", "live", "today"], forKey: "popoverOrder")
            defaults.set(PopoverSection.allCases.map(\.rawValue), forKey: "popoverHidden")
            let layout = PopoverLayout(defaults: defaults)
            Check.expectEqual(layout.order, [.blocked, .today, .companies, .connection])
            Check.expectTrue(layout.hidden.isEmpty, "everything hidden shows everything")
        }

        Check.test("restoring shows every view in the original order") {
            let layout = PopoverLayout(defaults: Check.defaults("layout-restore"))
            layout.move(.connection, to: 0)
            layout.setShown(.live, false)
            layout.restore()
            Check.expectTrue(layout.isDefault)
        }

        Check.test("the popover opens on Live, or on the first view shown") {
            let model = MonitorViewModel()
            model.popoverLayout.restore()
            model.setPopoverOpen(true)
            Check.expectEqual(model.popoverSection, .live)
            model.setPopoverOpen(false)
            model.popoverLayout.setShown(.live, false)
            model.popoverLayout.move(.blocked, to: 0)
            model.setPopoverOpen(true)
            Check.expectEqual(model.popoverSection, .blocked)
            model.setPopoverOpen(false)
            model.popoverLayout.restore()
        }

        Check.test("the Live line names the speeds for VoiceOver") {
            Check.expectEqual(LiveSpeed.spoken(LiveSample(time: 0, down: 1_048_576, up: 1024), unit: .bytes),
                              "Live, download 1.00 megabytes per second, upload 1.00 kilobytes per second")
            Check.expectEqual(LiveSpeed.spoken(nil, unit: .bytes), "Live, no speeds yet")
        }
    }
}
