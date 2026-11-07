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

        Check.test("never block and don't filter leave the malware lists on (#317)") {
            let never = AdRule(kind: .neverBlock, site: "example.com")
            let skip = AdRule(kind: .neverBlock, site: nil, appKey: chrome, appTitle: "Chrome")
            for rule in [never, skip] {
                let policy = FirewallPolicy(lists: [.ads, .malware], adRules: [rule],
                                            downloadedLists: ["hagezi-pro", "hagezi-threats"],
                                            threatLists: ["hagezi-threats"])
                Check.expectEqual(policy.decide(flow("ads.example.com", listed: [.ads])), .allow(.mode), rule.id)
                Check.expectEqual(policy.decide(flow("ads.example.com", listed: [.ads, .malware])),
                                  .block(.list(.malware)), rule.id)
                var downloaded = flow("ads.example.com", listed: [])
                downloaded.listedInDownloaded = ["hagezi-pro"]
                Check.expectEqual(policy.decide(downloaded), .allow(.mode), rule.id)
                downloaded.listedInDownloaded = ["hagezi-pro", "hagezi-threats"]
                Check.expectEqual(policy.decide(downloaded), .block(.downloadedList("hagezi-threats")), rule.id)
                // Only while the malware list is on, as before.
                Check.expectEqual(FirewallPolicy(lists: [.ads], adRules: [rule])
                                    .decide(flow("ads.example.com", listed: [.ads, .malware])), .allow(.mode), rule.id)
            }
            // Without a rule, the order is as it was: malware, then ads, then the downloaded lists in order.
            var both = flow("ads.example.com", listed: [.ads])
            both.listedInDownloaded = ["hagezi-threats", "hagezi-pro"]
            Check.expectEqual(FirewallPolicy(lists: [.ads], downloadedLists: ["hagezi-pro", "hagezi-threats"],
                                             threatLists: ["hagezi-threats"]).decide(both), .block(.list(.ads)))
            both.listedIn = []
            Check.expectEqual(FirewallPolicy(lists: [.ads], downloadedLists: ["hagezi-pro", "hagezi-threats"],
                                             threatLists: ["hagezi-threats"]).decide(both),
                              .block(.downloadedList("hagezi-pro")))
            // A site an Always Allow names still goes through.
            let allow = FirewallRule(subject: .site, key: "example.com", title: "example.com", action: .allow)
            Check.expectEqual(FirewallPolicy(rules: [allow], lists: [.malware], adRules: [never])
                                .decide(flow("ads.example.com", listed: [.malware])), .allow(.rule(allow)))
            // Which lists those are, and a site only they blocked.
            Check.expectTrue(ListCatalogue.isThreat("malware") && ListCatalogue.isThreat("hagezi-threats"))
            Check.expectFalse(ListCatalogue.isThreat("ads") || ListCatalogue.isThreat("hagezi-pro")
                              || ListCatalogue.isThreat("mine") || ListCatalogue.isThreat("url-abc123"))
            Check.expectTrue(AdsItem(id: "x.example", title: "x.example", detail: nil, count: 1,
                                     lists: ["malware", "hagezi-threats"]).onlyThreats)
            Check.expectFalse(AdsItem(id: "x.example", title: "x.example", detail: nil, count: 1,
                                      lists: ["ads", "malware"]).onlyThreats)
            Check.expectFalse(AdsItem(id: "x.example", title: "x.example", detail: nil, count: 1, lists: []).onlyThreats)
            // A policy saved before reads none.
            let old = Data(#"{"mode":"anywhere","rules":[]}"#.utf8)
            Check.expectEqual(FirewallPolicy.decode(old)?.threatLists, [])
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

        Check.test("one app's rule holds only for the app its team signed (#320)") {
            let skip = AdRule(kind: .neverBlock, site: nil, appKey: bank, appTitle: "Bank", team: "BANKTEAM01")
            let policy = FirewallPolicy(lists: [.ads, .malware], adRules: [skip])
            var signed = flow("tracker.example.com", app: bank)
            signed.teams = [bank: "BANKTEAM01"]
            Check.expectEqual(policy.decide(signed), .allow(.mode))
            var other = signed
            other.teams = [bank: "SOMEONE001"]
            Check.expectEqual(policy.decide(other), .block(.list(.ads)))
            other.teams = [:]
            Check.expectEqual(policy.decide(other), .block(.list(.ads)), "unsigned at the app's path")
            // A rule made before, with no team, holds as it did.
            let unsigned = AdRule(kind: .neverBlock, site: nil, appKey: bank, appTitle: "Bank")
            Check.expectEqual(FirewallPolicy(lists: [.ads], adRules: [unsigned]).decide(other), .allow(.mode))
            // Skipped, the rule leaves it to every app's rules.
            let always = AdRule(kind: .alwaysBlock, site: "example.com")
            let neverHere = AdRule(kind: .neverBlock, site: "example.com", appKey: bank, team: "BANKTEAM01")
            Check.expectEqual(AdRule.deciding([always, neverHere], name: "a.example.com", appKeys: [bank],
                                              teams: [bank: "SOMEONE001"]), always)
            Check.expectEqual(AdRule.deciding([always, neverHere], name: "a.example.com", appKeys: [bank]), neverHere,
                              "the log, with no teams, reads every rule")
            // Every app's rules keep no team; the same rule's id whatever its team.
            Check.expectNil(AdRule(kind: .alwaysBlock, site: "example.com", team: "X").team)
            Check.expectEqual(skip.id, unsigned.id)
            // Made in the app, it's signed for by the app's team, and saved without one if none.
            let firewall = FirewallRules(defaults: UserDefaults(suiteName: "ad-team-\(UUID().uuidString)")!,
                                         teamOf: { $0 == bank ? "BANKTEAM01" : nil })
            firewall.add(unsigned)
            firewall.add([AdRule(kind: .alwaysBlock, site: "ads.example.com", appKey: chrome)])
            Check.expectEqual(firewall.adRules.first { $0.appKey == bank }?.team, "BANKTEAM01")
            Check.expectNil(firewall.adRules.first { $0.appKey == chrome }?.team)
            let encoded = try! JSONEncoder().encode(unsigned)
            Check.expectFalse(String(decoding: encoded, as: UTF8.self).contains("team"))
            Check.expectEqual(try? JSONDecoder().decode(AdRule.self, from: Data(#"{"kind":"neverBlock","appKey":"/A.app"}"#.utf8)),
                              AdRule(kind: .neverBlock, site: nil, appKey: "/A.app"))
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

    Check.suite("Ad blocking — off on a network (#253)") {

        Check.test("no lists are sent on a network where it's off, and it's kept") {
            let suite = "ad-networks-\(UUID().uuidString)"
            let firewall = FirewallRules(defaults: UserDefaults(suiteName: suite)!)
            firewall.lists = [.ads]
            firewall.pauseLists(on: .init(id: "router-1", name: "Office"), true)
            Check.expectEqual(firewall.listsPausedNetworks, ["router-1": "Office"])
            let paused = Set(firewall.listsPausedNetworks.keys)
            Check.expectEqual(FirewallRules.activeLists(firewall.lists, pausedUntil: nil, network: "router-1",
                                                        pausedNetworks: paused), [])
            Check.expectEqual(FirewallRules.activeLists(firewall.lists, pausedUntil: nil, network: "home",
                                                        pausedNetworks: paused), [.ads])
            Check.expectEqual(FirewallRules.activeLists(firewall.lists, pausedUntil: nil, network: nil,
                                                        pausedNetworks: paused), [.ads])
            Check.expectEqual(FirewallRules(defaults: UserDefaults(suiteName: suite)!).listsPausedNetworks,
                              ["router-1": "Office"])
            firewall.resumeLists(onNetwork: "router-1")
            Check.expectEqual(firewall.listsPausedNetworks, [:])
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
            Check.expectEqual(result.listsNotHere, ["DEU-0"])
            // #254: the lists both offer are switched on, and one added by
            // address is added the same way.
            Check.expectEqual(result.downloadedLists, ["easylist-privacy"])
            Check.expectEqual(result.addedLists, [URL(string: "https://example.org/my-list.txt")!])
            Check.expectTrue(result.summary.contains("Switch on Ads and trackers, Malware and phishing and EasyPrivacy"),
                             "\(result.summary)")
            Check.expectTrue(result.summary.contains("Add 1 list by address: example.org"), "\(result.summary)")
            Check.expectEqual(result.forExtension, ["example.com##.ad"])
            Check.expectEqual(result.skipped.map(\.line), ["/regex/"])
        }

        Check.test("AdGuard's settings: the allowlist, user rules and its filters") {
            let settings: [String: Any] = [
                "protocol-version": "2.0",
                "filters": [
                    "enabled-filters": [2, 3, 15, 224],
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
            Check.expectEqual(result.listsNotHere, ["AdGuard Chinese filter"])
            Check.expectEqual(result.downloadedLists, ["adguard-dns"])
            Check.expectEqual(result.addedLists, [URL(string: "https://example.org/list.txt")!])
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
