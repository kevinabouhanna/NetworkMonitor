import FilterProtocol
import FirewallPolicy
import Foundation
import NetworkMonitorCore

// #199: Ask Me names the site, and its answer can be narrower: this site or
// the whole company, and once, until the app quits, or always.

func runAskSiteTests() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let figmaToSegment = FlowQuestion(id: "q1", appKey: "/Applications/Figma.app", companyKey: "Segment",
                                      companyName: "Segment", companyIsHost: false, hostname: "api.segment.io",
                                      address: "52.1.2.3", country: "US", deadline: now, port: 443)

    Check.suite("Ask Me names the site (#199)") {

        Check.test("the site, then whose it is, the country and the port") {
            let item = AskController.item(for: figmaToSegment, appName: "Figma", bundlePath: nil)
            Check.expectEqual(item.target, "api.segment.io")
            Check.expectTrue(item.detail.hasPrefix("Segment · "))
            Check.expectTrue(item.detail.hasSuffix(" · port 443"))
            Check.expectEqual(item.scopes, [.site("segment.io"), .company(key: "Segment", name: "Segment", isHost: false)])
            Check.expectTrue(item.canLastUntilQuit)
        }

        Check.test("on a host's network, only the site; with no name, the network or the address") {
            let hosted = FlowQuestion(id: "q2", appKey: "/Applications/Slack.app", companyKey: "host:Amazon",
                                      companyName: "Amazon", companyIsHost: true, hostname: "edge.example.app",
                                      address: "3.65.102.105", country: nil, deadline: now)
            Check.expectEqual(AskController.item(for: hosted, appName: "Slack", bundlePath: nil).scopes,
                              [.site("example.app")])
            let nameless = FlowQuestion(id: "q3", appKey: "/Applications/Slack.app", companyKey: "host:Amazon",
                                        companyName: "Amazon", companyIsHost: true, hostname: nil,
                                        address: "3.65.102.105", country: nil, deadline: now)
            Check.expectEqual(AskController.item(for: nameless, appName: "Slack", bundlePath: nil).scopes,
                              [.company(key: "host:Amazon", name: "Amazon", isHost: true)])
            let unowned = FlowQuestion(id: "q4", appKey: "/usr/bin/curl", companyKey: nil, companyName: nil,
                                       companyIsHost: false, hostname: nil, address: "100.64.0.1", country: nil,
                                       deadline: now)
            let item = AskController.item(for: unowned, appName: "curl", bundlePath: nil)
            Check.expectEqual(item.scopes, [.server("100.64.0.1")])
            Check.expectFalse(item.canLastUntilQuit, "a program that isn't an app can't be said to quit")
        }

        Check.test("each answer makes the rule it says") {
            let item = AskController.item(for: figmaToSegment, appName: "Figma", bundlePath: nil)
            let site = AskController.rule(for: item, .allow, scope: .site("segment.io"), lifetime: .always)
            Check.expectEqual(site?.subject, .site)
            Check.expectEqual(site?.key, "segment.io")
            Check.expectEqual(site?.title, "*.segment.io")
            Check.expectEqual(site?.appKey, "/Applications/Figma.app")
            Check.expectEqual(site?.lastsUntilQuit, false)

            let session = AskController.rule(for: item, .allow, scope: .site("segment.io"), lifetime: .untilQuit)
            Check.expectEqual(session?.lastsUntilQuit, true)
            Check.expectNil(AskController.rule(for: item, .allow, scope: .site("segment.io"), lifetime: .once),
                            "Allow Once makes no rule")

            let company = AskController.rule(for: item, .block, scope: item.scopes[1], lifetime: .untilQuit)
            Check.expectEqual(company?.subject, .company)
            Check.expectEqual(company?.action, .block)
            Check.expectEqual(company?.lastsUntilQuit, false, "a block lasts")

            let anywhere = AskController.rule(for: item, .allowAnywhere, scope: item.scopes[0], lifetime: .once)
            Check.expectEqual(anywhere?.subject, .app)
            Check.expectNil(anywhere?.appKey)
        }

        Check.test("answers until it quits go when it quits, and at launch if it's gone") {
            let defaults = UserDefaults(suiteName: "until-quit-\(UUID().uuidString)")!
            let firewall = FirewallRules(defaults: defaults)
            let figma = FirewallRule(subject: .site, key: "segment.io", title: "*.segment.io", action: .allow,
                                     appKey: "/Applications/Figma.app", appTitle: "Figma", untilQuit: true)
            let slack = FirewallRule(subject: .site, key: "slack.com", title: "*.slack.com", action: .allow,
                                     appKey: "/Applications/Slack.app", appTitle: "Slack", untilQuit: true)
            let kept = FirewallRule(subject: .company, key: "Meta", title: "Meta", action: .block,
                                    appKey: "/Applications/Figma.app", appTitle: "Figma")
            for rule in [figma, slack, kept] { firewall.add(rule) }
            firewall.removeRules(untilQuitOf: "/Applications/Figma.app")
            Check.expectEqual(Set(firewall.rules.map(\.id)), [slack.id, kept.id])
            firewall.pruneUntilQuit(running: ["/Applications/Figma.app"])
            Check.expectEqual(firewall.rules.map(\.id), [kept.id], "Slack isn't running")
        }

        Check.test("rules and questions from before #199 still read") {
            let oldRule = Data(#"{"subject":"company","key":"Meta","title":"Meta","action":"block"}"#.utf8)
            Check.expectEqual(try? JSONDecoder().decode(FirewallRule.self, from: oldRule).lastsUntilQuit, false)
            let encoded = try! JSONEncoder().encode(FirewallRule(subject: .company, key: "Meta", title: "Meta",
                                                                 action: .block))
            Check.expectFalse(String(decoding: encoded, as: UTF8.self).contains("untilQuit"),
                              "a lasting rule is written as before")
            Check.expectEqual(FlowQuestion.decode(figmaToSegment.encoded())?.port, 443)
            var old = try! JSONSerialization.jsonObject(with: figmaToSegment.encoded()) as! [String: Any]
            old.removeValue(forKey: "port")
            Check.expectNil(FlowQuestion.decode(try! JSONSerialization.data(withJSONObject: old))?.port)
        }
    }
}
