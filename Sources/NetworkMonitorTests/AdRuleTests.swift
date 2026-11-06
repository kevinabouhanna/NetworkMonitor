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

    Check.suite("Ad blocking — bringing rules over (#253)") {
        let apps: [String: (key: String, name: String)] = [
            "com.google.Chrome": (chrome, "Google Chrome"), "Slack": ("/Applications/Slack.app", "Slack"),
        ]
        let findApp: AdImport.AppFinder = { apps[$0] }

        Check.test("Adblock lines: whole sites come over, the rest is counted and kept for later") {
            let text = """
                ! My filters
                [Adblock Plus 2.0]
                ||taboola.com^
                @@||ads.linkedin.com^$important
                @@||googleadservices.com^$app=com.google.Chrome
                @@*$app=Slack
                ||outbrain.com^$third-party
                ||example.com/ads/*
                /banner[0-9]+/
                example.org##.ad-banner
                ##.sponsored
                youtube.com##+js(set, ytInitialPlayerResponse.adPlacements, undefined)
                @@||news.example^$elemhide
                ||tracker.example.net^$app=Missing
                0.0.0.0 hosts.example.com
                # a hosts comment
                plain.example.io
                """
            let result = try! AdImport.read(Data(text.utf8), existing: [], findApp: findApp)
            Check.expectEqual(result.source, "a list of rules")
            Check.expectEqual(result.rules, [
                AdRule(kind: .alwaysBlock, site: "taboola.com"),
                AdRule(kind: .neverBlock, site: "ads.linkedin.com"),
                AdRule(kind: .neverBlock, site: "googleadservices.com", appKey: chrome, appTitle: "Google Chrome"),
                AdRule(kind: .neverBlock, site: nil, appKey: "/Applications/Slack.app", appTitle: "Slack"),
                AdRule(kind: .alwaysBlock, site: "hosts.example.com"),
                AdRule(kind: .alwaysBlock, site: "plain.example.io"),
            ])
            Check.expectEqual(result.forEnhanced, ["||outbrain.com^$third-party", "||example.com/ads/*",
                                                   "/banner[0-9]+/"])
            Check.expectEqual(result.forExtension.count, 4)
            Check.expectEqual(result.skipped, [AdImport.Skipped(line: "||tracker.example.net^$app=Missing",
                                                                why: "Missing isn't on this Mac")])
            Check.expectEqual(result.summary, ["2 sites never blocked", "3 sites always blocked", "1 app not filtered"])
        }

        Check.test("what's here already is counted, and nothing is read from what isn't rules") {
            let here = [AdRule(kind: .alwaysBlock, site: "taboola.com")]
            let result = try! AdImport.read(Data("||taboola.com^\n||outbrain.com^".utf8), existing: here,
                                            findApp: findApp)
            Check.expectEqual(result.rules, [AdRule(kind: .alwaysBlock, site: "outbrain.com")])
            Check.expectEqual(result.alreadyHere, 1)
            Check.expectTrue((try? AdImport.read(Data("! only a comment".utf8), existing: [], findApp: findApp)) == nil)
            Check.expectTrue((try? AdImport.read(Data("{\"something\": 1}".utf8), existing: [], findApp: findApp)) == nil)
        }

        Check.test("a uBlock Origin backup: trusted sites, my filters and the lists it had on") {
            let backup: [String: Any] = [
                "timeStamp": 1_790_000_000_000, "version": "1.60.0",
                "whitelist": ["about-scheme", "chrome-extension-scheme", "bank.example.com", "/regex/"],
                "selectedFilterLists": ["user-filters", "ublock-filters", "easylist", "easyprivacy", "urlhaus-1",
                                        "https://example.org/my-list.txt", "DEU-0"],
                "userFilters": "||taboola.com^\nexample.com##.ad",
            ]
            let data = try! JSONSerialization.data(withJSONObject: backup)
            let result = try! AdImport.read(data, existing: [], findApp: findApp)
            Check.expectEqual(result.source, "uBlock Origin backup")
            Check.expectEqual(result.rules, [AdRule(kind: .neverBlock, site: "bank.example.com"),
                                             AdRule(kind: .alwaysBlock, site: "taboola.com")])
            Check.expectTrue(result.hasTrustedSites)
            Check.expectEqual(result.lists, [.ads, .malware])
            Check.expectEqual(result.listsNotHere, ["https://example.org/my-list.txt", "DEU-0"])
            Check.expectEqual(result.forExtension, ["example.com##.ad"])
            Check.expectEqual(result.skipped.map(\.line), ["/regex/"])
        }

        Check.test("AdGuard's settings: the allowlist, user rules and its filters") {
            let settings: [String: Any] = [
                "protocol-version": "2.0",
                "filters": [
                    "enabled-filters": [2, 3, 224],
                    "custom-filters": [["customUrl": "https://example.org/list.txt", "title": "My list",
                                        "enabled": true]],
                    "user-filter": ["rules": "||outbrain.com^\n||disabled.example^", "enabled": true,
                                    "disabled-rules": "||disabled.example^"],
                    "whitelist": ["enabled": true, "inverted": false, "domains": ["shop.example.com"]],
                ],
            ]
            let data = try! JSONSerialization.data(withJSONObject: settings)
            let result = try! AdImport.read(data, existing: [], findApp: findApp)
            Check.expectEqual(result.source, "AdGuard settings")
            Check.expectEqual(result.rules, [AdRule(kind: .neverBlock, site: "shop.example.com"),
                                             AdRule(kind: .alwaysBlock, site: "outbrain.com")])
            Check.expectEqual(result.lists, [.ads])
            Check.expectEqual(result.listsNotHere, ["AdGuard Chinese filter", "My list"])
        }

        Check.test("exported rules read back the same") {
            let rules = [AdRule(kind: .alwaysBlock, site: "taboola.com"),
                         AdRule(kind: .neverBlock, site: "googleadservices.com", appKey: chrome, appTitle: "Google Chrome"),
                         AdRule(kind: .neverBlock, site: nil, appKey: "/Applications/Slack.app", appTitle: "Slack")]
            let text = AdImport.export(rules) { $0 == chrome ? "com.google.Chrome" : nil }
            Check.expectTrue(text.contains("@@||googleadservices.com^$app=com.google.Chrome"))
            let back = try! AdImport.read(Data(text.utf8), existing: [],
                                          findApp: { apps[$0] ?? ($0 == "/Applications/Slack.app" ? ($0, "Slack") : nil) })
            Check.expectEqual(back.rules, rules)
        }
    }
}
