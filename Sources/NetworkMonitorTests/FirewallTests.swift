import FilterProtocol
import FirewallPolicy
import Foundation
import NetworkMonitorCore
import ServerDirectory
import SQLite3

func runFirewallTests() {
    func rule(_ subject: RuleSubject, _ key: String, _ action: RuleAction) -> FirewallRule {
        FirewallRule(subject: subject, key: key, title: key, action: action)
    }

    /// Chrome reaching one of Meta's servers in Ireland.
    let chromeToMeta = FlowFacts(appKeys: ["/Applications/Google Chrome.app"], companyKey: "Meta", country: "IE",
                                 address: "157.240.1.35", port: 443, isApple: false)

    Check.suite("Firewall — what's decided (#114)") {

        Check.test("with no rules, everything is allowed") {
            Check.expectEqual(FirewallPolicy().decide(chromeToMeta), .allow(.mode))
        }

        // Each subject on its own, both ways.
        Check.test("a rule on the app, the company, the country or the server decides it") {
            let cases: [(RuleSubject, String)] = [(.app, "/Applications/Google Chrome.app"), (.company, "Meta"),
                                                  (.country, "IE"), (.server, "157.240.1.35")]
            for (subject, key) in cases {
                let block = rule(subject, key, .block)
                Check.expectEqual(FirewallPolicy(rules: [block]).decide(chromeToMeta), .block(.rule(block)), "block \(subject)")
                let allow = rule(subject, key, .allow)
                Check.expectEqual(FirewallPolicy(mode: .onlyAllowed, rules: [allow]).decide(chromeToMeta),
                                  .allow(.rule(allow)), "allow \(subject)")
            }
        }

        Check.test("a rule about something else doesn't touch it") {
            let others = [rule(.app, "/Applications/Slack.app", .block), rule(.company, "Google", .block),
                          rule(.country, "US", .block), rule(.server, "1.1.1.1", .block)]
            Check.expectEqual(FirewallPolicy(rules: others).decide(chromeToMeta), .allow(.mode))
        }

        // Most specific first: server, app, company, country. Every pair, both
        // ways round, so the narrower rule wins whichever way it points.
        Check.test("the more specific rule wins, in every pair") {
            let keys: [RuleSubject: String] = [.server: "157.240.1.35", .app: "/Applications/Google Chrome.app",
                                               .company: "Meta", .country: "IE"]
            let order = FirewallPolicy.precedence
            for (i, narrow) in order.enumerated() {
                for wide in order[(i + 1)...] {
                    for (narrowAction, wideAction) in [(RuleAction.allow, RuleAction.block), (.block, .allow)] {
                        let narrowRule = rule(narrow, keys[narrow]!, narrowAction)
                        let wideRule = rule(wide, keys[wide]!, wideAction)
                        let verdict = FirewallPolicy(rules: [wideRule, narrowRule]).decide(chromeToMeta)
                        let expected: Verdict = narrowAction == .allow ? .allow(.rule(narrowRule)) : .block(.rule(narrowRule))
                        Check.expectEqual(verdict, expected, "\(narrow) \(narrowAction) over \(wide) \(wideAction)")
                    }
                }
            }
        }

        Check.test("Block Meta and always allow WhatsApp lets WhatsApp through") {
            let whatsApp = FlowFacts(appKeys: ["/Applications/WhatsApp.app"], companyKey: "Meta", country: "IE",
                                     address: "157.240.1.53", port: 443, isApple: false)
            let policy = FirewallPolicy(rules: [rule(.company, "Meta", .block),
                                                rule(.app, "/Applications/WhatsApp.app", .allow)])
            Check.expectTrue(policy.decide(whatsApp).allows)
            Check.expectFalse(policy.decide(chromeToMeta).allows)
        }

        Check.test("on hotspots means only on hotspots") {
            let hotspotOnly = rule(.company, "Meta", .blockOnHotspots)
            Check.expectEqual(FirewallPolicy(rules: [hotspotOnly], onHotspot: false).decide(chromeToMeta), .allow(.mode))
            Check.expectEqual(FirewallPolicy(rules: [hotspotOnly], onHotspot: true).decide(chromeToMeta),
                              .block(.rule(hotspotOnly)))
            // Off a hotspot, a wider rule still has its say.
            let country = rule(.country, "IE", .block)
            Check.expectEqual(FirewallPolicy(rules: [hotspotOnly, country], onHotspot: false).decide(chromeToMeta),
                              .block(.rule(country)))
        }

        Check.test("any of an app's names matches: Safari's pages come from a WebKit process") {
            let webKit = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/"
                + "com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking"
            let safari = FlowFacts(appKeys: [webKit, "/Applications/Safari.app"], companyKey: "Meta", country: "IE",
                                   address: "157.240.1.35", port: 443, isApple: true)
            Check.expectFalse(FirewallPolicy(rules: [rule(.app, "/Applications/Safari.app", .block)]).decide(safari).allows)
            Check.expectFalse(FirewallPolicy(rules: [rule(.app, webKit, .block)]).decide(safari).allows)
        }

        Check.test("only where allowed: blocks the rest, but never macOS and Apple's apps") {
            let policy = FirewallPolicy(mode: .onlyAllowed)
            Check.expectEqual(policy.decide(chromeToMeta), .block(.mode))
            var apple = chromeToMeta
            apple.isApple = true
            Check.expectEqual(policy.decide(apple), .allow(.apple))
            // Unless they're blocked.
            let blockMeta = rule(.company, "Meta", .block)
            Check.expectEqual(FirewallPolicy(mode: .onlyAllowed, rules: [blockMeta]).decide(apple), .block(.rule(blockMeta)))
        }

        Check.test("essentials are never blocked, by any rule or mode") {
            let everything = FirewallPolicy(mode: .onlyAllowed, rules: [
                rule(.app, "/usr/sbin/mDNSResponder", .block), rule(.country, "US", .block),
                rule(.server, "8.8.8.8", .block), rule(.server, "192.168.1.1", .block)])
            for port in [53, 67, 123, 853, 5353] {
                let flow = FlowFacts(appKeys: ["/usr/sbin/mDNSResponder"], companyKey: "Google", country: "US",
                                     address: "8.8.8.8", port: port, isApple: true)
                Check.expectEqual(everything.decide(flow), .allow(.essential), "port \(port)")
            }
            let router = FlowFacts(appKeys: ["/Applications/Google Chrome.app"], companyKey: nil, country: nil,
                                   address: "192.168.1.1", port: 443, isApple: false)
            Check.expectEqual(everything.decide(router), .allow(.essential), "the local network")
        }

        Check.test("the local network, in both families") {
            for local in ["127.0.0.1", "10.0.0.5", "172.16.4.1", "172.31.255.255", "192.168.1.1", "169.254.3.3",
                          "224.0.0.251", "::1", "fe80::1c98:eeba:57c2:d2da%en0", "fd12:3456::1", "ff02::fb",
                          "::ffff:192.168.1.10"] {
                Check.expectTrue(FirewallPolicy.isLocal(local), local)
            }
            for internet in ["8.8.8.8", "172.32.0.1", "157.240.1.35", "2a03:2880:f12f:83:face:b00c:0:25de",
                             "::ffff:8.8.8.8", "not an address"] {
                Check.expectFalse(FirewallPolicy.isLocal(internet), internet)
            }
        }

        Check.test("servers are keyed as Connections keys them") {
            Check.expectEqual(FirewallPolicy.serverAddress("::ffff:3.65.102.105"), "3.65.102.105")
            Check.expectEqual(FirewallPolicy.serverAddress("fe80::1%en0"), "fe80::1")
            Check.expectEqual(FirewallPolicy.serverAddress("2a03:2880::1"), "2a03:2880::1")
        }

        Check.test("the policy survives the trip to the filter") {
            let policy = FirewallPolicy(mode: .onlyAllowed, rules: [rule(.company, "Meta", .blockOnHotspots)],
                                        onHotspot: true)
            Check.expectEqual(FirewallPolicy.decode(policy.encoded()), policy)
            Check.expectNil(FirewallPolicy.decode(Data("nonsense".utf8)))
        }
    }

    Check.suite("Firewall — the same keys as Connections") {

        // The filter folds paths with `AppKey`; Connections with
        // `AppIdentityResolver`. They must agree, or a rule misses its row.
        Check.test("an app's key is the one Connections lists it under") {
            let paths = [
                "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/151/"
                    + "Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
                "/Applications/Slack.app/Contents/MacOS/Slack",
                "/usr/sbin/mDNSResponder",
            ]
            for path in paths {
                Check.expectEqual(AppKey.key(forExecutablePath: path),
                                  AppIdentityResolver.identity(forExecutablePath: path, fallbackName: "").key, path)
            }
            let parent = ParentApp(key: "/Applications/Visual Studio Code.app", displayName: "Code",
                                   bundlePath: "/Applications/Visual Studio Code.app")
            let child = AppIdentityResolver.identity(forExecutablePath: "/usr/local/bin/node", fallbackName: "node")
            Check.expectEqual(AppIdentityResolver.adopted(child, by: parent).key,
                              AppKey.key(adopting: "/usr/local/bin/node", by: parent.key))
        }

        Check.test("a company's key is the one Connections groups it by") {
            Check.expectEqual(Company(name: "Amazon", isHost: true).key, "host:Amazon")
            Check.expectEqual(Company(name: "Meta", isHost: false).key, "Meta")
        }
    }

    Check.suite("Firewall — the rules a person makes") {

        func item(_ dimension: ConnectionsDimension, _ key: String) -> ConnectionsItem {
            ConnectionsItem(dimension: dimension, key: key, title: key.capitalized, subtitle: nil, isHost: false,
                            symbol: nil, bundlePath: nil)
        }

        Check.test("one rule per row, newest first, kept across launches") {
            let defaults = UserDefaults(suiteName: "firewall-tests-\(UUID().uuidString)")!
            let rules = FirewallRules(defaults: defaults)
            rules.set(.block, for: item(.company, "Meta"))
            rules.set(.allow, for: item(.app, "/Applications/Slack.app"))
            rules.set(.blockOnHotspots, for: item(.company, "Meta"))
            Check.expectEqual(rules.rules.map(\.key), ["Meta", "/Applications/Slack.app"])
            Check.expectEqual(rules.rule(for: item(.company, "Meta"))?.action, .blockOnHotspots)

            let reopened = FirewallRules(defaults: defaults)
            Check.expectEqual(reopened.rules, rules.rules)
            reopened.remove(reopened.rules[0])
            Check.expectNil(reopened.rule(for: item(.company, "Meta")))
        }

        Check.test("Unknown and Other servers can't have a rule: they're many things at once") {
            let defaults = UserDefaults(suiteName: "firewall-tests-\(UUID().uuidString)")!
            let rules = FirewallRules(defaults: defaults)
            rules.set(.block, for: item(.company, ConnectionsReport.unknownKey))
            rules.set(.block, for: item(.company, ConnectionsReport.otherKey))
            Check.expectTrue(rules.rules.isEmpty)
        }
    }

    Check.suite("Firewall — what was blocked, in Usage History") {

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_792_573_800)
        let day = HistoryPeriod(scale: .day, containing: now, calendar: calendar)
        let curlKey = "/Applications/iTerm.app\u{1}/usr/bin/curl"

        func temporaryURL() -> URL {
            URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("blocked-\(UUID().uuidString).sqlite")
        }
        func remove(_ url: URL) {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        func joined(_ history: UsageHistory) {
            history.join(NetworkFingerprint(id: "A", kind: .wifi, gatewayMAC: "A", defaultLabel: "A",
                                            isExpensive: false, isConstrained: false),
                         label: "A", switched: false, now: now)
        }

        Check.test("blocked connections are counted beside the bytes, and each view sees only its own") {
            let url = temporaryURL()
            defer { remove(url) }
            let history = UsageHistory(databaseURL: url, calendar: calendar)
            joined(history)
            let slack = AppIdentity(key: "Slack", displayName: "Slack", bundlePath: nil, isSystem: false)
            history.recordApps([(slack, 10, 0)],
                               servers: ["Slack": ["3.65.102.105": ByteCounts(bytesIn: 10, bytesOut: 0)]], now: now)
            let curl = AppIdentityResolver.identity(forKey: curlKey)
            history.recordBlocked([(curl, "185.15.58.224"), (curl, "185.15.58.224"), (curl, "3.65.102.105")], now: now)

            let traffic = history.servers(from: day.start, to: day.end)
            Check.expectEqual(traffic.map(\.address), ["3.65.102.105"], "nothing blocked among the traffic")
            Check.expectEqual(traffic.first?.appKey, "Slack")

            let blocked = history.servers(from: day.start, to: day.end, measure: .blocked)
            Check.expectEqual(blocked.map(\.address), ["185.15.58.224", "3.65.102.105"], "most first")
            Check.expectEqual(blocked.map(\.bytesIn), [2, 1])
            Check.expectTrue(blocked.allSatisfy { $0.appKey == curlKey && $0.bytesOut == 0 })
            Check.expectEqual(blocked.first?.parentName, "iTerm", "named after the app that started it")
            Check.expectEqual(history.serverHours(from: day.start, to: day.end, measure: .blocked).map(\.bytes), [3])
            Check.expectEqual(history.serverHours(from: day.start, to: day.end).map(\.bytes), [10])

            history.flush(now: now)
            let reopened = UsageHistory(databaseURL: url, calendar: calendar)
            Check.expectEqual(reopened.servers(from: day.start, to: day.end, measure: .blocked).map(\.bytesIn), [2, 1])
        }

        Check.test("a database from before blocking gains the count") {
            let url = temporaryURL()
            defer { remove(url) }
            var database: OpaquePointer?
            sqlite3_open(url.path, &database)
            sqlite3_exec(database, """
                CREATE TABLE server_traffic (
                    hour INTEGER NOT NULL, session_id INTEGER NOT NULL, app_server_id INTEGER NOT NULL,
                    bytes_in INTEGER NOT NULL DEFAULT 0, bytes_out INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (hour, session_id, app_server_id)) WITHOUT ROWID;
                """, nil, nil, nil)
            sqlite3_close(database)

            let history = UsageHistory(databaseURL: url, calendar: calendar)
            joined(history)
            history.recordBlocked([(AppIdentityResolver.identity(forKey: curlKey), "185.15.58.224")], now: now)
            Check.expectEqual(history.servers(from: day.start, to: day.end, measure: .blocked).map(\.bytesIn), [1])
        }

        Check.test("an app is rebuilt from its key alone, as the filter sends it") {
            for key in ["/Applications/Safari.app", "/usr/sbin/mDNSResponder", curlKey] {
                Check.expectEqual(AppIdentityResolver.identity(forKey: key).key, key, key)
            }
            let curl = AppIdentityResolver.identity(forKey: curlKey)
            Check.expectEqual(curl.parent?.bundlePath, "/Applications/iTerm.app")
            Check.expectEqual(curl.displayName, "curl")
            Check.expectFalse(curl.isSystem, "started by an app, so not a system process")
        }

        Check.test("a report from a filter before blocking still reads") {
            let old = Data(#"[{"address":"1.1.1.1","port":443,"pid":7,"time":800000000}]"#.utf8)
            let reports = FlowReport.decode(old)
            Check.expectEqual(reports.count, 1)
            Check.expectNil(reports.first?.blockedBy)
            let blocked = FlowReport(address: "1.1.1.1", port: 443, hostname: nil, pid: 7, time: now,
                                     blockedBy: "company:Meta", appKey: curlKey)
            Check.expectEqual(FlowReport.decode(FlowReport.encode([blocked])), [blocked])
        }

        Check.test("counts read as times, bytes as bytes") {
            Check.expectEqual(ConnectionsViewModel.format(1, .blocked), "1 time")
            Check.expectEqual(ConnectionsViewModel.format(1204, .blocked), "\(1204.formatted()) times")
            Check.expectEqual(ConnectionsViewModel.format(2048, .bytes), ByteFormat.bytes(2048))
        }
    }

    Check.suite("Firewall — updates on a hotspot (#98)") {

        Check.test("an updater is known by its shape, wherever it is") {
            let updaters = [
                "/Applications/Opera.app/Contents/MacOS/opera_autoupdate",
                "/Applications/Raycast.app/Contents/Resources/Updater",
                "/Applications/AppCleaner.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate",
                "/Applications/AppCleaner.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/"
                    + "Contents/MacOS/Updater",
                "/Applications/AppCleaner.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/"
                    + "Downloader.xpc/Contents/MacOS/Downloader",
                "/Users/k/Library/Application Support/Google/GoogleUpdater/150.0.7000.0/GoogleUpdater.app/"
                    + "Contents/MacOS/GoogleUpdater",
                "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/"
                    + "Microsoft AutoUpdate",
                "/Applications/Slack.app/Contents/Frameworks/Squirrel.framework/Resources/ShipIt",
                "/Applications/Google Chrome.app/Contents/Library/LaunchServices/"
                    + "com.google.Chrome.UpdaterPrivilegedHelper",
            ]
            for path in updaters { Check.expectTrue(FirewallPolicy.isUpdater(path), path) }
            let apps = [
                "/Applications/Slack.app/Contents/MacOS/Slack",
                "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/"
                    + "151/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
                "/usr/bin/curl",
                // An app's own name doesn't make it an updater.
                "/Applications/Update Notes.app/Contents/MacOS/Update Notes",
            ]
            for path in apps { Check.expectFalse(FirewallPolicy.isUpdater(path), path) }
        }

        Check.test("update servers are the helper's list, and their subdomains") {
            Check.expectTrue(FirewallPolicy.isUpdateHost("update.googleapis.com"))
            Check.expectTrue(FirewallPolicy.isUpdateHost("UPDATE.googleapis.com."))
            Check.expectTrue(FirewallPolicy.isUpdateHost("eu.desktop.figma.com"))
            Check.expectFalse(FirewallPolicy.isUpdateHost("figma.com"))
            Check.expectFalse(FirewallPolicy.isUpdateHost("googleapis.com"))
            Check.expectFalse(FirewallPolicy.isUpdateHost("notupdate.googleapis.com"))
        }

        let updater = FlowFacts(appKeys: ["/Applications/Opera.app"], companyKey: "Opera", country: "NO",
                                address: "185.26.182.1", port: 443, isApple: false,
                                executablePaths: ["/Applications/Opera.app/Contents/MacOS/opera_autoupdate"])

        Check.test("stopped only on a hotspot with Hotspot mode on") {
            Check.expectEqual(FirewallPolicy(pausesUpdates: true).decide(updater), .block(.updatesOnHotspot))
            Check.expectEqual(FirewallPolicy(pausesUpdates: false).decide(updater), .allow(.mode))
            var browsing = updater
            browsing.executablePaths = ["/Applications/Opera.app/Contents/MacOS/Opera"]
            Check.expectEqual(FirewallPolicy(pausesUpdates: true).decide(browsing), .allow(.mode), "the app itself")
            var check = browsing
            check.hostname = "update.googleapis.com"
            Check.expectEqual(FirewallPolicy(pausesUpdates: true).decide(check), .block(.updatesOnHotspot),
                              "an update server, whoever asks")
        }

        Check.test("your rules win, and Apple's own follows its system setting") {
            let allowOpera = FirewallRule(subject: .app, key: "/Applications/Opera.app", title: "Opera", action: .allow)
            Check.expectEqual(FirewallPolicy(rules: [allowOpera], pausesUpdates: true).decide(updater),
                              .allow(.rule(allowOpera)))
            var apple = updater
            apple.isApple = true
            Check.expectTrue(FirewallPolicy(pausesUpdates: true).decide(apple).allows)
        }

        Check.test("each reason has a name for the report") {
            Check.expectEqual(BlockReason.mode.id, "mode")
            Check.expectEqual(BlockReason.updatesOnHotspot.id, "hotspot-updates")
            Check.expectTrue(FirewallPolicy(pausesUpdates: true).isActive)
            Check.expectFalse(FirewallPolicy().isActive)
        }
    }

    Check.suite("Firewall — Ask Me (#129)") {

        let now = Date(timeIntervalSince1970: 1_792_573_800)

        let slack = FlowFacts(appKeys: ["/Applications/Slack.app"], companyKey: "host:Amazon", country: "DE",
                              address: "3.65.102.105", port: 443, isApple: false)
        var chrome = slack
        chrome.appKeys = ["/Applications/Google Chrome.app"]

        Check.test("asks about what nothing decided, and never about Apple's own") {
            Check.expectEqual(FirewallPolicy(mode: .ask).decide(slack), .ask)
            var apple = slack
            apple.isApple = true
            Check.expectEqual(FirewallPolicy(mode: .ask).decide(apple), .allow(.apple))
            var unnamed = slack
            unnamed.appKeys = []
            Check.expectEqual(FirewallPolicy(mode: .ask).decide(unnamed), .allow(.mode), "a program it couldn't name")
            var dns = slack
            dns.port = 53
            Check.expectEqual(FirewallPolicy(mode: .ask).decide(dns), .allow(.essential))
        }

        Check.test("an answer for one app holds for that app only, and before any rule for every app") {
            let forSlack = FirewallRule(subject: .company, key: "host:Amazon", title: "Hosted on Amazon",
                                        action: .allow, appKey: "/Applications/Slack.app", appTitle: "Slack")
            let blockAmazon = FirewallRule(subject: .company, key: "host:Amazon", title: "Hosted on Amazon",
                                           action: .block)
            let serverBlock = FirewallRule(subject: .server, key: "3.65.102.105", title: "3.65.102.105", action: .block)
            let policy = FirewallPolicy(mode: .ask, rules: [blockAmazon, forSlack, serverBlock])
            Check.expectEqual(policy.decide(slack), .allow(.rule(forSlack)))
            Check.expectEqual(policy.decide(chrome), .block(.rule(serverBlock)))
            Check.expectEqual(FirewallPolicy(mode: .ask, rules: [forSlack]).decide(chrome), .ask, "Chrome still asked")
            Check.expectEqual(forSlack.id, "company:host:Amazon@/Applications/Slack.app")
        }

        Check.test("rules from before Ask Me still read") {
            let old = Data(#"[{"subject":"company","key":"Meta","title":"Meta","action":"block"}]"#.utf8)
            let rules = try? JSONDecoder().decode([FirewallRule].self, from: old)
            Check.expectEqual(rules?.first?.id, "company:Meta")
            Check.expectNil(rules?.first?.appKey)
        }

        Check.test("a question survives the trip, and reads as a person would say it") {
            let question = FlowQuestion(id: "q1", appKey: "/Applications/Slack.app", companyKey: "Slack",
                                        companyName: "Slack", companyIsHost: false, hostname: "wss-primary.slack.com",
                                        address: "3.65.102.105", country: "DE", deadline: now)
            Check.expectEqual(FlowQuestion.decode(question.encoded()), question)
            let item = AskController.item(for: question)
            Check.expectEqual(item.appName, "Slack")
            Check.expectEqual(item.target, "Slack")
            Check.expectTrue(item.detail.hasPrefix("wss-primary.slack.com · "))

            let hosted = FlowQuestion(id: "q2", appKey: "/Applications/Slack.app", companyKey: "host:Amazon",
                                      companyName: "Amazon", companyIsHost: true, hostname: nil,
                                      address: "3.65.102.105", country: nil, deadline: now)
            Check.expectEqual(AskController.item(for: hosted).target, "a server on Amazon's network")
            Check.expectEqual(AskController.item(for: hosted).detail, "3.65.102.105")

            // Seen on Kevin's Mac: Raycast's bundled node asked as plain "node".
            let started = FlowQuestion(id: "q3", appKey: "/Applications/Raycast.app\u{1}/Users/k/node", companyKey: nil,
                                       companyName: nil, companyIsHost: false, hostname: "backend.raycast.com",
                                       address: "1.2.3.4", country: nil, deadline: now)
            Check.expectEqual(AskController.item(for: started).appName, "Raycast's node")
        }

        Check.test("a rule for one app is listed, not shown on every app's row") {
            let defaults = UserDefaults(suiteName: "firewall-tests-\(UUID().uuidString)")!
            let rules = FirewallRules(defaults: defaults)
            rules.add(FirewallRule(subject: .company, key: "Meta", title: "Meta", action: .block,
                                   appKey: "/Applications/Slack.app", appTitle: "Slack"))
            let meta = ConnectionsItem(dimension: .company, key: "Meta", title: "Meta", subtitle: nil, isHost: false,
                                       symbol: nil, bundlePath: nil)
            Check.expectNil(rules.rule(for: meta))
            rules.set(.allow, for: meta)
            Check.expectEqual(rules.rules.count, 2, "one for Slack, one for everyone")
            Check.expectEqual(rules.rule(for: meta)?.action, .allow)
        }
    }
}
