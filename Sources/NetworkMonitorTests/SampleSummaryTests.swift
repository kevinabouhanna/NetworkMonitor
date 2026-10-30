import Foundation
import FirewallPolicy
import NetworkMonitorCore

func runSampleSummaryTests() {
    Check.suite("SampleSummary") {

        func app(_ name: String) -> AppIdentity {
            AppIdentity(key: "/Applications/\(name).app", displayName: name,
                        bundlePath: "/Applications/\(name).app", isSystem: false)
        }

        // Chrome's helpers each have a pid; the store wants Chrome once.
        Check.test("a sample's pids fold into one entry per app, servers and all") {
            let sample = [
                NettopRow(pid: 1, processName: "Google Chrome", bytesIn: 100, bytesOut: 10,
                          servers: ["142.250.1.1": ByteCounts(bytesIn: 100, bytesOut: 10)]),
                NettopRow(pid: 2, processName: "Google Chrome H", bytesIn: 50, bytesOut: 5,
                          servers: ["142.250.1.1": ByteCounts(bytesIn: 50, bytesOut: 5)]),
                NettopRow(pid: 3, processName: "Slack", bytesIn: 7, bytesOut: 1),
            ]
            let summary = SampleSummary(sample) { $0.pid == 3 ? app("Slack") : app("Google Chrome") }
            Check.expectEqual(summary.apps.map(\.identity.displayName), ["Google Chrome", "Slack"])
            Check.expectEqual(summary.apps.first?.bytesIn, 150)
            Check.expectEqual(summary.apps.first?.bytesOut, 15)
            Check.expectEqual(summary.servers["/Applications/Google Chrome.app"]?["142.250.1.1"],
                              ByteCounts(bytesIn: 150, bytesOut: 15))
            Check.expectEqual(summary.pids, [1, 2, 3])
        }

        // Mirroring to an Apple TV crosses the Wi-Fi but costs no internet.
        Check.test("LAN bytes never make a row, and only unicast comes off the total") {
            let sample = [
                NettopRow(pid: 4, processName: "AirPlayXPCHelpe", bytesIn: 900, bytesOut: 90,
                          localBytesIn: 900, localBytesOut: 90,
                          subtractableLocalIn: 600, subtractableLocalOut: 60),
            ]
            let summary = SampleSummary(sample) { _ in app("AirPlay") }
            Check.expectTrue(summary.apps.isEmpty)
            Check.expectEqual(summary.localIn, 600)
            Check.expectEqual(summary.localOut, 60)
            Check.expectEqual(summary.pids, [4], "seen, for the cache, though quiet")
        }

        Check.test("updaters are kept by their own name, with the app they fold into") {
            let sample = [NettopRow(pid: 5, processName: "GoogleUpdater", bytesIn: 2_000, bytesOut: 100),
                          NettopRow(pid: 6, processName: "Slack", bytesIn: 2_000, bytesOut: 100)]
            let summary = SampleSummary(sample) { $0.pid == 5 ? app("GoogleUpdater") : app("Slack") }
            Check.expectEqual(summary.updaters.map(\.processName), ["GoogleUpdater"])
            Check.expectEqual(summary.updaters.first?.bytes, 2_100)
        }

        Check.test("an update's traffic is looked for at the app, or the program and its adopter") {
            Check.expectEqual(app("Slack").trafficPaths, ["/Applications/Slack.app"])
            let claude = "/Users/me/.local/share/claude/versions/2.1.314"
            let adopted = AppIdentity(key: "/Applications/iTerm.app" + String(AppKey.separator) + claude,
                                      displayName: "2.1.314", bundlePath: nil, isSystem: false,
                                      parent: ParentApp(key: "/Applications/iTerm.app", displayName: "iTerm2",
                                                        bundlePath: "/Applications/iTerm.app"))
            Check.expectEqual(adopted.trafficPaths, [claude, "/Applications/iTerm.app"])
        }
    }
}
