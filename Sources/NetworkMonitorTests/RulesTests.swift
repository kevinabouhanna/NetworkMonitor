import Foundation
import FirewallPolicy
import NetworkMonitorCore
import ServerDirectory

/// Your rules, where you made them (#592): what each did in the period, the
/// same way in Connections' Rules and Ads and Trackers'.
func runRulesTests() {
    Check.suite("Your rules, with what each did (#592)") {
        let safari = "/Applications/Safari.app"
        let slack = "/Applications/Slack.app"
        let meta = NetworkOwner(asn: 32934, registeredName: "FACEBOOK", company: Company(name: "Meta", isHost: false))
        func connection(_ app: String, _ address: String, _ bytes: Int64, name: String? = nil,
                        otherNames: [String] = [], owner: NetworkOwner? = nil, country: String? = nil) -> Connection {
            Connection(usage: ServerUsage(appKey: app, address: address, bytesIn: bytes, bytesOut: 0,
                                          firstSeen: Date(), appName: (app as NSString).lastPathComponent,
                                          name: name, otherNames: otherNames),
                       country: country, owner: owner)
        }

        Check.test("a rule covers what Connections groups by, a name under its site, and only its app") {
            let facebook = connection(safari, "157.240.22.36", 10, name: "graph.facebook.com", owner: meta, country: "IE")
            Check.expectTrue(RuleCount.covers(FirewallRule(subject: .company, key: "Meta", title: "Meta", action: .block),
                                              facebook))
            Check.expectTrue(RuleCount.covers(FirewallRule(subject: .country, key: "IE", title: "Ireland", action: .block),
                                              facebook))
            Check.expectTrue(RuleCount.covers(FirewallRule(subject: .server, key: "157.240.22.36", title: "x",
                                                           action: .block), facebook))
            Check.expectTrue(RuleCount.covers(FirewallRule(subject: .site, key: "facebook.com", title: "*.facebook.com",
                                                           action: .block), facebook))
            Check.expectTrue(!RuleCount.covers(FirewallRule(subject: .site, key: "book.com", title: "book.com",
                                                            action: .block), facebook), "a site isn't a suffix")
            Check.expectTrue(RuleCount.covers(FirewallRule(subject: .app, key: safari, title: "Safari", action: .block),
                                              facebook))
            Check.expectTrue(!RuleCount.covers(FirewallRule(subject: .company, key: "Meta", title: "Meta", action: .block,
                                                            appKey: slack, appTitle: "Slack"), facebook),
                             "a rule for Slack covers Safari's connection")
            // A program Safari started is listed under it.
            let helper = connection(AppKey.key(adopting: "/usr/libexec/helper", by: safari), "1.2.3.4", 1)
            Check.expectTrue(RuleCount.covers(FirewallRule(subject: .app, key: safari, title: "Safari", action: .block),
                                              helper))
        }

        Check.test("a block counts what it stopped, an allow what it let through") {
            let block = FirewallRule(subject: .company, key: "Meta", title: "Meta", action: .block)
            let allow = FirewallRule(subject: .company, key: "Meta", title: "Meta", action: .allow)
            let traffic = [connection(safari, "157.240.22.36", 94_900_000, owner: meta),
                           connection(slack, "52.1.2.3", 5_000_000)]
            let blocked = [connection(safari, "157.240.22.36", 40, owner: meta),
                           connection(slack, "157.240.22.37", 12, owner: meta),
                           connection(slack, "52.1.2.3", 3)]
            Check.expectEqual(RuleCount.activity(of: block, traffic: traffic, blocked: blocked), .stopped(52))
            Check.expectEqual(RuleCount.activity(of: allow, traffic: traffic, blocked: blocked), .letThrough(94_900_000))
            Check.expectEqual(RuleCount.activity(of: block, traffic: [], blocked: []), .stopped(0))
        }

        Check.test("an ad-blocking rule counts its own blocks, and a site always allowed its bytes") {
            let blocks = [ListBlock(appKey: safari, appName: "Safari", name: "pixel.tracker.example", list: "mine", count: 7),
                          ListBlock(appKey: slack, appName: "Slack", name: "tracker.example", list: "mine", count: 2),
                          ListBlock(appKey: safari, appName: "Safari", name: "tracker.example", list: "ads", count: 9)]
            let everywhere = AdRule(kind: .alwaysBlock, site: "tracker.example")
            Check.expectEqual(RuleCount.activity(of: everywhere, traffic: [], listBlocks: blocks), .stopped(9),
                              "a list's blocks counted as your rule's")
            let inSafari = AdRule(kind: .alwaysBlock, site: "tracker.example", appKey: safari, appTitle: "Safari")
            Check.expectEqual(RuleCount.activity(of: inSafari, traffic: [], listBlocks: blocks), .stopped(7))

            let traffic = [connection(safari, "151.101.1.140", 2_000_000, name: "www.theguardian.com"),
                           connection(safari, "151.101.1.141", 1_000_000, name: "cdn.example",
                                      otherNames: ["assets.guim.theguardian.com"]),
                           connection(slack, "52.1.2.3", 500)]
            Check.expectEqual(RuleCount.activity(of: AdRule(kind: .neverBlock, site: "theguardian.com"), traffic: traffic,
                                                 listBlocks: []), .letThrough(3_000_000))
            let leftAlone = AdRule(kind: .neverBlock, site: nil, appKey: slack, appTitle: "Slack")
            Check.expectEqual(RuleCount.activity(of: leftAlone, traffic: traffic, listBlocks: []), .letThrough(500))
        }

        Check.test("each list says what a rule did the same way") {
            Check.expectEqual(RuleActivity.stopped(52).text, L("Stopped %@ times", 52.formatted()))
            Check.expectEqual(RuleActivity.stopped(1).text, L("Stopped 1 time"))
            Check.expectEqual(RuleActivity.letThrough(0).text, L("Not used"))
            Check.expectEqual(RuleActivity.stopped(0).text, L("Not used"))
            Check.expectEqual(RuleActivity.uncounted.text, nil)
        }
    }
}
