import CryptoKit
import FirewallPolicy
import Foundation
import NetworkMonitorCore

// #176: ad, tracker and malware lists, matched by name in the content filter.

func runBlocklistTests() {
    let lists = Blocklists(tables: [.ads: BlocklistTable(names: ["doubleclick.net", "ads.example.com"]),
                                    .malware: BlocklistTable(names: ["evil.example", "ads.example.com"])],
                           version: "2026-10-31")

    Check.suite("Blocklists — reading published lists (#176)") {

        Check.test("hosts files, plain lists and Adblock domain rules") {
            let text = """
                # StevenBlack-style header
                127.0.0.1 localhost
                0.0.0.0 0.0.0.0
                0.0.0.0 ads.example.com   # inline comment
                0.0.0.0 Tracker.Example.NET tracker2.example.net
                ::1 ip6-localhost
                plain.example.org
                ||adblock.example.com^
                ||withpath.example.com^$third-party
                ! an Adblock comment
                [Adblock Plus 2.0]
                192.168.1.1
                not a name
                0.0.0.0 bad_ünicode.example
                """
            Check.expectEqual(BlocklistParser.names(in: text),
                              ["ads.example.com", "tracker.example.net", "tracker2.example.net", "plain.example.org",
                               "adblock.example.com"])
        }

        Check.test("a table reads back exactly, and refuses what isn't one") {
            let table = BlocklistTable(names: ["a.example", "b.example", "a.example"])
            Check.expectEqual(table.count, 2)
            Check.expectEqual(try? BlocklistTable(data: table.encoded()), table)
            Check.expectTrue(table.contains("a.example"))
            Check.expectFalse(table.contains("c.example"))
            Check.expectNil(try? BlocklistTable(data: Data("NMBL".utf8)))
            var truncated = table.encoded()
            truncated.removeLast()
            Check.expectNil(try? BlocklistTable(data: truncated))
            Check.expectNil(try? BlocklistTable(data: Data("not a list at all".utf8)))
        }

        Check.test("a name is listed by itself or a domain above it, never by a bare suffix") {
            Check.expectEqual(lists.topics(listing: "static.doubleclick.net"), [.ads])
            Check.expectEqual(lists.topics(listing: "doubleclick.net"), [.ads])
            Check.expectEqual(lists.topics(listing: "notdoubleclick.net"), [])
            Check.expectEqual(lists.topics(listing: "ads.example.com"), [.ads, .malware])
            Check.expectEqual(lists.topics(listing: "example.com"), [], "a list holding a subdomain doesn't list its site")
            let suffixes = Blocklists(tables: [.ads: BlocklistTable(names: ["com", "co.uk"])], version: "2026-10-31")
            Check.expectEqual(suffixes.topics(listing: "www.apple.com"), [])
            Check.expectEqual(suffixes.topics(listing: "www.bbc.co.uk"), [])
            Check.expectEqual(lists.topics(listing: "142.251.39.174"), [])
        }

        Check.test("the newest copy on disk wins, the first listed breaking a tie") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("lists-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            func write(_ name: String, _ version: String) -> URL {
                let directory = root.appendingPathComponent(name)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for topic in BlocklistTopic.allCases {
                    try? BlocklistTable(names: [name + ".example"]).encoded()
                        .write(to: directory.appendingPathComponent(topic.fileName))
                }
                try? Data(version.utf8).write(to: directory.appendingPathComponent(Blocklists.versionFile))
                return directory
            }
            let shipped = write("shipped", "2026-10-31")
            let older = write("older", "2026-10-24")
            let newer = write("newer", "2026-11-07")
            let broken = root.appendingPathComponent("broken")
            Check.expectEqual(Blocklists.newest([shipped, older])?.directory, shipped)
            Check.expectEqual(Blocklists.newest([shipped, newer])?.directory, newer)
            Check.expectEqual(Blocklists.newest([shipped, write("same", "2026-10-31")])?.directory, shipped)
            Check.expectEqual(Blocklists.newest([broken, older])?.directory, older)
        }
    }

    Check.suite("Blocklists — what the filter decides (#176)") {
        let chromeToAds = FlowFacts(appKeys: ["/Applications/Google Chrome.app"], companyKey: "Google", country: "US",
                                    address: "142.251.39.174", port: 443, isApple: false,
                                    hostname: "static.doubleclick.net", listedIn: [.ads])

        Check.test("a listed site is blocked only while its list is on") {
            Check.expectEqual(FirewallPolicy().decide(chromeToAds), .allow(.mode))
            Check.expectEqual(FirewallPolicy(lists: [.malware]).decide(chromeToAds), .allow(.mode))
            Check.expectEqual(FirewallPolicy(lists: [.ads]).decide(chromeToAds), .block(.list(.ads)))
            Check.expectEqual(BlockReason.list(.ads).id, "list:ads")
            Check.expectTrue(FirewallPolicy(lists: [.ads]).isActive)
        }

        Check.test("your rules come first: Always Allow lets a listed site through") {
            let allow = FirewallRule(subject: .site, key: "doubleclick.net", title: "*.doubleclick.net", action: .allow)
            Check.expectEqual(FirewallPolicy(rules: [allow], lists: [.ads]).decide(chromeToAds), .allow(.rule(allow)))
            let block = FirewallRule(subject: .app, key: "/Applications/Google Chrome.app", title: "Chrome", action: .block)
            Check.expectEqual(FirewallPolicy(rules: [block], lists: [.ads]).decide(chromeToAds), .block(.rule(block)))
        }

        Check.test("a name on both lists is blocked as malware") {
            var both = chromeToAds
            both.listedIn = [.ads, .malware]
            Check.expectEqual(FirewallPolicy(lists: [.ads, .malware]).decide(both), .block(.list(.malware)))
        }

        Check.test("a policy saved before the lists reads them as off, and new ones survive the trip") {
            let old = Data(#"{"mode":"anywhere","rules":[],"onHotspot":true,"pausesUpdates":false}"#.utf8)
            let decoded = FirewallPolicy.decode(old)
            Check.expectEqual(decoded?.lists, [])
            Check.expectEqual(decoded?.onHotspot, true)
            let policy = FirewallPolicy(lists: [.ads, .malware])
            Check.expectEqual(FirewallPolicy.decode(policy.encoded()), policy)
        }
    }

    Check.suite("Blocklists — the weekly refresh (#176)") {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        func signed(_ data: Data, with signer: Curve25519.Signing.PrivateKey) -> Data {
            Data(((try? signer.signature(for: data)) ?? Data()).base64EncodedString().utf8)
        }
        let files = BlocklistTopic.allCases.map {
            BlocklistManifest.File(name: $0.fileName, asset: $0.fileName + ".lzfse", size: 20, sha256: "00")
        }
        let manifest = try! JSONEncoder().encode(BlocklistManifest(version: "2026-11-07", files: files))

        Check.test("a manifest signed by the key is read; anything else is refused") {
            Check.expectEqual(try? BlocklistUpdater.verify(manifest, signature: signed(manifest, with: key),
                                                           publicKey: publicKey).version, "2026-11-07")
            Check.expectNil(try? BlocklistUpdater.verify(manifest, signature: signed(manifest, with: .init()),
                                                         publicKey: publicKey))
            var tampered = manifest
            tampered[tampered.startIndex] = UInt8(ascii: " ")
            Check.expectNil(try? BlocklistUpdater.verify(tampered, signature: signed(manifest, with: key),
                                                         publicKey: publicKey))
        }

        // The lists are signed with the country data's key: one manifest
        // mustn't pass for the other.
        Check.test("a signed country-data manifest isn't a list manifest") {
            let geo = try! JSONEncoder().encode(GeoDataManifestStandIn(month: "2026-11", files: []))
            Check.expectNil(try? BlocklistUpdater.verify(geo, signature: signed(geo, with: key), publicKey: publicKey))
        }

        Check.test("checked only while the lists are on, stale, and not checked lately") {
            let now = BlocklistUpdater.dateFormatter.date(from: "2026-11-10")!
            Check.expectFalse(BlocklistUpdater.isDue(enabled: true, wanted: false, version: "2026-10-01",
                                                     lastChecked: nil, now: now), "lists off")
            Check.expectFalse(BlocklistUpdater.isDue(enabled: false, wanted: true, version: "2026-10-01",
                                                     lastChecked: nil, now: now), "updates off")
            Check.expectTrue(BlocklistUpdater.isDue(enabled: true, wanted: true, version: "2026-10-31",
                                                    lastChecked: nil, now: now), "ten days old")
            Check.expectFalse(BlocklistUpdater.isDue(enabled: true, wanted: true, version: "2026-11-07",
                                                     lastChecked: nil, now: now), "three days old")
            Check.expectFalse(BlocklistUpdater.isDue(enabled: true, wanted: true, version: "2026-10-31",
                                                     lastChecked: now.addingTimeInterval(-3600), now: now),
                              "checked an hour ago")
        }

        Check.test("today's count starts again tomorrow") {
            let defaults = UserDefaults(suiteName: "list-blocks-\(UUID().uuidString)")!
            let calendar = Calendar(identifier: .gregorian)
            let day = BlocklistUpdater.dateFormatter.date(from: "2026-11-10")!
            let count = ListBlockCount(defaults: defaults, calendar: calendar, now: day)
            count.add(3, now: day)
            count.add(2, now: day.addingTimeInterval(3600))
            Check.expectEqual(count.today, 5)
            Check.expectEqual(ListBlockCount(defaults: defaults, calendar: calendar, now: day).today, 5)
            Check.expectEqual(ListBlockCount(defaults: defaults, calendar: calendar,
                                             now: day.addingTimeInterval(86_400)).today, 0)
            count.add(1, now: day.addingTimeInterval(86_400))
            Check.expectEqual(count.today, 1)
        }
    }

    Check.suite("Blocklists — the copy in the app (#176)") {
        let shipped = URL(fileURLWithPath: "Resources/Blocklists", isDirectory: true)

        Check.test("is complete and reads") {
            let copy = Blocklists(directory: shipped)
            Check.expectNotNil(copy)
            Check.expectTrue((copy?.tables[.ads]?.count ?? 0) > 20_000, "ads")
            Check.expectTrue((copy?.tables[.malware]?.count ?? 0) > 100, "malware")
        }

        // What a list must never catch: if one ever does, it fails here
        // before it ships in the app.
        Check.test("holds ad servers, and none of the sites people use every day") {
            guard let copy = Blocklists(directory: shipped) else { return Check.expectTrue(false, "no copy") }
            for name in ["static.doubleclick.net", "securepubads.g.doubleclick.net", "aax.amazon-adsystem.com"] {
                Check.expectTrue(copy.topics(listing: name).contains(.ads), name)
            }
            for name in ["www.google.com", "www.youtube.com", "www.apple.com", "github.com", "api.github.com",
                         "slack.com", "app.slack.com", "www.wikipedia.org", "www.nytimes.com", "www.bbc.co.uk",
                         "login.microsoftonline.com", "www.figma.com", "claude.ai", "api.anthropic.com",
                         "raw.githubusercontent.com", "objects.githubusercontent.com", "dns.google",
                         "one.one.one.one", "update.googleapis.com", "www.gstatic.com"] {
                Check.expectEqual(copy.topics(listing: name), [], name)
            }
        }
    }
}

/// The shape of the country data's manifest, signed with the same key.
private struct GeoDataManifestStandIn: Codable {
    let month: String
    let files: [String]
}
