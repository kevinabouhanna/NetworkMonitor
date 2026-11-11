import Foundation
import NetworkMonitorCore
import ServerDirectory

func runConnectionsTests() {
    let english = Locale(identifier: "en_US")
    let reference = Date(timeIntervalSince1970: 1_792_573_800)   // 2026-10-21 09:10 UTC

    func owner(_ company: String, host: Bool = false, asn: UInt32 = 64_512) -> NetworkOwner {
        NetworkOwner(asn: asn, registeredName: "\(company) Inc.", company: Company(name: company, isHost: host))
    }

    func connection(_ app: String, _ address: String, _ bytes: Int64, country: String?,
                    owner: NetworkOwner?, parent: String? = nil) -> Connection {
        Connection(usage: ServerUsage(appKey: app, address: address, bytesIn: bytes, bytesOut: 0,
                                      firstSeen: reference, appName: app, parentName: parent),
                   country: country, owner: owner)
    }

    // Teams on Microsoft in two countries, Chrome on Google and on something
    // hosted by Google Cloud, Mail on an unknown network.
    let sample = [
        connection("Teams", "52.112.0.1", 500, country: "NL", owner: owner("Microsoft")),
        connection("Teams", "52.113.0.1", 300, country: "IE", owner: owner("Microsoft")),
        connection("Chrome", "142.250.0.1", 450, country: "US", owner: owner("Google")),
        connection("Chrome", "34.120.0.1", 100, country: "US", owner: owner("Google", host: true)),
        connection("Mail", "100.64.0.1", 50, country: nil, owner: nil),
    ]

    Check.suite("Connections — grouping") {

        Check.test("by company, biggest first, each opening into apps, countries and servers") {
            let groups = ConnectionsReport.groups(sample, by: .companies, locale: english)
            Check.expectEqual(groups.map(\.item.title),
                              ["Microsoft", "Google", "Hosted on Google", "Unknown network"])
            let microsoft = groups[0]
            Check.expectEqual(microsoft.item.total, 800)
            Check.expectEqual(microsoft.sections.map(\.dimension), [.app, .country, .server])
            Check.expectEqual(microsoft.sections[0].items.map(\.title), ["Teams"])
            Check.expectEqual(microsoft.sections[1].items.map(\.title), ["Netherlands", "Ireland"])
            Check.expectEqual(microsoft.sections[1].items.first?.symbol, "🇳🇱")
            Check.expectEqual(microsoft.sections[2].items.count, 2)
        }

        // Google's own network and Google Cloud are different answers, and the
        // second must not read as Google.
        Check.test("keeps a host apart from the company of the same name") {
            let groups = ConnectionsReport.groups(sample, by: .companies, locale: english)
            let hosted = groups.first { $0.item.isHost }
            Check.expectEqual(hosted?.item.title, "Hosted on Google")
            Check.expectEqual(hosted?.item.total, 100)
            Check.expectEqual(groups.first { $0.item.title == "Google" }?.item.total, 450)
        }

        Check.test("by app and by country, turned around") {
            let apps = ConnectionsReport.groups(sample, by: .apps, locale: english)
            Check.expectEqual(apps.map(\.item.title), ["Teams", "Chrome", "Mail"])
            Check.expectEqual(apps[0].sections.map(\.dimension), [.company, .country, .server])
            let countries = ConnectionsReport.groups(sample, by: .countries, locale: english)
            Check.expectEqual(countries.map(\.item.title),
                              ["United States", "Netherlands", "Ireland", "Unknown country"])
            Check.expectEqual(countries[0].sections[0].items.map(\.title), ["Google", "Hosted on Google"])
        }

        Check.test("an app's servers past the hourly limit read as other servers") {
            let other = connection("Torrent", UsageHistory.otherServers, 70, country: nil, owner: nil)
            let groups = ConnectionsReport.groups([other], by: .companies, locale: english)
            Check.expectEqual(groups.first?.item.title, "Other servers")
            Check.expectEqual(ConnectionsReport.summary([other]).servers, 0)
        }
    }

    Check.suite("Connections — narrowing") {

        Check.test("a filter keeps only what matches every chip") {
            let filter = ConnectionsFilter(keys: [.company: "Microsoft", .country: "IE"])
            let groups = ConnectionsReport.groups(sample, by: .companies, filter: filter, locale: english)
            Check.expectEqual(groups.map(\.item.total), [300])
        }

        Check.test("search finds a company, a registered name, a country, an app or an address") {
            func titles(_ query: String) -> [String] {
                ConnectionsReport.groups(sample, by: .apps, search: query, locale: english).map(\.item.title)
            }
            Check.expectEqual(titles("micro"), ["Teams"])
            Check.expectEqual(titles("Google Inc"), ["Chrome"])
            Check.expectEqual(titles("ireland"), ["Teams"])
            Check.expectEqual(titles("mail"), ["Mail"])
            Check.expectEqual(titles("100.64"), ["Mail"])
            Check.expectEqual(titles("  "), ["Teams", "Chrome", "Mail"], "blank searches nothing out")
        }

        Check.test("the summary counts companies and countries, not placeholders") {
            let summary = ConnectionsReport.summary(sample)
            Check.expectEqual(summary.total, 1_400)
            Check.expectEqual(summary.companies, 3, "Microsoft, Google, hosted on Google")
            Check.expectEqual(summary.countries, 3)
            Check.expectEqual(summary.apps, 3)
            Check.expectEqual(summary.servers, 5)
        }

        // An app on Amazon's network isn't talking to Amazon.
        Check.test("an app's companies leave hosts out") {
            Check.expectEqual(ConnectionsReport.companies(ofApp: "Chrome", in: sample), ["Google"])
        }

        // Cloudflare answers from whichever data centre is nearest, so the
        // country its addresses are filed under is not where the data went.
        Check.test("the map shades countries, and keeps anycast networks off it") {
            let cloudflare = NetworkOwner(asn: 13335, registeredName: "Cloudflare, Inc.",
                                          company: Company(name: "Cloudflare", isHost: true, answersEverywhere: true))
            let extra = [
                connection("Chrome", "104.18.0.1", 700, country: "CA", owner: cloudflare),
                connection("Torrent", UsageHistory.otherServers, 90, country: nil, owner: nil),
            ]
            let geography = ConnectionsReport.geography(sample + extra)
            Check.expectEqual(geography.countries, ["NL": 500, "IE": 300, "US": 550])
            Check.expectEqual(geography.everywhere, 700)
            Check.expectEqual(geography.everywhereCompanies, ["Cloudflare"])
            Check.expectEqual(geography.largest, 550)
            Check.expectEqual(ConnectionsReport.companies(inCountry: "US", sample + extra).map(\.item.title),
                              ["Google", "Hosted on Google"])
            Check.expectEqual(ConnectionsReport.companies(inCountry: "CA", sample + extra).count, 0)
        }

        Check.test("flags are regional indicators, and only for two letters") {
            Check.expectEqual(ConnectionsReport.flag("lb"), "🇱🇧")
            Check.expectNil(ConnectionsReport.flag("EU1"))
        }
    }

    Check.suite("Connections — makers and timeline") {

        Check.test("reads the maker from a certificate's subject") {
            Check.expectEqual(AppMaker.name(fromCertificateSummary:
                "Developer ID Application: Microsoft Corporation (UBF8T346G9)"), "Microsoft Corporation")
            Check.expectEqual(AppMaker.name(fromCertificateSummary: "macOS Software Signing"), "Apple")
            Check.expectEqual(AppMaker.name(fromCertificateSummary: "Software Signing"), "Apple",
                              "the name before macOS 27")
            Check.expectEqual(AppMaker.name(fromCertificateSummary:
                "Developer ID Application: SLACK TECHNOLOGIES L.L.C. (BQR82RBBHL)"), "Slack Technologies L.L.C.")
            Check.expectNil(AppMaker.name(fromCertificateSummary: "Apple Mac OS Application Signing"),
                            "a Mac App Store certificate is Apple's, whoever wrote the app")
            Check.expectNil(AppMaker.name(fromCertificateSummary: "NetworkMonitor Signing"))
        }

        Check.test("reads a real app's signature") {
            Check.expectEqual(AppMaker.name(ofBundleAt: "/System/Applications/Calculator.app"), "Apple")
            Check.expectNil(AppMaker.name(ofBundleAt: "/nonexistent.app"))
        }

        Check.test("hours fall into the period's bars") {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let day = HistoryPeriod(scale: .day, containing: reference, calendar: calendar)
            let nine = calendar.dateInterval(of: .hour, for: reference)!.start
            let bins = ConnectionsViewModel.timeline(
                for: day, hours: [(nine, 100), (nine + 3_600, 40), (day.start - 3_600, 999)], calendar: calendar)
            Check.expectEqual(bins.count, 24)
            Check.expectEqual(bins[9].bytes, 100)
            Check.expectEqual(bins[10].bytes, 40)
            Check.expectEqual(bins.reduce(0) { $0 + $1.bytes }, 140, "an hour outside the period is left out")
        }
    }

    Check.suite("Connections — reading the record") {

        func temporaryURL() -> URL {
            URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("connections-test-\(UUID().uuidString).sqlite")
        }

        func remove(_ url: URL) {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let network = NetworkFingerprint(id: "A", kind: .wifi, gatewayMAC: "A", defaultLabel: "Net A",
                                         isExpensive: false, isConstrained: false)
        let teams = AppIdentity(key: "/Applications/Microsoft Teams.app", displayName: "Microsoft Teams",
                                bundlePath: "/Applications/Microsoft Teams.app", isSystem: false)

        Check.test("servers carry the app's name, and hours add up per hour") {
            let url = temporaryURL(); defer { remove(url) }
            let history = UsageHistory(databaseURL: url, calendar: calendar)
            history.join(network, label: "Net A", switched: false, now: reference)
            history.recordApps([(teams, 30, 0)],
                               servers: [teams.key: ["52.112.0.1": ByteCounts(bytesIn: 30, bytesOut: 0)]],
                               now: reference)
            history.recordApps([(teams, 12, 0)],
                               servers: [teams.key: ["52.112.0.1": ByteCounts(bytesIn: 12, bytesOut: 0)]],
                               now: reference + 3_600)
            let day = HistoryPeriod(scale: .day, containing: reference, calendar: calendar)
            let servers = history.servers(in: day)
            Check.expectEqual(servers.first?.appName, "Microsoft Teams")
            Check.expectEqual(servers.first?.bundlePath, teams.bundlePath)
            Check.expectEqual(history.serverHours(from: day.start, to: day.end).map(\.bytes), [30, 12])

            // The timeline's span: only the second hour.
            let second = calendar.dateInterval(of: .hour, for: reference + 3_600)!
            Check.expectEqual(history.servers(from: second.start, to: second.end).first?.bytesIn, 12)
        }

        Check.test("the window's loader delivers the same, off the main thread") {
            let url = temporaryURL(); defer { remove(url) }
            let history = UsageHistory(databaseURL: url, calendar: calendar)
            history.join(network, label: "Net A", switched: false, now: reference)
            history.recordApps([(teams, 30, 0)],
                               servers: [teams.key: ["52.112.0.1": ByteCounts(bytesIn: 30, bytesOut: 0)]],
                               now: reference)
            let day = HistoryPeriod(scale: .day, containing: reference, calendar: calendar)
            var delivered: ServerReport?
            history.loadServers(in: day.interval, hoursOf: day.interval, filter: HistoryFilter()) {
                delivered = $0
            }
            let deadline = Date() + 5
            while delivered == nil && Date() < deadline { RunLoop.main.run(until: Date() + 0.01) }
            Check.expectEqual(delivered?.servers.first?.address, "52.112.0.1")
            Check.expectEqual(delivered?.hours.first?.bytes, 30)
            Check.expectEqual(delivered?.recordingSince, calendar.dateInterval(of: .hour, for: reference)?.start)
        }
    }

    Check.suite("Connections — the map's pulses (#182)") {

        Check.test("live whenever a map someone can see shows traffic now, and only then") {
            let defaults = Check.defaults("connections-live")
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("connections-live-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = UsageStore(storeURL: dir.appendingPathComponent("usage.json"))
            let metering = MeteringController(store: store,
                                              journal: SuppressionJournal(url: dir.appendingPathComponent("journal.json")),
                                              suppressors: [], defaults: defaults)
            let model = ConnectionsViewModel(monitor: MonitorViewModel(store: store, metering: metering),
                                             defaults: defaults)
            model.mapDidAppear()
            Check.expectFalse(model.isLive, "not before the window opens")
            model.windowDidOpen()
            // Opens on Blocked when only what's allowed may connect.
            model.measure = .bytes
            Check.expectTrue(model.isLive)

            // List, then Both: the new map can come before the old one goes.
            model.mapDidDisappear()
            Check.expectFalse(model.isLive, "the list alone")
            model.mapDidAppear()
            model.mapDidAppear()
            model.mapDidDisappear()
            Check.expectTrue(model.isLive, "a map is still showing")

            model.measure = .blocked
            Check.expectFalse(model.isLive, "Blocked isn't traffic as it happens")
            model.measure = .bytes
            model.step(-1)
            Check.expectFalse(model.isLive, "yesterday")
            model.goToPresent()
            Check.expectTrue(model.isLive)

            model.windowIsVisible = false
            Check.expectFalse(model.isLive, "minimised, covered or on another Space")
            model.windowIsVisible = true
            model.windowDidClose()
            Check.expectFalse(model.isLive, "closed")
        }
    }

    Check.suite("Connections — where the map's lines start (#231)") {

        Check.test("Location first, then the Mac's own address, then the Region setting") {
            Check.expectEqual(HomeCountry.first(location: "LB", internetAddress: "DE", region: "US"),
                              HomeCountry(code: "LB", source: .location))
            Check.expectEqual(HomeCountry.first(location: nil, internetAddress: "DE", region: "US"),
                              HomeCountry(code: "DE", source: .internetAddress))
            Check.expectEqual(HomeCountry.first(location: nil, internetAddress: nil, region: "US"),
                              HomeCountry(code: "US", source: .region))
            Check.expectNil(HomeCountry.first(location: nil, internetAddress: nil, region: nil))
        }

        Check.test("a Region that's no country, such as the world, names none") {
            Check.expectNil(HomeCountry.first(location: nil, internetAddress: nil, region: "001"))
            Check.expectEqual(HomeCountry.first(location: "lb", internetAddress: nil, region: "150"),
                              HomeCountry(code: "LB", source: .location))
        }

        Check.test("hovering the starting point says where it came from") {
            Check.expectEqual(HomeCountry(code: "LB", source: .location).description(locale: english),
                              "Your Mac, in Lebanon (from Location)")
            Check.expectEqual(HomeCountry(code: "US", source: .region).description(locale: english),
                              "Your Mac, in United States (from your Mac's Region setting)")
            Check.expectEqual(HomeCountry(code: "DE", source: .internetAddress).description(locale: english),
                              "Your Mac, in Germany (from its internet address)")
        }

        /// Sources whose answers the test gives when it chooses.
        final class Fake {
            var locationAsked = 0, addressAsked = 0
            var location: ((String?) -> Void)?
            var address: ((String?) -> Void)?
            var region: String? = "US"
            var sources: HomeCountryFinder.Sources {
                HomeCountryFinder.Sources(
                    location: { self.locationAsked += 1; self.location = $0 },
                    internetAddress: { self.addressAsked += 1; self.address = $0 },
                    region: { self.region })
            }
        }

        Check.test("Region straight away; Location replaces it when it answers") {
            let fake = Fake()
            let finder = HomeCountryFinder(sources: fake.sources)
            Check.expectEqual(finder.home, HomeCountry(code: "US", source: .region), "before anything is asked")
            finder.refresh()
            Check.expectEqual(finder.home?.source, .region, "while Location works it out")
            fake.address?(nil)
            fake.location?("LB")
            Check.expectEqual(finder.home, HomeCountry(code: "LB", source: .location))
        }

        Check.test("without Location, the Mac's address; without either, the Region setting") {
            let fake = Fake()
            let finder = HomeCountryFinder(sources: fake.sources)
            finder.refresh()
            fake.location?(nil)
            fake.address?("LB")
            Check.expectEqual(finder.home, HomeCountry(code: "LB", source: .internetAddress))

            let behindRouter = Fake()
            let other = HomeCountryFinder(sources: behindRouter.sources)
            other.refresh()
            behindRouter.location?(nil)
            behindRouter.address?(nil)
            Check.expectEqual(other.home, HomeCountry(code: "US", source: .region))
        }

        Check.test("Location wins whichever answers first; withdrawn, the address takes over") {
            var time = Date(timeIntervalSince1970: 0)
            let fake = Fake()
            let finder = HomeCountryFinder(sources: fake.sources, now: { time })
            finder.refresh()
            fake.location?("LB")
            fake.address?("DE")
            Check.expectEqual(finder.home?.code, "LB", "Location before the address, whichever answers first")

            time += HomeCountryFinder.interval + 1
            finder.refresh()
            fake.location?(nil)
            Check.expectEqual(finder.home, HomeCountry(code: "DE", source: .internetAddress))
        }

        Check.test("asked at most every ten minutes, however often the map shows") {
            var time = Date(timeIntervalSince1970: 0)
            let fake = Fake()
            let finder = HomeCountryFinder(sources: fake.sources, now: { time })
            finder.refresh()
            time += 60
            finder.refresh()
            Check.expectEqual(fake.locationAsked, 1)
            Check.expectEqual(fake.addressAsked, 1)
            time += HomeCountryFinder.interval
            finder.refresh()
            Check.expectEqual(fake.locationAsked, 2)
        }

        Check.test("the Region setting is read afresh each time") {
            let fake = Fake()
            let finder = HomeCountryFinder(sources: fake.sources)
            fake.region = "FR"
            finder.refresh()
            Check.expectEqual(finder.home, HomeCountry(code: "FR", source: .region))
        }

        Check.test("the map asks when it appears, through the window's model") {
            let defaults = Check.defaults("connections-home")
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("connections-home-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = UsageStore(storeURL: dir.appendingPathComponent("usage.json"))
            let metering = MeteringController(store: store,
                                              journal: SuppressionJournal(url: dir.appendingPathComponent("journal.json")),
                                              suppressors: [], defaults: defaults)
            let fake = Fake()
            let model = ConnectionsViewModel(monitor: MonitorViewModel(store: store, metering: metering),
                                             defaults: defaults, homeSources: fake.sources)
            Check.expectEqual(model.home?.source, .region)
            Check.expectEqual(fake.locationAsked, 0, "nothing asked until the map shows")
            model.mapDidAppear()
            fake.location?("LB")
            Check.expectEqual(model.home, HomeCountry(code: "LB", source: .location))
        }

        Check.test("only an address the internet sees as it is says where the Mac is") {
            func isPublic(_ text: String) -> Bool { IPAddress(text).map(MacAddresses.isPublic) ?? false }
            Check.expectTrue(isPublic("185.22.12.7"))
            Check.expectTrue(isPublic("2a02:c38:1::5"))
            for address in ["192.168.1.118", "10.0.0.2", "172.20.1.1", "100.64.3.4", "169.254.9.9",
                            "127.0.0.1", "fe80::1", "fd12:3456::1", "2001:db8::1", "2002:c000:204::1",
                            "2001:0:4136::1", "::1"] {
                Check.expectFalse(isPublic(address), address)
            }
        }
    }
}
