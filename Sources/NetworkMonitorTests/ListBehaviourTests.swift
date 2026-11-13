import Foundation
import NetworkMonitorCore
import ServerDirectory

/// The main window's three lists open, close and filter alike (#593): a click
/// shows only that row, the ▸ opens it, Escape lets go, and what a list opens
/// by itself it closes again.
func runListBehaviourTests() {
    let reference = Date(timeIntervalSince1970: 1_792_573_800)

    Check.suite("Lists — what opens by itself (#593)") {
        Check.test("closes what it opened, and leaves what the person opened or closed") {
            var open: Set<String> = ["mine"]
            var opened = OpenedByItself()
            opened.open("mine", in: &open)
            opened.open("chosen", in: &open)
            opened.open("other", in: &open)
            Check.expectEqual(open, ["mine", "chosen", "other"])
            opened.handOver("other")          // closed and opened again by hand
            opened.close(in: &open)
            Check.expectEqual(open, ["mine", "other"], "only what it opened itself closes")
        }

        // The list is read again every 30 s: a row the person closed must
        // stay closed.
        Check.test("opens a row once, until it's closed again") {
            var open: Set<String> = []
            var opened = OpenedByItself()
            opened.openOnce("Teams", in: &open)
            opened.handOver("Teams")
            open.remove("Teams")
            opened.openOnce("Teams", in: &open)
            Check.expectEqual(open, [], "opened again after the person closed it")
            opened.close(in: &open)
            opened.openOnce("Teams", in: &open)
            Check.expectEqual(open, ["Teams"], "a new search opens it again")
        }

        Check.test("search opens a row found by what's inside it, not by its own name") {
            Check.expectTrue(OpenedByItself.matchesInside("Terminal", parts: ["git", "curl"], query: "gi"))
            Check.expectFalse(OpenedByItself.matchesInside("Terminal", parts: ["git"], query: "term"),
                              "its own name matches: nothing to show inside")
            Check.expectFalse(OpenedByItself.matchesInside("Terminal", parts: ["git"], query: "  "))
            let site = AdsItem(id: "doubleclick.net", title: "doubleclick.net", detail: "securepubads.g.doubleclick.net",
                               count: 9, lists: ["ads"],
                               children: [AdsItem(id: "/Applications/Safari.app", title: "Safari", detail: nil,
                                                  count: 9, lists: ["ads"])])
            Check.expectTrue(AdsViewModel.matchesInside(site, "safari"))
            Check.expectFalse(AdsViewModel.matchesInside(site, "securepubads"), "a name under the site is its own")
        }

        Check.test("a row chosen inside another keeps only it") {
            let app = AdsItem(id: "chrome", title: "Google Chrome", detail: nil, count: 30, lists: ["ads"], children: [
                AdsItem(id: "doubleclick.net", title: "doubleclick.net", detail: nil, count: 20, lists: ["ads"]),
                AdsItem(id: "bing.com", title: "bing.com", detail: nil, count: 10, lists: ["ads"]),
            ])
            let kept = app.keeping("bing.com")
            Check.expectEqual(kept.children.map(\.id), ["bing.com"])
            Check.expectEqual(kept.count, 30, "the row's own count stays")
        }
    }

    func owner(_ company: String) -> NetworkOwner {
        NetworkOwner(asn: 64_512, registeredName: "\(company) Inc.", company: Company(name: company, isHost: false))
    }
    func connection(_ app: String, _ address: String, _ bytes: Int64, country: String, owner: NetworkOwner) -> Connection {
        Connection(usage: ServerUsage(appKey: app, address: address, bytesIn: bytes, bytesOut: 0,
                                      firstSeen: reference, appName: app, parentName: nil),
                   country: country, owner: owner)
    }
    let sample = [
        connection("Teams", "52.112.0.1", 500, country: "NL", owner: owner("Microsoft")),
        connection("Teams", "52.113.0.1", 300, country: "IE", owner: owner("Microsoft")),
        connection("Chrome", "142.250.0.1", 450, country: "US", owner: owner("Google")),
        connection("Safari", "142.250.0.2", 100, country: "US", owner: owner("Google")),
    ]

    Check.suite("Lists — Connections (#593)") {
        let defaults = Check.defaults("connections-lists")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lists-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UsageStore(storeURL: dir.appendingPathComponent("usage.json"))
        let metering = MeteringController(store: store,
                                          journal: SuppressionJournal(url: dir.appendingPathComponent("journal.json")),
                                          suppressors: [], defaults: defaults)
        let monitor = MonitorViewModel(store: store, metering: metering)
        // A list of its own for each test, read from the sample rather than a
        // record, with nothing chosen or open.
        var model = ConnectionsViewModel(monitor: monitor, defaults: defaults)
        func reset() {
            model = ConnectionsViewModel(monitor: monitor, defaults: defaults)
            model.showConnections(sample)
        }

        Check.test("a click on a company shows only it, open and marked; a second lets it go and closes it") {
            reset()
            guard let microsoft = model.groups.first(where: { $0.item.title == "Microsoft" })?.item else {
                return Check.expectTrue(false, "no Microsoft in \(model.groups.map(\.item.title))")
            }
            model.choose(microsoft)
            Check.expectEqual(model.groups.map(\.item.title), ["Microsoft"])
            Check.expectTrue(model.isChosen(microsoft))
            Check.expectTrue(model.expanded.contains(microsoft.id), "the one left didn't open")
            Check.expectTrue(model.canGoBack)
            model.choose(microsoft)
            Check.expectEqual(model.groups.count, 2)
            Check.expectFalse(model.expanded.contains(microsoft.id), "what choosing opened stayed open")
            Check.expectFalse(model.canGoBack)
        }

        Check.test("a row inside chosen twice lets go of it and keeps the company") {
            reset()
            guard let group = model.groups.first(where: { $0.item.title == "Microsoft" }),
                  let ireland = group.sections.first(where: { $0.dimension == .country })?.items
                      .first(where: { $0.key == "IE" }) else {
                return Check.expectTrue(false, "no Ireland under Microsoft")
            }
            model.narrow(to: ireland, in: group.item)
            Check.expectEqual(model.chips.map(\.title), ["Microsoft", ireland.title])
            Check.expectTrue(model.isChosen(ireland))
            model.narrow(to: ireland, in: group.item)
            Check.expectEqual(model.chips.map(\.title), ["Microsoft"])
        }

        Check.test("Escape lets go of the narrowest chip first") {
            reset()
            guard let group = model.groups.first(where: { $0.item.title == "Microsoft" }),
                  let teams = group.sections.first(where: { $0.dimension == .app })?.items.first else {
                return Check.expectTrue(false, "no Teams under Microsoft")
            }
            model.narrow(to: teams, in: group.item)
            model.goBack()
            Check.expectEqual(model.chips.map(\.title), ["Microsoft"])
            model.goBack()
            Check.expectEqual(model.chips.count, 0)
            Check.expectFalse(model.canGoBack, "Escape would be taken from search with nothing to let go")
        }

        Check.test("a company closed by hand stays closed while it's chosen") {
            reset()
            guard let google = model.groups.first(where: { $0.item.title == "Google" })?.item else {
                return Check.expectTrue(false, "no Google")
            }
            model.choose(google)
            model.setExpanded(google.id, false)
            model.showConnections(sample)      // read again, as every 30 s
            Check.expectFalse(model.expanded.contains(google.id), "it opened again by itself")
        }

        Check.test("what's open stays open across groupings") {
            reset()
            guard let google = model.groups.first(where: { $0.item.title == "Google" })?.item else {
                return Check.expectTrue(false, "no Google")
            }
            model.setExpanded(google.id, true)
            model.grouping = .apps
            model.grouping = .companies
            Check.expectTrue(model.expanded.contains(google.id), "switching grouping closed it")
        }

        // "e" is in Teams' and Chrome's names, and only in what's inside
        // Safari (Google, the United States).
        Check.test("search opens a group found by what's inside it, and closes it once cleared") {
            reset()
            model.grouping = .apps
            model.search = "e"
            let open = Set(model.groups.filter { model.expanded.contains($0.id) }.map(\.item.title))
            Check.expectEqual(open, ["Safari"])
            model.search = ""
            Check.expectTrue(model.expanded.isEmpty, "still open: \(model.expanded)")
        }
    }

    Check.suite("Lists — Usage History (#593)") {
        let defaults = Check.defaults("history-lists")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("history-lists-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UsageStore(storeURL: dir.appendingPathComponent("usage.json"))
        let metering = MeteringController(store: store,
                                          journal: SuppressionJournal(url: dir.appendingPathComponent("journal.json")),
                                          suppressors: [], defaults: defaults)
        let model = HistoryViewModel(monitor: MonitorViewModel(store: store, metering: metering), defaults: defaults)

        Check.test("Escape lets go of a visit, then a network, then an app") {
            model.toggleApp("/Applications/Safari.app")
            model.toggleNetwork("home")
            Check.expectTrue(model.canGoBack)
            model.goBack()
            Check.expectNil(model.filter.networkID, "the network wasn't let go of first")
            Check.expectEqual(model.filter.appKey, "/Applications/Safari.app")
            model.goBack()
            Check.expectNil(model.filter.appKey)
            Check.expectFalse(model.canGoBack)
        }

        Check.test("System opens and closes, by hand") {
            model.setExpanded(HistoryViewModel.systemID, true)
            Check.expectTrue(model.systemExpanded)
            model.toggleExpanded(HistoryViewModel.systemID)
            Check.expectFalse(model.systemExpanded)
        }
    }
}
