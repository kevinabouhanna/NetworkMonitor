import FilterProtocol
import FirewallPolicy
import Foundation
import NetworkExtension
import NetworkMonitorCore
import ServerDirectory
import SQLite3
import SystemExtensions

func runFilterTests() {
    Check.suite("Content filter — what it reports") {

        Check.test("reports survive the trip from the filter to the app") {
            let report = FlowReport(address: "52.112.0.1", port: 443, hostname: "teams.microsoft.com",
                                    pid: 321, time: Date(timeIntervalSince1970: 1_800_000_000))
            Check.expectEqual(FlowReport.decode(FlowReport.encode([report])), [report])
            Check.expectEqual(FlowReport.decode(Data("not json".utf8)), [])
        }

        // audit_token_t is eight 32-bit words; the process ID is the sixth.
        Check.test("reads the process ID from an audit token") {
            var words: [UInt32] = [1, 2, 3, 4, 5, 4242, 7, 8]
            let token = Data(bytes: &words, count: words.count * 4)
            Check.expectEqual(FlowReport.pid(fromAuditToken: token), 4242)
            Check.expectEqual(FlowReport.pid(fromAuditToken: Data([1, 2, 3])), 0)
            Check.expectEqual(FlowReport.pid(fromAuditToken: nil), 0)
        }

        Check.test("only NetworkMonitor's team may connect to the filter") {
            Check.expectTrue(FilterIdentity.appRequirement.contains("GRQKG7M8CL"))
            Check.expectTrue(FilterIdentity.machServiceName.hasPrefix(FilterIdentity.teamIdentifier + "."))
        }

        // #142: a name per build, under the app group, as both ends read it.
        Check.test("each build's filter has a service name of its own") {
            let name = FilterIdentity.machServiceName(build: "89")
            Check.expectEqual(name, "GRQKG7M8CL.com.kevinabouhanna.NetworkMonitor.Filter.89")
            Check.expectTrue(name.hasPrefix(FilterIdentity.appGroup + "."), "under the app group")
            Check.expectTrue(FilterIdentity.machServiceName(build: "89") != FilterIdentity.machServiceName(build: "90"))
            let info: [String: Any] = ["NetworkExtension": ["NEMachServiceName": name]]
            Check.expectEqual(FilterIdentity.machServiceName(inInfo: info), name)
            Check.expectEqual(FilterIdentity.machServiceName(inInfo: nil), FilterIdentity.machServiceName,
                              "a filter without a stamped name")
        }
    }

    Check.suite("Content filter — noticing it has gone quiet (#272)") {

        Check.test("tests only after two quiet minutes, and not while reports come") {
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            var watchdog = FilterWatchdog(now: start)
            Check.expectEqual(watchdog.tick(at: start.addingTimeInterval(119)), .none)
            watchdog.heard(at: start.addingTimeInterval(100))
            Check.expectEqual(watchdog.tick(at: start.addingTimeInterval(200)), .none)
            Check.expectEqual(watchdog.tick(at: start.addingTimeInterval(220)), .probe)
        }

        Check.test("a report after the test ends it") {
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            var watchdog = FilterWatchdog(now: start)
            Check.expectEqual(watchdog.tick(at: start.addingTimeInterval(120)), .probe)
            watchdog.heard(at: start.addingTimeInterval(121))
            Check.expectEqual(watchdog.tick(at: start.addingTimeInterval(140)), .none)
            Check.expectEqual(watchdog.tick(at: start.addingTimeInterval(240)), .none)
            Check.expectEqual(watchdog.tick(at: start.addingTimeInterval(241)), .probe)
        }

        Check.test("silence: reconnect, then restart, then not again for 15 minutes") {
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            var watchdog = FilterWatchdog(now: start)
            var now = start.addingTimeInterval(120)
            Check.expectEqual(watchdog.tick(at: now), .probe)
            Check.expectEqual(watchdog.tick(at: now.addingTimeInterval(5)), .none)
            now += 10
            Check.expectEqual(watchdog.tick(at: now), .reconnect)
            now += 10
            Check.expectEqual(watchdog.tick(at: now), .restart)
            // Still silent after the restart: tests and reconnects, but the
            // next restart waits.
            now += 120
            Check.expectEqual(watchdog.tick(at: now), .probe)
            now += 10
            Check.expectEqual(watchdog.tick(at: now), .reconnect)
            now += 10
            Check.expectEqual(watchdog.tick(at: now), .none)
            now += 15 * 60
            Check.expectEqual(watchdog.tick(at: now), .probe)
            now += 10
            Check.expectEqual(watchdog.tick(at: now), .reconnect)
            now += 10
            Check.expectEqual(watchdog.tick(at: now), .restart)
        }

        Check.test("a test that can't start, with no network, counts for nothing") {
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            var watchdog = FilterWatchdog(now: start)
            Check.expectEqual(watchdog.tick(at: start.addingTimeInterval(120)), .probe)
            watchdog.probeCouldNotStart(at: start.addingTimeInterval(120))
            Check.expectEqual(watchdog.tick(at: start.addingTimeInterval(135)), .none)
            Check.expectEqual(watchdog.tick(at: start.addingTimeInterval(240)), .probe)
        }

        Check.test("the test connection is the app's own, never the person's") {
            Check.expectTrue(FilterWatchdog.isProbe(address: "192.0.2.1", port: 9, pid: getpid()))
            Check.expectFalse(FilterWatchdog.isProbe(address: "192.0.2.1", port: 9, pid: 1))
            Check.expectFalse(FilterWatchdog.isProbe(address: "192.0.2.1", port: 443, pid: getpid()))
            Check.expectFalse(FilterWatchdog.isProbe(address: "1.1.1.1", port: 9, pid: getpid()))
        }
    }

    Check.suite("Content filter — companies from server names") {

        func company(_ hostname: String) -> Company? { Company.named(byHostname: hostname) }

        // The point of #128: a name says whose server it is, wherever it's hosted.
        Check.test("a name says whose server it is") {
            Check.expectEqual(company("api.slack.com")?.name, "Slack")
            Check.expectEqual(company("edge-star-mini-shv-01.facebook.com")?.name, "Meta")
            Check.expectEqual(company("scontent.cdninstagram.com")?.name, "Meta")
            Check.expectEqual(company("www.googleapis.com")?.name, "Google")
            Check.expectEqual(company("api.figma.com")?.name, "Figma", "an unknown domain names itself")
            Check.expectEqual(company("api.figma.com")?.isHost, false)
            Check.expectEqual(company("dns.google")?.name, "Google", "a brand's own top-level domain")
            Check.expectEqual(company("http-intake.logs.us5.datadoghq.com")?.name, "Datadog")
            // Seen on Kevin's Mac in 1.14.0, each under a domain's name of its own.
            Check.expectEqual(company("slackb.com")?.name, "Slack")
            Check.expectEqual(company("x.raycast-releases.com")?.name, "Raycast")
            Check.expectEqual(company("a-cdn.claudeusercontent.com")?.name, "Anthropic")
            Check.expectEqual(company("proxy.googlezip.net")?.name, "Google")
        }

        Check.test("a host's own domain leaves it to the network's owner") {
            Check.expectNil(company("d2x8p0abc.cloudfront.net"))
            Check.expectNil(company("e1234.a.akamaiedge.net"))
            Check.expectNil(company("myapp.appspot.com"))
        }

        Check.test("addresses and bare words aren't names") {
            Check.expectNil(company("142.250.180.14"))
            Check.expectNil(company("localhost"))
        }

        Check.test("country domains keep their second level") {
            Check.expectEqual(company("www.bbc.co.uk")?.name, "Bbc")
        }

        Check.test("Connections uses the name over the network's owner") {
            let amazon = NetworkOwner(asn: 16509, registeredName: "Amazon.com, Inc.",
                                      company: Company(name: "Amazon", isHost: true))
            let usage = ServerUsage(appKey: "Slack", address: "3.65.102.105", bytesIn: 10, bytesOut: 0,
                                    firstSeen: Date(), appName: "Slack", name: "wss-primary.slack.com")
            let named = Connection(usage: usage, country: "DE", owner: amazon)
            let groups = ConnectionsReport.groups([named], by: .companies)
            Check.expectEqual(groups.first?.item.title, "Slack")
            Check.expectEqual(groups.first?.item.isHost, false)
            let server = groups.first?.sections.first { $0.dimension == .server }?.items.first
            Check.expectEqual(server?.title, "wss-primary.slack.com")
            Check.expectTrue(server?.subtitle?.contains("3.65.102.105") ?? false, "the address underneath")
            Check.expectEqual(ConnectionsReport.groups([named], by: .companies, search: "wss-primary").count, 1)
        }
    }

    Check.suite("Content filter — names in Usage History") {

        let calendar: Calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            return calendar
        }()
        let now = Date(timeIntervalSince1970: 1_792_573_800)
        let day = HistoryPeriod(scale: .day, containing: now, calendar: calendar)
        func app(_ key: String) -> AppIdentity {
            AppIdentity(key: key, displayName: key, bundlePath: nil, isSystem: false)
        }
        func seen(_ key: String, _ address: String, _ name: String, blocked: Bool = false) -> UsageHistory.NameSighting {
            UsageHistory.NameSighting(identity: app(key), address: address, name: name, blocked: blocked)
        }
        func withHistory(_ body: (UsageHistory, URL) -> Void) {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("filter-names-\(UUID().uuidString).sqlite")
            defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
            let history = UsageHistory(databaseURL: url, calendar: calendar)
            history.join(NetworkFingerprint(id: "A", kind: .wifi, gatewayMAC: "A", defaultLabel: "A",
                                            isExpensive: false, isConstrained: false),
                         label: "A", switched: false, now: now)
            body(history, url)
        }
        func bytes(_ history: UsageHistory, _ key: String, _ address: String, _ count: Int64 = 10) {
            history.recordApps([(app(key), count, 0)],
                               servers: [key: [address: ByteCounts(bytesIn: count, bytesOut: 0)]], now: now)
        }

        Check.test("a name the filter saw is stored with its app and server, and read back") {
            withHistory { history, url in
                history.recordServerNames([seen("Slack", "3.65.102.105", "wss-primary.slack.com")], now: now)
                bytes(history, "Slack", "3.65.102.105")
                Check.expectEqual(history.servers(in: day).first?.name, "wss-primary.slack.com")

                history.flush(now: now)
                let reopened = UsageHistory(databaseURL: url, calendar: calendar)
                Check.expectEqual(reopened.servers(in: day).first?.name, "wss-primary.slack.com")
            }
        }

        // #247: a CDN address showed an updater's 23 MB under an ad SDK's name,
        // because another app had last reached it by that name.
        Check.test("two apps reaching one address by different names each keep their own") {
            withHistory { history, _ in
                history.recordServerNames([seen("Chrome", "18.66.1.1", "sdk-api-v1.singular.net", blocked: true),
                                           seen("Updater", "18.66.1.1", "download.example.com")], now: now)
                bytes(history, "Updater", "18.66.1.1", 23_000_000)
                bytes(history, "Teams", "18.66.1.1")
                let rows = Dictionary(uniqueKeysWithValues: history.servers(in: day).map { ($0.appKey, $0) })
                Check.expectEqual(rows["Updater"]?.name, "download.example.com")
                Check.expectNil(rows["Teams"]?.name, "Teams named nothing there, so it shows the address")
            }
        }

        Check.test("a name that was only blocked never labels traffic, and Blocked shows it") {
            withHistory { history, _ in
                history.recordServerNames([seen("Chrome", "142.250.74.66", "www.google.com"),
                                           seen("Chrome", "142.250.74.66", "pagead2.googlesyndication.com",
                                                blocked: true)], now: now)
                history.recordBlocked([(app("Chrome"), "142.250.74.66")], now: now)
                bytes(history, "Chrome", "142.250.74.66")
                let traffic = history.servers(in: day).first
                Check.expectEqual(traffic?.name, "www.google.com")
                Check.expectEqual(traffic?.otherNames, [])
                let blocked = history.servers(from: day.start, to: day.end, measure: .blocked).first
                Check.expectEqual(blocked?.name, "pagead2.googlesyndication.com")
            }
        }

        Check.test("several names: the busiest is the title, the rest are listed and searchable") {
            withHistory { history, _ in
                history.recordServerNames([seen("Chrome", "142.250.74.66", "fonts.gstatic.com"),
                                           seen("Chrome", "142.250.74.66", "www.google.com"),
                                           seen("Chrome", "142.250.74.66", "www.google.com"),
                                           seen("Chrome", "142.250.74.66", "apis.google.com")], now: now)
                bytes(history, "Chrome", "142.250.74.66")
                let row = history.servers(in: day).first
                Check.expectEqual(row?.name, "www.google.com")
                Check.expectEqual(row?.otherNames, ["apis.google.com", "fonts.gstatic.com"])

                guard let row else { return }
                let groups = ConnectionsReport.groups([Connection(usage: row, country: nil, owner: nil)], by: .apps)
                let server = groups.first?.sections.first { $0.dimension == .server }?.items.first
                Check.expectTrue(server?.subtitle?.hasPrefix("Also apis.google.com and 1 more") ?? false,
                                 server?.subtitle ?? "no subtitle")
                Check.expectEqual(ConnectionsReport.groups([Connection(usage: row, country: nil, owner: nil)],
                                                           by: .apps, search: "gstatic").count, 1)
            }
        }

        Check.test("a row from before names were kept per app keeps its old name") {
            withHistory { history, url in
                bytes(history, "Slack", "3.65.102.105")
                history.flush(now: now)
                var database: OpaquePointer?
                sqlite3_open(url.path, &database)
                sqlite3_exec(database, "UPDATE servers SET name = 'app.slack.com'", nil, nil, nil)
                sqlite3_close(database)
                Check.expectEqual(history.servers(in: day).first?.name, "app.slack.com")

                // Once the app has a name of its own there, the old one is gone.
                history.recordServerNames([seen("Slack", "3.65.102.105", "wss-primary.slack.com")], now: now)
                Check.expectEqual(history.servers(in: day).first?.name, "wss-primary.slack.com")
            }
        }

        // #250: the Ads window's record.
        Check.test("what the lists blocked is kept by app, name and list, and read back most first") {
            withHistory { history, url in
                history.recordListBlocks([(app("Chrome"), "pagead2.googlesyndication.com", "ads"),
                                          (app("Chrome"), "pagead2.googlesyndication.com", "ads"),
                                          (app("Chrome"), "evil.example", "malware"),
                                          (app("Slack"), "pagead2.googlesyndication.com", "ads")], now: now)
                let blocks = history.listBlocks(from: day.start, to: day.end)
                Check.expectEqual(blocks.first, ListBlock(appKey: "Chrome", appName: "Chrome",
                                                          name: "pagead2.googlesyndication.com", list: "ads", count: 2))
                Check.expectEqual(blocks.count, 3)
                Check.expectEqual(history.listBlockCount(from: day.start, to: day.end), 4)

                history.flush(now: now)
                let reopened = UsageHistory(databaseURL: url, calendar: calendar)
                Check.expectEqual(reopened.listBlockCount(from: day.start, to: day.end), 4)
                Check.expectEqual(reopened.listBlocks(from: day.end, to: day.end.addingTimeInterval(86_400)), [],
                                  "nothing the next day")

                reopened.clear(now: now)
                Check.expectEqual(reopened.listBlockCount(from: day.start, to: day.end), 0, "Clear History clears it")
            }
        }

        Check.test("the popover's count takes History's when it's higher, and starts again each day") {
            let defaults = UserDefaults(suiteName: "list-block-count-\(UUID().uuidString)")!
            let count = ListBlockCount(defaults: defaults, calendar: calendar, now: now)
            count.add(3, now: now)
            count.seed(10, now: now)
            Check.expectEqual(count.today, 10)
            count.seed(4, now: now)
            Check.expectEqual(count.today, 10, "never lower than what was counted live")
            count.seed(2, now: now.addingTimeInterval(86_400))
            Check.expectEqual(count.today, 2, "a new day")
        }

        // #251: the Ads and Trackers window.
        Check.test("the Ads window groups blocks by site and by app, most first") {
            let report = AdsReport([
                ListBlock(appKey: "/Applications/Google Chrome.app", appName: "Google Chrome",
                          name: "pagead2.googlesyndication.com", list: "ads", count: 6),
                ListBlock(appKey: "/Applications/Google Chrome.app", appName: "Google Chrome",
                          name: "googleads.g.doubleclick.net", list: "ads", count: 3),
                ListBlock(appKey: "/Applications/Google Chrome.app", appName: "Google Chrome",
                          name: "ad.doubleclick.net", list: "ads", count: 2),
                ListBlock(appKey: "/Applications/Slack.app", appName: "Slack",
                          name: "evil.example", list: "malware", count: 1),
            ])
            Check.expectEqual(report.total, 12)
            Check.expectEqual(report.lists.map(\.list), ["ads", "malware"])
            Check.expectEqual(report.lists.map(\.count), [11, 1])
            Check.expectEqual(report.sites.map(\.title), ["googlesyndication.com", "doubleclick.net", "evil.example"])
            Check.expectEqual(report.sites[1].count, 5)
            Check.expectEqual(report.sites[1].detail, "googleads.g.doubleclick.net, ad.doubleclick.net")
            Check.expectEqual(report.apps.map(\.title), ["Google Chrome", "Slack"])
            Check.expectEqual(report.apps[0].detail, "googlesyndication.com, doubleclick.net")
            Check.expectEqual(report.apps[1].lists, ["malware"])
            Check.expectEqual(AdsReport.listed(["a", "b", "c", "d"]), "a, b and 2 more")
        }

        Check.test("the Ads chart puts each hour's blocks in its bar") {
            let hour = day.start.addingTimeInterval(3 * 3600)
            let bins = AdsViewModel.chart(for: day, hours: [(hour, 4), (hour.addingTimeInterval(3600), 2)],
                                          calendar: calendar)
            Check.expectEqual(bins.count, 24)
            Check.expectEqual(bins[3].count, 4)
            Check.expectEqual(bins[4].count, 2)
            Check.expectEqual(bins.reduce(0) { $0 + $1.count }, 6)
        }

        Check.test("paused, the filter is sent no lists until the time comes, and it's kept across a relaunch") {
            let lists = Set(BlocklistTopic.allCases)
            Check.expectEqual(FirewallRules.activeLists(lists, pausedUntil: nil), lists)
            Check.expectEqual(FirewallRules.activeLists(lists, pausedUntil: now.addingTimeInterval(60), now: now), [])
            Check.expectEqual(FirewallRules.activeLists(lists, pausedUntil: now.addingTimeInterval(-60), now: now), lists)

            let defaults = UserDefaults(suiteName: "ads-pause-\(UUID().uuidString)")!
            let rules = FirewallRules(defaults: defaults, teamOf: { _ in nil })
            let later = Date().addingTimeInterval(3600)
            rules.pauseLists(until: later)
            Check.expectEqual(FirewallRules(defaults: defaults, teamOf: { _ in nil }).listsPausedUntil, later)
            rules.pauseLists(until: nil)
            Check.expectNil(FirewallRules(defaults: defaults, teamOf: { _ in nil }).listsPausedUntil)
            rules.pauseLists(until: Date().addingTimeInterval(-1))
            Check.expectNil(rules.listsPausedUntil, "a time already past isn't a pause")
        }

        // #252: the live log.
        func logged(_ name: String?, blockedBy: String? = nil, lists: [String] = [], app: String = "Google Chrome")
            -> (time: Date, appKey: String?, appName: String, bundlePath: String?, address: String, port: Int,
                name: String?, blockedBy: String?, lists: [String]) {
            (now, "/Applications/\(app).app", app, nil, "142.250.74.66", 443, name, blockedBy, lists)
        }

        Check.test("the log keeps the newest first, and only so many") {
            let log = AdsLog(limit: 3)
            log.append([logged("a.example"), logged("b.example")])
            log.append([logged("c.example"), logged("d.example")])
            Check.expectEqual(log.entries.map(\.name), ["d.example", "c.example", "b.example"])
            log.clear()
            Check.expectEqual(log.entries, [])
        }

        Check.test("the log narrows to blocked, listed or unnamed, and searches") {
            let log = AdsLog()
            log.append([logged("www.google.com"),
                        logged("pagead2.googlesyndication.com", blockedBy: "list:ads", lists: ["ads"]),
                        logged("stats.example", lists: ["ads"], app: "Slack"),
                        logged(nil)])
            let reason: (AdsLogEntry) -> String = { AdsLog.reason(for: $0, rules: []) }
            func names(_ show: AdsLog.Show, _ search: String = "") -> [String] {
                AdsLog.filtered(log.entries, show: show, search: search, reason: reason).map { $0.name ?? "-" }
            }
            Check.expectEqual(names(.blocked), ["pagead2.googlesyndication.com"])
            Check.expectEqual(names(.listed), ["stats.example", "pagead2.googlesyndication.com"])
            Check.expectEqual(names(.unnamed), ["-"])
            Check.expectEqual(names(.all, "slack"), ["stats.example"])
            Check.expectEqual(names(.all, "ads and trackers"), ["pagead2.googlesyndication.com"], "by its reason")
        }

        Check.test("the log says why, in plain words") {
            let entry = { (blockedBy: String?, lists: [String]) in
                AdsLogEntry(id: 0, time: now, appKey: nil, appName: "Chrome", bundlePath: nil, address: "1.2.3.4",
                            port: 443, name: "ads.example", blockedBy: blockedBy, lists: lists)
            }
            let rule = FirewallRule(subject: .site, key: "example.com", title: "*.example.com", action: .block,
                                    appKey: "/Applications/Slack.app", appTitle: "Slack")
            Check.expectEqual(AdsLog.reason(for: entry(nil, []), rules: []), "Let through")
            Check.expectEqual(AdsLog.reason(for: entry(nil, ["ads"]), rules: []), "Let through, though it's on a list")
            Check.expectEqual(AdsLog.reason(for: entry("list:ads", ["ads"]), rules: []), "On the ads and trackers list")
            Check.expectEqual(AdsLog.reason(for: entry(rule.id, []), rules: [rule]), "Your rule: *.example.com in Slack")
            Check.expectEqual(AdsLog.reason(for: entry("mode", []), rules: []), "Only where you allow")

            let text = AdsLog.text([entry("list:ads", ["ads"])], reason: { AdsLog.reason(for: $0, rules: []) })
            Check.expectTrue(text.contains("\tads.example\t1.2.3.4\t443\tblocked\tOn the ads and trackers list\tads"),
                             text)
        }
    }
}

