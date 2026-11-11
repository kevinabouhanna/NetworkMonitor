import FirewallPolicy
import Foundation
import NetworkMonitorCore

// #254: more lists, downloaded on the Mac from their makers, and any list by
// its address.

func runListLibraryTests() {
    Check.suite("More lists — reading them (#254)") {

        Check.test("Adblock rules: exceptions, site-wide options, and nothing narrower") {
            let parsed = BlocklistParser.read("""
                ! Title: Test filter
                ||ads.example.com^
                ||important.example.com^$important
                ||ends.example.com^|
                @@||cdn.ads.example.com^
                @@||kept.example.com^$important
                ||cancelled.example.com^$badfilter
                ||third.example.com^$third-party
                ||path.example.com/banner.js
                /^139\\.45\\.197\\.2/
                .leading.example.com^
                example.org##.advert
                example.net#@#.advert
                """)
            Check.expectEqual(parsed.title, "Test filter")
            Check.expectEqual(parsed.names, ["ads.example.com", "ends.example.com", "important.example.com"])
            Check.expectEqual(parsed.exceptions, ["cdn.ads.example.com", "kept.example.com"])
            Check.expectEqual(parsed.skipped, 6)
        }

        Check.test("$important outranks the list's exceptions, and $badfilter cancels only its rule (#322)") {
            let list = DownloadedList(id: "test-list", parsed: BlocklistParser.read("""
                ||tracker.example^$important
                @@||tracker.example^
                @@||cdn.tracker.example^
                @@||ok.example^
                ||example.com^
                ||ads.example.com^$badfilter
                ||gone.example^
                ||gone.example^$badfilter
                ||loud.example^$important
                ||loud.example^$important,badfilter
                @@||cdn.example.com^
                @@||cdn.example.com^$badfilter
                """))
            Check.expectTrue(list.lists("tracker.example"))
            Check.expectTrue(list.lists("img.cdn.tracker.example"))
            Check.expectFalse(list.lists("ok.example"))
            // Cancelling ads.example.com's own rule leaves example.com's in force.
            Check.expectTrue(list.lists("ads.example.com"))
            Check.expectFalse(list.lists("gone.example"))
            Check.expectFalse(list.lists("loud.example"))
            Check.expectTrue(list.lists("cdn.example.com"))
            let parsed = BlocklistParser.read("||a.example^$important\n||a.example^\n@@||a.example^$important")
            Check.expectEqual(parsed.names, ["a.example"])
            Check.expectEqual(parsed.exceptions, [])
        }

        Check.test("a page-hiding rule never reads as its site") {
            Check.expectEqual(BlocklistParser.names(in: "youtube.com##.ad-showing\nexample.com"), ["example.com"])
            Check.expectEqual(BlocklistParser.read("# Title: Hosts\n0.0.0.0 a.example # why").title, "Hosts")
        }

        Check.test("the most specific name decides, exception or block") {
            let list = DownloadedList(id: "test-list", parsed: BlocklistParser.read("""
                ||example.com^
                @@||cdn.example.com^
                ||ads.cdn.example.com^
                """))
            Check.expectTrue(list.lists("example.com"))
            Check.expectTrue(list.lists("tracker.example.com"))
            Check.expectFalse(list.lists("cdn.example.com"))
            Check.expectFalse(list.lists("img.cdn.example.com"))
            Check.expectTrue(list.lists("ads.cdn.example.com"))
            Check.expectFalse(list.lists("example.org"))
        }

        Check.test("several lists travel to the filter in one file, and back") {
            let lists = [DownloadedList(id: "hagezi-pro", blocks: BlocklistTable(names: ["a.example", "b.example"])),
                         DownloadedList(id: "url-0a1b2c", blocks: BlocklistTable(names: ["c.example"]),
                                        exceptions: BlocklistTable(names: ["ok.c.example"]))]
            let data = DownloadedList.encode(lists)
            Check.expectEqual(try? DownloadedList.decode(data), lists)
            Check.expectEqual(try? DownloadedList.decode(DownloadedList.encode([])), [])
            Check.expectNil(try? DownloadedList.decode(data.dropLast()))
            Check.expectNil(try? DownloadedList.decode(Data("NMBL".utf8)))
            var extra = data
            extra.append(0)
            Check.expectNil(try? DownloadedList.decode(extra))
        }

        Check.test("ids are safe file names, and never a shipped list's") {
            Check.expectTrue(DownloadedList.isID("hagezi-pro"))
            Check.expectTrue(DownloadedList.isID(ListSource.id(forURL: URL(string: "https://example.com/list.txt")!)))
            Check.expectFalse(DownloadedList.isID("ads"))
            Check.expectFalse(DownloadedList.isID("mine"))
            Check.expectFalse(DownloadedList.isID("../x-y"))
            Check.expectFalse(DownloadedList.isID("Big-List"))
            for source in ListCatalogue.all { Check.expectTrue(DownloadedList.isID(source.id), source.id) }
            Check.expectEqual(Set(ListCatalogue.all.map(\.id)).count, ListCatalogue.all.count)
            // #287: nothing that would stop encrypted DNS.
            Check.expectFalse(ListCatalogue.all.contains { $0.url.absoluteString.contains("doh") })
        }
    }

    Check.suite("More lists — what they block (#254)") {
        func flow(_ name: String, listedIn: Set<BlocklistTopic> = [], downloaded: [String] = []) -> FlowFacts {
            FlowFacts(appKeys: ["/Applications/Safari.app"], companyKey: nil, country: nil, address: "203.0.113.9",
                      port: 443, isApple: false, hostname: name, listedIn: listedIn, listedInDownloaded: downloaded)
        }

        Check.test("a downloaded list blocks while ad blocking is on, after the shipped lists") {
            let policy = FirewallPolicy(lists: [.ads, .malware], downloadedLists: ["oisd-small", "hagezi-pro"])
            Check.expectEqual(policy.decide(flow("t.example", downloaded: ["hagezi-pro", "oisd-small"])),
                              .block(.downloadedList("oisd-small")))
            Check.expectEqual(policy.decide(flow("t.example", listedIn: [.ads], downloaded: ["hagezi-pro"])),
                              .block(.list(.ads)))
            Check.expectEqual(policy.decide(flow("t.example", downloaded: ["peter-lowe"])), .allow(.mode))
            Check.expectEqual(BlockReason.downloadedList("hagezi-pro").id, "list:hagezi-pro")
            Check.expectEqual(BlockReason.list(inReport: "list:hagezi-pro"), "hagezi-pro")
        }

        Check.test("your never-block rule lets it through; with ad blocking off, nothing blocks") {
            var policy = FirewallPolicy(lists: [.ads], downloadedLists: ["hagezi-pro"])
            policy.adRules = [AdRule(kind: .neverBlock, site: "t.example")]
            Check.expectEqual(policy.decide(flow("t.example", downloaded: ["hagezi-pro"])), .allow(.mode))
            let off = FirewallPolicy(lists: [], downloadedLists: ["hagezi-pro"])
            Check.expectEqual(off.decide(flow("t.example", downloaded: ["hagezi-pro"])), .allow(.mode))
        }

        Check.test("a policy from before #254 reads with no downloaded lists") {
            let old = Data(#"{"mode":"anywhere","rules":[],"lists":["ads"]}"#.utf8)
            Check.expectEqual(FirewallPolicy.decode(old)?.downloadedLists, [])
            let policy = FirewallPolicy(lists: [.ads], downloadedLists: ["hagezi-light"])
            Check.expectEqual(FirewallPolicy.decode(policy.encoded()), policy)
        }
    }

    Check.suite("More lists — keeping them (#254)") {
        func library() -> (ListLibrary, URL) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lists-\(UUID().uuidString)")
            let library = ListLibrary(defaults: Check.defaults("lists"),
                                      directory: directory)
            library.mayDownload = { false }
            return (library, directory)
        }

        Check.test("only an https address is added, and only once") {
            let (library, _) = library()
            Check.expectEqual(library.add("http://example.com/list.txt"), .failure(.notAnAddress))
            Check.expectEqual(library.add("not an address"), .failure(.notAnAddress))
            let added = library.add(" https://lists.example.com/hosts.txt ")
            guard case .success(let id) = added else { Check.expectTrue(false, "not added"); return }
            Check.expectTrue(library.isEnabled(id))
            Check.expectEqual(library.source(id)?.title, "lists.example.com")
            Check.expectEqual(library.add("https://lists.example.com/hosts.txt"),
                              .failure(.alreadyThere("lists.example.com")))
            let catalogued = ListCatalogue.source("hagezi-pro")!.url.absoluteString
            Check.expectEqual(library.add(catalogued), .failure(.alreadyThere("HaGeZi Pro")))
            library.remove(id)
            Check.expectNil(library.source(id))
            Check.expectFalse(library.isEnabled(id))
        }

        Check.test("on a hotspot, a new list waits rather than downloading") {
            let (library, _) = library()
            library.setEnabled("hagezi-light", true)
            Check.expectTrue(library.isEnabled("hagezi-light"))
            Check.expectEqual(library.ready, [], "no copy yet")
            Check.expectTrue(library.status["hagezi-light"]?.error?.contains("hotspot") == true)
            Check.expectNil(library.status["hagezi-light"]?.checked, "waiting isn't a failed try")
        }

        Check.test("a download that isn't a list of sites keeps nothing") {
            guard case .failed(let reason) = ListLibrary.read(Data("example.org##.advert\n".utf8)) else {
                Check.expectTrue(false, "read as a list"); return
            }
            Check.expectTrue(reason.contains("Chrome extension"))
            guard case .failed = ListLibrary.read(Data("<html><body>Not found</body></html>".utf8)) else {
                Check.expectTrue(false, "read as a list"); return
            }
            guard case .list(let parsed) = ListLibrary.read(Data("0.0.0.0 ads.example.com\n".utf8)) else {
                Check.expectTrue(false, "not read"); return
            }
            Check.expectEqual(parsed.names, ["ads.example.com"])
        }

        Check.test("weekly, and a failed try waits most of a day") {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let day: TimeInterval = 24 * 60 * 60
            Check.expectTrue(ListLibrary.isDue(nil, hasCopy: false, now: now))
            Check.expectFalse(ListLibrary.isDue(ListStatus(names: 5, updated: now - 6 * day, checked: now - 6 * day),
                                                hasCopy: true, now: now))
            Check.expectTrue(ListLibrary.isDue(ListStatus(names: 5, updated: now - 8 * day, checked: now - 8 * day),
                                               hasCopy: true, now: now))
            Check.expectFalse(ListLibrary.isDue(ListStatus(updated: nil, checked: now - 3600, error: "503"),
                                                hasCopy: false, now: now))
            Check.expectTrue(ListLibrary.isDue(ListStatus(updated: nil, checked: now - day, error: "503"),
                                               hasCopy: false, now: now))
            Check.expectTrue(ListLibrary.isDue(ListStatus(error: "Waiting"), hasCopy: false, now: now))
        }

        Check.test("added lists go by their own name in the Ads window") {
            let (library, _) = library()
            guard case .success(let id) = library.add("https://named.example.com/list.txt") else { return }
            Check.expectEqual(AdsReport.title(ofList: id), "named.example.com")
            Check.expectEqual(AdsReport.title(ofList: "hagezi-pro"), "HaGeZi Pro")
            Check.expectEqual(AdsReport.title(ofList: "ads"), BlocklistTopic.ads.title)
        }
    }

    Check.suite("More lists — recommended (#314)") {
        func library(_ defaults: UserDefaults = Check.defaults("lists"))
            -> ListLibrary {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lists-\(UUID().uuidString)")
            let library = ListLibrary(defaults: defaults, directory: directory)
            library.mayDownload = { false }
            return library
        }

        Check.test("the recommended pair are lists the catalogue has") {
            Check.expectEqual(ListCatalogue.recommended.count, 2)
            Check.expectTrue(ListCatalogue.recommended.allSatisfy { ListCatalogue.source($0)?.topic == .ads })
        }

        Check.test("a new install starts on the recommended lists") {
            let library = library()
            Check.expectTrue(library.usesRecommended)
            Check.expectEqual(library.enabled, ListCatalogue.recommended)
        }

        Check.test("lists chosen before #314 stay chosen") {
            let defaults = Check.defaults("lists")
            defaults.set(["hagezi-pro", "adguard-dns"], forKey: ListLibrary.enabledKey)
            let library = library(defaults)
            Check.expectFalse(library.usesRecommended)
            Check.expectEqual(library.enabled, ["hagezi-pro", "adguard-dns"])
        }

        Check.test("switching a list by hand makes it your own choice, from the lists in use") {
            let library = library()
            library.setEnabled("peter-lowe", true)
            Check.expectFalse(library.usesRecommended)
            Check.expectEqual(library.enabled, ListCatalogue.recommended + ["peter-lowe"])
        }

        Check.test("Recommended and back finds your own choice as you left it") {
            let defaults = Check.defaults("lists")
            let first = library(defaults)
            first.setUsesRecommended(false)
            Check.expectEqual(first.enabled, [], "nothing chosen yet")
            first.setEnabled("hagezi-light", true)
            first.setUsesRecommended(true)
            Check.expectEqual(first.enabled, ListCatalogue.recommended)
            let relaunched = library(defaults)
            Check.expectTrue(relaunched.usesRecommended)
            relaunched.setUsesRecommended(false)
            Check.expectEqual(relaunched.enabled, ["hagezi-light"])
        }

        Check.test("adding a list by its address is your own choice") {
            let library = library()
            guard case .success(let id) = library.add("https://more.example.com/hosts.txt") else { return }
            Check.expectFalse(library.usesRecommended)
            Check.expectTrue(library.isEnabled(id))
            library.setUsesRecommended(true)
            library.remove(id)
            library.setUsesRecommended(false)
            Check.expectFalse(library.chosen.contains(id), "a removed list leaves your choice too")
        }
    }

    Check.suite("More lists — what the filter is sent (#352)") {
        Check.test("a choice changed while the app was closed reaches the filter at start") {
            let defaults = Check.defaults("lists")
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lists-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            func copy(_ id: String, _ name: String) -> DownloadedList {
                let list = DownloadedList(id: id, parsed: BlocklistParser.read(name))
                try? DownloadedList.encode([list]).write(to: directory.appendingPathComponent(id + ".nmdl"))
                return list
            }
            let own = copy("hagezi-pro", "pro.example.com")
            for id in ListCatalogue.recommended { _ = copy(id, "\(id).example.com") }
            let bundle = directory.appendingPathComponent("Enabled.nmdl")
            try? DownloadedList.encode([own]).write(to: bundle)
            defaults.set(["hagezi-pro"], forKey: ListLibrary.enabledKey)
            defaults.set(true, forKey: ListLibrary.recommendedKey)

            let library = ListLibrary(defaults: defaults, directory: directory)
            library.mayDownload = { false }
            var sent = 0
            library.onChange = { _, _ in sent += 1 }
            library.bringBundleUpToDate()
            let ids = (try? DownloadedList.decode(Data(contentsOf: bundle)))?.map(\.id) ?? []
            Check.expectEqual(ids, ListCatalogue.recommended)
            Check.expectEqual(sent, 1)

            library.bringBundleUpToDate()
            Check.expectEqual(sent, 1, "up to date: not sent again")
        }

        Check.test("with no lists and no file, nothing is sent") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lists-\(UUID().uuidString)")
            let defaults = Check.defaults("lists")
            defaults.set(false, forKey: ListLibrary.recommendedKey)
            let library = ListLibrary(defaults: defaults, directory: directory)
            var sent = 0
            library.onChange = { _, _ in sent += 1 }
            library.bringBundleUpToDate()
            Check.expectEqual(sent, 0)
        }
    }
}
