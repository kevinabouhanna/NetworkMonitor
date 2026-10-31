import FirewallPolicy
import Foundation
import NetworkMonitorCore

// #200: a rule that applies only on one network, by the router's identity.

func runNetworkRuleTests() {
    let office = "gw:aa:bb:cc:dd:ee:ff"
    let home = "gw:11:22:33:44:55:66"
    let chromeToYouTube = FlowFacts(appKeys: ["/Applications/Google Chrome.app"], companyKey: "Google",
                                    country: "US", address: "142.250.1.1", port: 443, isApple: false,
                                    hostname: "www.youtube.com")

    Check.suite("Rules for one network (#200)") {

        Check.test("applies on its network, and nowhere else") {
            let rule = FirewallRule(subject: .site, key: "youtube.com", title: "*.youtube.com", action: .block,
                                    network: office, networkTitle: "Office Wi-Fi")
            Check.expectEqual(FirewallPolicy(rules: [rule], network: office).decide(chromeToYouTube), .block(.rule(rule)))
            Check.expectEqual(FirewallPolicy(rules: [rule], network: home).decide(chromeToYouTube), .allow(.mode))
            Check.expectEqual(FirewallPolicy(rules: [rule]).decide(chromeToYouTube), .allow(.mode), "offline")
        }

        Check.test("elsewhere, the next rule decides") {
            let here = FirewallRule(subject: .site, key: "youtube.com", title: "*.youtube.com", action: .allow,
                                    network: home, networkTitle: "Home")
            let everywhere = FirewallRule(subject: .company, key: "Google", title: "Google", action: .block)
            Check.expectEqual(FirewallPolicy(rules: [here, everywhere], network: home).decide(chromeToYouTube),
                              .allow(.rule(here)))
            Check.expectEqual(FirewallPolicy(rules: [here, everywhere], network: office).decide(chromeToYouTube),
                              .block(.rule(everywhere)))
        }

        Check.test("made from a row, with the network's name; old rules and policies still read") {
            let firewall = FirewallRules(defaults: UserDefaults(suiteName: "network-rules-\(UUID().uuidString)")!)
            let row = ConnectionsItem(dimension: .company, key: "Meta", title: "Meta", subtitle: nil, isHost: false,
                                      symbol: nil, bundlePath: nil)
            firewall.set(.block, for: row, network: .init(id: office, name: "Office Wi-Fi"))
            Check.expectEqual(firewall.rules.first?.network, office)
            Check.expectEqual(firewall.rules.first?.networkTitle, "Office Wi-Fi")
            firewall.set(.block, for: row)
            Check.expectNil(firewall.rules.first?.network, "a rule for everywhere replaces it")
            Check.expectEqual(firewall.rules.count, 1)

            let lasting = try! JSONEncoder().encode(FirewallRule(subject: .company, key: "Meta", title: "Meta",
                                                                 action: .block))
            Check.expectFalse(String(decoding: lasting, as: UTF8.self).contains("network"))
            let old = Data(#"{"mode":"anywhere","rules":[],"onHotspot":false,"pausesUpdates":false}"#.utf8)
            Check.expectNil(FirewallPolicy.decode(old)?.network)
            let policy = FirewallPolicy(network: office)
            Check.expectEqual(FirewallPolicy.decode(policy.encoded()), policy)
        }
    }
}
