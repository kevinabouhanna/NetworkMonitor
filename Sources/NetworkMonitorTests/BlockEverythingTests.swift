import FirewallPolicy
import Foundation
import NetworkMonitorCore

// #198: one switch that stops every app's new connections, apart from what's
// needed to turn it off again.

func runBlockEverythingTests() {
    let chrome = FlowFacts(appKeys: ["/Applications/Google Chrome.app"], companyKey: "Google", country: "US",
                           address: "142.250.1.1", port: 443, isApple: false, hostname: "www.google.com")

    Check.suite("Block Everything (#198)") {

        Check.test("blocks every app, Apple's included, whatever the rules say") {
            let policy = FirewallPolicy(blocksEverything: true)
            Check.expectEqual(policy.decide(chrome), .block(.everything))
            var safari = chrome
            safari.appKeys = ["/Applications/Safari.app"]
            safari.isApple = true
            Check.expectEqual(policy.decide(safari), .block(.everything))
            let allow = FirewallRule(subject: .app, key: "/Applications/Google Chrome.app", title: "Chrome",
                                     action: .allow)
            Check.expectEqual(FirewallPolicy(rules: [allow], blocksEverything: true).decide(chrome),
                              .block(.everything), "Always Allow doesn't open a way round it")
            Check.expectEqual(BlockReason.everything.id, "everything")
            Check.expectTrue(policy.isActive)
        }

        Check.test("leaves what's needed to turn it off: names, the clock, your network, NetworkMonitor") {
            let policy = FirewallPolicy(blocksEverything: true)
            var dns = chrome
            dns.port = 53
            Check.expectEqual(policy.decide(dns), .allow(.essential))
            var local = chrome
            local.address = "192.168.1.20"
            Check.expectEqual(policy.decide(local), .allow(.essential))
            var itself = chrome
            itself.isNetworkMonitor = true
            Check.expectEqual(policy.decide(itself), .allow(.networkMonitor))
        }

        Check.test("off, nothing changes; a policy saved before it reads it as off") {
            Check.expectEqual(FirewallPolicy().decide(chrome), .allow(.mode))
            let old = Data(#"{"mode":"anywhere","rules":[],"onHotspot":false,"pausesUpdates":false}"#.utf8)
            Check.expectEqual(FirewallPolicy.decode(old)?.blocksEverything, false)
            let on = FirewallPolicy(blocksEverything: true)
            Check.expectEqual(FirewallPolicy.decode(on.encoded()), on)
        }

        Check.test("lasts across a relaunch until it's turned off") {
            let defaults = UserDefaults(suiteName: "block-everything-\(UUID().uuidString)")!
            let firewall = FirewallRules(defaults: defaults)
            Check.expectFalse(firewall.blocksEverything)
            firewall.blocksEverything = true
            Check.expectTrue(FirewallRules(defaults: defaults).blocksEverything)
            firewall.blocksEverything = false
            Check.expectFalse(FirewallRules(defaults: defaults).blocksEverything)
        }

        Check.test("the readout turns red while it's on, whatever colours were chosen") {
            Check.expectTrue(MenuBarTints.blockingEverything != MenuBarTints.live)
            Check.expectTrue(MenuBarTints.blockingEverything.down.redComponent > 0.9)
        }
    }
}
