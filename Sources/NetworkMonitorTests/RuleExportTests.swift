import FirewallPolicy
import Foundation
import NetworkMonitorCore

// #201: rules go to a file, and come back on another Mac.

func runRuleExportTests() {
    func store() -> FirewallRules {
        FirewallRules(defaults: UserDefaults(suiteName: "rule-export-\(UUID().uuidString)")!)
    }
    let meta = FirewallRule(subject: .company, key: "Meta", title: "Meta", action: .block)
    let ads = FirewallRule(subject: .site, key: "doubleclick.net", title: "*.doubleclick.net", action: .block)
    let slack = FirewallRule(subject: .company, key: "host:Amazon", title: "Hosted on Amazon", action: .allow,
                             appKey: "/Applications/Slack.app", appTitle: "Slack")

    Check.suite("Rules — export and import (#201)") {

        Check.test("what's exported imports exactly, newest first") {
            let here = store()
            for rule in [meta, ads, slack] { here.add(rule) }
            let there = store()
            let result = try? there.importRules(from: here.exportData())
            Check.expectEqual(result?.added, 3)
            Check.expectEqual(there.rules, here.rules)
            Check.expectTrue(String(decoding: here.exportData(), as: UTF8.self).contains("\"networkMonitorRules\" : 1"))
        }

        Check.test("leaves out answers that last only until an app quits (#199)") {
            let here = store()
            here.add(meta)
            here.add(FirewallRule(subject: .site, key: "segment.io", title: "*.segment.io", action: .allow,
                                  appKey: "/Applications/Figma.app", appTitle: "Figma", untilQuit: true))
            let there = store()
            Check.expectEqual((try? there.importRules(from: here.exportData()))?.added, 1)
            Check.expectEqual(there.rules, [meta])
        }

        Check.test("adds what's new, never replaces a rule that's here") {
            let there = store()
            let mine = FirewallRule(subject: .company, key: "Meta", title: "Meta", action: .allow)
            there.add(mine)
            let here = store()
            for rule in [meta, ads] { here.add(rule) }
            let result = try? there.importRules(from: here.exportData())
            Check.expectEqual(result?.added, 1)
            Check.expectEqual(result?.alreadyHere, 1)
            Check.expectEqual(there.rules.first { $0.id == meta.id }?.action, .allow, "the rule here wins")
            Check.expectEqual(there.rules.count, 2)
        }

        Check.test("a plain list of rules imports too; anything else is refused") {
            let there = store()
            let list = try! JSONEncoder().encode([ads])
            Check.expectEqual((try? there.importRules(from: list))?.added, 1)
            Check.expectEqual(try? store().importRules(from: Data("{\"hello\": 1}".utf8)).added, nil)
            do {
                try store().importRules(from: Data("not json".utf8))
                Check.expectTrue(false, "should refuse")
            } catch {
                Check.expectEqual(error as? FirewallRules.ImportError, .notRules)
            }
        }

        Check.test("says what it did") {
            Check.expectEqual(FirewallRules.importSummary(added: 3, alreadyHere: 2),
                              "Added 3 rules. 2 were already here.")
            Check.expectEqual(FirewallRules.importSummary(added: 1, alreadyHere: 0), "Added 1 rule.")
            Check.expectEqual(FirewallRules.importSummary(added: 0, alreadyHere: 1),
                              "No new rules. 1 was already here.")
        }
    }
}
