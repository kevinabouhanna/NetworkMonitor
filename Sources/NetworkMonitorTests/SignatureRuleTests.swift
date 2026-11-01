import FirewallPolicy
import Foundation
import NetworkMonitorCore

// #202: a rule about an app remembers the team that signed it, and doesn't
// apply to a program at that path signed by anyone else.

func runSignatureRuleTests() {
    let figma = "/Applications/Figma.app"
    func flow(team: String?) -> FlowFacts {
        FlowFacts(appKeys: [figma], companyKey: "Segment", country: "US", address: "52.1.2.3", port: 443,
                  isApple: false, hostname: "api.segment.io", teams: team.map { [figma: $0] } ?? [:])
    }
    let allowFigma = FirewallRule(subject: .app, key: figma, title: "Figma", action: .allow, team: "T8RA8NE3B7")

    Check.suite("Rules follow the app's signature (#202)") {

        Check.test("a rule about an app applies only to the team that signed it") {
            let policy = FirewallPolicy(mode: .onlyAllowed, rules: [allowFigma])
            Check.expectEqual(policy.decide(flow(team: "T8RA8NE3B7")), .allow(.rule(allowFigma)))
            Check.expectEqual(policy.decide(flow(team: "SOMEONEELS")), .block(.mode), "signed by someone else")
            Check.expectEqual(policy.decide(flow(team: nil)), .block(.mode), "no longer signed by a team")
        }

        Check.test("so does an answer for one app, and a rule without a team is as before") {
            let forFigma = FirewallRule(subject: .company, key: "Segment", title: "Segment", action: .block,
                                        appKey: figma, appTitle: "Figma", team: "T8RA8NE3B7")
            Check.expectEqual(FirewallPolicy(rules: [forFigma]).decide(flow(team: "T8RA8NE3B7")), .block(.rule(forFigma)))
            Check.expectEqual(FirewallPolicy(rules: [forFigma]).decide(flow(team: "SOMEONEELS")), .allow(.mode))
            let unsigned = FirewallRule(subject: .app, key: figma, title: "Figma", action: .block)
            Check.expectEqual(FirewallPolicy(rules: [unsigned]).decide(flow(team: "SOMEONEELS")), .block(.rule(unsigned)))
        }

        Check.test("a rule about an app remembers its team when it's made, and only then") {
            let firewall = FirewallRules(defaults: UserDefaults(suiteName: "signature-\(UUID().uuidString)")!,
                                         teamOf: { $0 == figma ? "T8RA8NE3B7" : nil })
            firewall.add(FirewallRule(subject: .app, key: figma, title: "Figma", action: .block))
            Check.expectEqual(firewall.rules.first?.team, "T8RA8NE3B7")
            firewall.add(FirewallRule(subject: .company, key: "Meta", title: "Meta", action: .block))
            Check.expectNil(firewall.rules.first?.team, "a rule for every app has none")
            firewall.add(FirewallRule(subject: .site, key: "segment.io", title: "*.segment.io", action: .allow,
                                      appKey: figma, appTitle: "Figma"))
            Check.expectEqual(firewall.rules.first?.team, "T8RA8NE3B7")
        }

        Check.test("Apple's own apps have no team, and old rules still read") {
            Check.expectNil(AppMaker.team(forAppKey: "/System/Applications/Calculator.app"))
            let old = Data(#"{"subject":"app","key":"/Applications/Figma.app","title":"Figma","action":"block"}"#.utf8)
            Check.expectNil(try? JSONDecoder().decode(FirewallRule.self, from: old).team)
            let encoded = try! JSONEncoder().encode(FirewallRule(subject: .company, key: "Meta", title: "Meta",
                                                                 action: .block))
            Check.expectFalse(String(decoding: encoded, as: UTF8.self).contains("team"))
        }
    }
}