func runSetupTests() {
    Check.suite("Welcome window and permissions (#134)") {

        Check.test("shown once, and only with something to offer") {
            Check.expectTrue(Welcome.shouldShow(shown: false, filter: .off, wifi: .asking))
            Check.expectTrue(Welcome.shouldShow(shown: false, filter: .on, wifi: .denied))
            Check.expectTrue(Welcome.shouldShow(shown: false, filter: .off, wifi: .allowed))
            Check.expectTrue(Welcome.shouldShow(shown: false, filter: .unavailable, wifi: .asking))
            Check.expectFalse(Welcome.shouldShow(shown: false, filter: .on, wifi: .allowed), "everything's on")
            Check.expectFalse(Welcome.shouldShow(shown: false, filter: .unavailable, wifi: .allowed))
            Check.expectFalse(Welcome.shouldShow(shown: true, filter: .off, wifi: .asking), "never twice")
        }

        Check.test("offered until it's on, then nothing to manage (#181)") {
            for state: FilterController.State in [.off, .needsApplicationsFolder, .starting,
                                                  .waitingForApproval, .confirming, .failed("x")] {
                Check.expectTrue(state.isOffered, "\(state)")
            }
            Check.expectFalse(FilterController.State.on.isOffered)
            Check.expectFalse(FilterController.State.unavailable.isOffered, "a build that can't have it")
        }

        // The point of #134: what you get, never how it works.
        Check.test("says what you get, in plain words") {
            let jargon = ["filter", "extension", "server", "ssid", "content", "permission", "dns", "socket"]
            for text in SetupCopy.plain {
                for word in jargon {
                    Check.expectFalse(text.lowercased().contains(word), "“\(word)” in: \(text)")
                }
            }
        }

        Check.test("a newer request isn't a failure, and no isn't an error") {
            let superseded = NSError(domain: OSSystemExtensionErrorDomain,
                                     code: OSSystemExtensionError.requestSuperseded.rawValue)
            Check.expectNil(FilterController.state(after: superseded))

            let outsideApplications = NSError(domain: OSSystemExtensionErrorDomain,
                                              code: OSSystemExtensionError.unsupportedParentBundleLocation.rawValue)
            Check.expectEqual(FilterController.state(after: outsideApplications), .needsApplicationsFolder)

            let declined = NSError(domain: NEFilterErrorDomain,
                                   code: NEFilterManagerError.configurationPermissionDenied.rawValue)
            let cancelled = NSError(domain: OSSystemExtensionErrorDomain,
                                    code: OSSystemExtensionError.requestCanceled.rawValue)
            for answer in [declined, cancelled] {
                let state = FilterController.state(after: answer)
                Check.expectNotNil(state)
                if case .failed = state { Check.expectTrue(false, "an answer shown as a failure") }
            }

            let broken = NSError(domain: OSSystemExtensionErrorDomain,
                                 code: OSSystemExtensionError.validationFailed.rawValue)
            if case .failed = FilterController.state(after: broken) {} else {
                Check.expectTrue(false, "a real failure is shown as one")
            }
        }
    }
}
