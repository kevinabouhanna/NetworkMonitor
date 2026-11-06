import FirewallPolicy
import Foundation
import NetworkMonitorCore

// #253: your own say over ad blocking, beside the lists.

func runAdRuleTests() {
    let chrome = "/Applications/Google Chrome.app"
    let bank = "/Applications/Bank.app"
    func flow(_ name: String?, app: String = chrome, listed: Set<BlocklistTopic> = [.ads]) -> FlowFacts {
        FlowFacts(appKeys: [app], companyKey: nil, country: "US", address: "142.251.39.174", port: 443,
                  isApple: false, hostname: name, listedIn: listed)
    }

    Check.suite("Ad blocking — your rules (#253)") {

        Check.test("never block lets a listed site and every name under it through") {
            let never = AdRule(kind: .neverBlock, site: "doubleclick.net")
            let policy = FirewallPolicy(lists: [.ads], adRules: [never])
            Check.expectEqual(policy.decide(flow("static.doubleclick.net")), .allow(.mode))
            Check.expectEqual(policy.decide(flow("ads.example.com")), .block(.list(.ads)))
        }

        Check.test("always block stops a site no list has, counted with the lists") {
            let always = AdRule(kind: .alwaysBlock, site: "example.com")
            let policy = FirewallPolicy(lists: [.ads], adRules: [always])
            Check.expectEqual(policy.decide(flow("cdn.example.com", listed: [])), .block(.adRule(always)))
            Check.expectEqual(BlockReason.adRule(always).id, "list:mine:alwaysBlock:example.com")
            Check.expectEqual(BlockReason.list(inReport: BlockReason.adRule(always).id), "mine")
            Check.expectEqual(BlockReason.adRuleID(inReport: BlockReason.adRule(always).id), always.id)
            Check.expectEqual(BlockReason.list(inReport: "list:ads"), "ads")
            Check.expectEqual(BlockReason.list(inReport: "mode"), nil)
            Check.expectEqual(BlockReason.adRuleID(inReport: "list:ads"), nil)
        }

        Check.test("rules count only while ad blocking is on, and never over a firewall rule") {
            let always = AdRule(kind: .alwaysBlock, site: "example.com")
            Check.expectEqual(FirewallPolicy(adRules: [always]).decide(flow("example.com", listed: [])), .allow(.mode))
            let allow = FirewallRule(subject: .site, key: "example.com", title: "example.com", action: .allow)
            Check.expectEqual(FirewallPolicy(rules: [allow], lists: [.ads], adRules: [always])
                                .decide(flow("example.com", listed: [])), .allow(.rule(allow)))
        }

        Check.test("don't filter an app: none of its connections meet the lists") {
            let skip = AdRule(kind: .neverBlock, site: nil, appKey: bank, appTitle: "Bank")
            Check.expectTrue(skip.skipsApp)
            let policy = FirewallPolicy(lists: [.ads], adRules: [skip])
            Check.expectEqual(policy.decide(flow("tracker.example.com", app: bank)), .allow(.mode))
            Check.expectEqual(policy.decide(flow("tracker.example.com")), .block(.list(.ads)))
            Check.expectEqual(skip.summary, "Don't filter Bank")
        }

        Check.test("one app's rule wins over every app's, never over always, the longer name within") {
            let alwaysAll = AdRule(kind: .alwaysBlock, site: "example.com")
            let neverChrome = AdRule(kind: .neverBlock, site: "example.com", appKey: chrome, appTitle: "Chrome")
            Check.expectEqual(AdRule.deciding([alwaysAll, neverChrome], name: "a.example.com", appKeys: [chrome]),
                              neverChrome)
            Check.expectEqual(AdRule.deciding([alwaysAll, neverChrome], name: "a.example.com", appKeys: [bank]),
                              alwaysAll)
            let alwaysChrome = AdRule(kind: .alwaysBlock, site: "ads.example.com", appKey: chrome)
            Check.expectEqual(AdRule.deciding([alwaysChrome, neverChrome], name: "ads.example.com", appKeys: [chrome]),
                              neverChrome, "never before always, for the same scope")
            let neverSite = AdRule(kind: .neverBlock, site: "example.com")
            let neverName = AdRule(kind: .neverBlock, site: "a.example.com")
            Check.expectEqual(AdRule.deciding([neverSite, neverName], name: "a.example.com", appKeys: []), neverName)
            Check.expectEqual(AdRule.deciding([neverSite], name: nil, appKeys: [chrome]), nil)
        }

        Check.test("a site from whatever was typed or pasted") {
            Check.expectEqual(AdRule.site(from: " https://Ads.Example.com/banner?x=1 "), "ads.example.com")
            Check.expectEqual(AdRule.site(from: "||doubleclick.net^"), "doubleclick.net")
            Check.expectEqual(AdRule.site(from: "*.example.com"), "example.com")
            Check.expectEqual(AdRule.site(from: "example.com:8443"), "example.com")
            Check.expectEqual(AdRule.site(from: "localhost"), nil)
            Check.expectEqual(AdRule.site(from: "1.2.3.4"), nil)
            Check.expectEqual(AdRule.site(from: ""), nil)
        }

        Check.test("kept and sent: one rule per site and app, an old filter reads none") {
            let firewall = FirewallRules(defaults: UserDefaults(suiteName: "ad-rules-\(UUID().uuidString)")!)
            firewall.add(AdRule(kind: .neverBlock, site: "example.com"))
            firewall.add(AdRule(kind: .alwaysBlock, site: "example.com"))
            firewall.add(AdRule(kind: .alwaysBlock, site: "example.com", appKey: chrome))
            firewall.add(AdRule(kind: .alwaysBlock, site: "not a site"))
            Check.expectEqual(firewall.adRules.map(\.id),
                              ["alwaysBlock:example.com@\(chrome)", "alwaysBlock:example.com"])
            let policy = firewall.policy(onHotspot: false)
            Check.expectEqual(FirewallPolicy.decode(policy.encoded())?.adRules, firewall.adRules)
            var old = try! JSONSerialization.jsonObject(with: policy.encoded()) as! [String: Any]
            old.removeValue(forKey: "adRules")
            let oldData = try! JSONSerialization.data(withJSONObject: old)
            Check.expectEqual(FirewallPolicy.decode(oldData)?.adRules, [])
            firewall.remove(firewall.adRules[0])
            Check.expectEqual(firewall.adRules.count, 1)
        }

        Check.test("the log says which rule decided") {
            let never = AdRule(kind: .neverBlock, site: "doubleclick.net")
            let always = AdRule(kind: .alwaysBlock, site: "example.com", appKey: chrome, appTitle: "Chrome")
            func entry(_ name: String, blockedBy: String?, lists: [String]) -> AdsLogEntry {
                AdsLogEntry(id: 0, time: Date(), appKey: chrome, appName: "Chrome", bundlePath: chrome,
                            address: "1.2.3.4", port: 443, name: name, blockedBy: blockedBy, lists: lists)
            }
            Check.expectEqual(AdsLog.reason(for: entry("ad.doubleclick.net", blockedBy: nil, lists: ["ads"]),
                                            rules: [], adRules: [never]),
                              "Your rule: never block doubleclick.net")
            Check.expectEqual(AdsLog.reason(for: entry("ad.doubleclick.net", blockedBy: nil, lists: ["ads"]),
                                            rules: [], adRules: []),
                              "Let through, though it's on a list")
            Check.expectEqual(AdsLog.reason(for: entry("example.com", blockedBy: BlockReason.adRule(always).id, lists: []),
                                            rules: [], adRules: [always]),
                              "Your rule: always block example.com in Chrome")
            Check.expectEqual(AdsReport.title(ofList: "mine"), "Your Rules")
        }
    }
}
