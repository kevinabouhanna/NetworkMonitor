import CryptoKit
import FirewallPolicy
import Foundation
import NetworkMonitorCore
import ServerDirectory

func runGeoDataTests() {
    func temporaryDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("geodata-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A small table that opens: one IPv4 range labelled `label`.
    func table(_ label: String) -> Data {
        var writer = RangeTableWriter()
        try? writer.add(from: IPAddress("1.0.0.0")!, to: IPAddress("1.0.0.255")!, label: label)
        return writer.encoded()
    }

    /// A copy of the data in `directory`, for `month`.
    func copy(in directory: URL, month: String) {
        for name in GeoData.tables { try? table(name).write(to: directory.appendingPathComponent(name)) }
        try? Data((month + "\n").utf8).write(to: directory.appendingPathComponent(GeoData.monthFile))
    }

    func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    Check.suite("Data refresh (#121) — which copy") {

        Check.test("the newest month wins, the shipped copy breaking a tie") {
            let shipped = temporaryDirectory(), downloaded = temporaryDirectory()
            defer { [shipped, downloaded].forEach { try? FileManager.default.removeItem(at: $0) } }
            copy(in: shipped, month: "2026-10")
            copy(in: downloaded, month: "2026-11")
            Check.expectEqual(GeoData.newest([shipped, downloaded]), downloaded)
            copy(in: downloaded, month: "2026-10")
            Check.expectEqual(GeoData.newest([shipped, downloaded]), shipped, "a tie")
            copy(in: downloaded, month: "2026-09")
            Check.expectEqual(GeoData.newest([shipped, downloaded]), shipped, "an older download, after an update")
        }

        Check.test("a copy missing a table or a month isn't one") {
            let shipped = temporaryDirectory(), broken = temporaryDirectory()
            defer { [shipped, broken].forEach { try? FileManager.default.removeItem(at: $0) } }
            copy(in: shipped, month: "2026-10")
            copy(in: broken, month: "2026-12")
            try? FileManager.default.removeItem(at: broken.appendingPathComponent("owners.bin"))
            Check.expectEqual(GeoData.newest([shipped, broken]), shipped)
            Check.expectTrue(GeoData.isMonth("2026-11"))
            Check.expectFalse(GeoData.isMonth("2026-1"))
            Check.expectFalse(GeoData.isMonth("../../etc"))
        }

        Check.test("the month reads as a person would say it") {
            Check.expectEqual(ConnectionsGlance.dataSource(month: "2026-10").hasPrefix("DB-IP Lite, "), true)
            Check.expectTrue(ConnectionsGlance.dataSource(month: "2026-10").contains("2026"))
            Check.expectEqual(ConnectionsGlance.dataSource(month: nil), "DB-IP Lite")
        }
    }

    Check.suite("Data refresh (#121) — trusting a download") {

        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let countries = table("countries"), owners = table("owners")
        let manifest = GeoDataManifest(month: "2026-11", files: [
            .init(name: "countries.bin", asset: "countries.bin.lzfse", size: countries.count, sha256: digest(countries)),
            .init(name: "owners.bin", asset: "owners.bin.lzfse", size: owners.count, sha256: digest(owners)),
        ])
        let manifestData = (try? JSONEncoder().encode(manifest)) ?? Data()
        let signature = Data(((try? key.signature(for: manifestData)) ?? Data()).base64EncodedString().utf8)

        Check.test("a manifest signed by the key is read; anything else is refused") {
            Check.expectEqual(try? GeoDataUpdater.verify(manifestData, signature: signature, publicKey: publicKey),
                              manifest)
            var tampered = manifestData
            tampered[tampered.count / 2] ^= 1
            Check.expectNil(try? GeoDataUpdater.verify(tampered, signature: signature, publicKey: publicKey),
                            "one bit changed")
            let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
            Check.expectNil(try? GeoDataUpdater.verify(manifestData, signature: signature, publicKey: other),
                            "someone else's key")
            Check.expectNil(try? GeoDataUpdater.verify(manifestData, signature: Data("nonsense".utf8),
                                                       publicKey: publicKey))
        }

        Check.test("the app's key is a real Ed25519 public key") {
            let raw = Data(base64Encoded: GeoDataUpdater.publicKey)
            Check.expectNotNil(raw.flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) })
        }

        Check.test("even signed, a manifest names exactly the tables, and no paths") {
            Check.expectTrue(manifest.isWellFormed)
            let sneaky = GeoDataManifest(month: "2026-11", files: [
                .init(name: "countries.bin", asset: "../countries.bin", size: 1, sha256: ""),
                .init(name: "owners.bin", asset: "owners.bin.lzfse", size: 1, sha256: ""),
            ])
            Check.expectFalse(sneaky.isWellFormed)
            Check.expectFalse(GeoDataManifest(month: "2026-11", files: [manifest.files[0]]).isWellFormed, "one table")
            Check.expectFalse(GeoDataManifest(month: "soon", files: manifest.files).isWellFormed)
        }

        Check.test("each table must be the size and digest the manifest says") {
            let compressed = try? (countries as NSData).compressed(using: .lzfse) as Data
            Check.expectEqual(try? GeoDataUpdater.decompress(compressed ?? Data(), as: manifest.files[0]), countries)
            let wrong = GeoDataManifest.File(name: "countries.bin", asset: "x", size: countries.count,
                                             sha256: digest(owners))
            Check.expectNil(try? GeoDataUpdater.decompress(compressed ?? Data(), as: wrong), "another file's digest")
            Check.expectNil(try? GeoDataUpdater.decompress(Data("not lzfse".utf8), as: manifest.files[0]))
        }

        Check.test("a new month goes in whole, over the last one") {
            let parent = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: parent) }
            let destination = parent.appendingPathComponent("Geo")
            try? GeoDataUpdater.install(["countries.bin": countries, "owners.bin": owners], month: "2026-11",
                                        at: destination)
            Check.expectEqual(GeoData.month(in: destination), "2026-11")
            try? GeoDataUpdater.install(["countries.bin": countries, "owners.bin": owners], month: "2026-12",
                                        at: destination)
            Check.expectEqual(GeoData.month(in: destination), "2026-12")
            Check.expectNotNil(try? ServerDirectory(directory: destination))
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
            Check.expectEqual(leftovers, ["Geo"], "nothing staged left behind")
        }
    }

    Check.suite("Data refresh (#121) — when, and through the filter") {

        let now = Date(timeIntervalSince1970: 1_793_400_000)   // 2026-10-30
        let current = GeoDataUpdater.currentMonth(now)

        Check.test("a check is due once the data is from an earlier month, at most daily") {
            Check.expectEqual(current, "2026-10")
            Check.expectTrue(GeoDataUpdater.isDue(enabled: true, month: "2026-09", lastChecked: nil, now: now))
            Check.expectFalse(GeoDataUpdater.isDue(enabled: true, month: "2026-10", lastChecked: nil, now: now),
                              "already this month's")
            Check.expectFalse(GeoDataUpdater.isDue(enabled: false, month: "2026-09", lastChecked: nil, now: now),
                              "switched off")
            Check.expectFalse(GeoDataUpdater.isDue(enabled: true, month: "2026-09", lastChecked: now - 3600, now: now),
                              "checked an hour ago")
            Check.expectTrue(GeoDataUpdater.isDue(enabled: true, month: "2026-09", lastChecked: now - 86400, now: now))
            Check.expectTrue(GeoDataUpdater.isDue(enabled: true, month: "2026-09", lastChecked: now + 86400, now: now),
                             "a clock set back")
        }

        Check.test("Only Where I Allow and Ask Me don't hold back NetworkMonitor's own download; a rule can") {
            let own = FlowFacts(appKeys: ["/Applications/NetworkMonitor.app"], companyKey: "GitHub", country: "US",
                                address: "185.199.108.133", port: 443, isApple: false, isNetworkMonitor: true)
            Check.expectEqual(FirewallPolicy(mode: .onlyAllowed).decide(own), .allow(.networkMonitor))
            Check.expectEqual(FirewallPolicy(mode: .ask).decide(own), .allow(.networkMonitor))
            let blockGitHub = FirewallRule(subject: .company, key: "GitHub", title: "GitHub", action: .block)
            Check.expectEqual(FirewallPolicy(mode: .onlyAllowed, rules: [blockGitHub]).decide(own),
                              .block(.rule(blockGitHub)))
        }
    }
}
