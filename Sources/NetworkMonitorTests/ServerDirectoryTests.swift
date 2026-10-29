import Foundation
import ServerDirectory

func runServerDirectoryTests() {
    func address(_ text: String) -> IPAddress { IPAddress(text)! }

    func table(_ build: (inout RangeTableWriter) throws -> Void) -> RangeTable? {
        var writer = RangeTableWriter()
        do {
            try build(&writer)
            return try RangeTable(data: writer.encoded())
        } catch {
            Check.expectTrue(false, "building the table failed: \(error)")
            return nil
        }
    }

    Check.suite("ServerDirectory — addresses") {

        Check.test("reads IPv4 and IPv6") {
            Check.expectEqual(IPAddress("1.2.3.4"), .v4(0x0102_0304))
            Check.expectEqual(IPAddress("2a00:1450::1"),
                              .v6(IPv6Value(high: 0x2a00_1450_0000_0000, low: 1)))
        }

        // nettop reports dual-stack sockets this way; DB-IP lists the address
        // only under IPv4, so reading it as IPv6 would find nothing.
        Check.test("reads an IPv4 address written as IPv6 as the IPv4 address") {
            Check.expectEqual(IPAddress("::ffff:142.250.180.14"), IPAddress("142.250.180.14"))
        }

        // How a Mac on an IPv6-only network reaches an IPv4 server.
        Check.test("reads a NAT64 address as the IPv4 address inside it") {
            Check.expectEqual(IPAddress("64:ff9b::8.8.8.8"), IPAddress("8.8.8.8"))
            Check.expectEqual(IPAddress("64:ff9b::808:808"), IPAddress("8.8.8.8"))
        }

        Check.test("rejects what isn't an address") {
            Check.expectNil(IPAddress(""))
            Check.expectNil(IPAddress("example.com"))
            Check.expectNil(IPAddress("300.1.1.1"))
        }
    }

    Check.suite("ServerDirectory — range tables") {

        Check.test("finds the range an address falls in, and nothing in the gaps") {
            guard let table = table({
                try $0.add(from: address("10.0.0.0"), to: address("10.0.0.255"), label: "A")
                try $0.add(from: address("10.0.2.0"), to: address("10.0.2.255"), label: "B")
            }) else { return }
            Check.expectNil(table.label(for: address("9.255.255.255")), "before the first range")
            Check.expectEqual(table.label(for: address("10.0.0.0")), "A")
            Check.expectEqual(table.label(for: address("10.0.0.255")), "A")
            Check.expectNil(table.label(for: address("10.0.1.7")), "the gap between them")
            Check.expectEqual(table.label(for: address("10.0.2.128")), "B")
            Check.expectNil(table.label(for: address("10.0.3.0")), "after the last range")
        }

        Check.test("order doesn't matter, and neighbours with one label merge") {
            guard let table = table({
                try $0.add(from: address("10.0.1.0"), to: address("10.0.1.255"), label: "A")
                try $0.add(from: address("10.0.0.0"), to: address("10.0.0.255"), label: "A")
            }) else { return }
            Check.expectEqual(table.label(for: address("10.0.0.9")), "A")
            Check.expectEqual(table.label(for: address("10.0.1.9")), "A")
            // A gap before and after, and one merged range between them.
            Check.expectEqual(table.ipv4Count, 3)
        }

        Check.test("a nil label means nowhere, like DB-IP's ZZ") {
            guard let table = table({
                try $0.add(from: address("10.0.0.0"), to: address("10.0.0.255"), label: nil)
            }) else { return }
            Check.expectNil(table.label(for: address("10.0.0.1")))
        }

        Check.test("the highest address ends a range without overflowing") {
            guard let table = table({
                try $0.add(from: address("255.255.255.0"), to: address("255.255.255.255"), label: "Top")
            }) else { return }
            Check.expectEqual(table.label(for: address("255.255.255.255")), "Top")
        }

        // Keyed on the first 64 bits: a /64 is one subnet at one site.
        Check.test("IPv6 is found by its /64") {
            guard let table = table({
                try $0.add(from: address("2a00:1450::"),
                           to: address("2a00:1450:ffff:ffff:ffff:ffff:ffff:ffff"), label: "Google")
            }) else { return }
            Check.expectEqual(table.label(for: address("2a00:1450:4001:82b::200e")), "Google")
            Check.expectNil(table.label(for: address("2a00:1451::1")))
            Check.expectNil(table.label(for: address("10.0.0.1")), "the families are separate")
        }

        // The bug this guards against: a range starting partway into a /64 was
        // keyed nowhere, so the /64s after it read the range before it.
        Check.test("a range that starts partway into a /64 owns the /64s after it") {
            guard let table = table({
                try $0.add(from: address("2001:db8::"), to: address("2001:db8::7fff"), label: "A")
                try $0.add(from: address("2001:db8::8000"),
                           to: address("2001:db8:0:9:ffff:ffff:ffff:ffff"), label: "B")
            }) else { return }
            Check.expectEqual(table.label(for: address("2001:db8::1")), "A", "the /64 goes to whoever starts it")
            Check.expectEqual(table.label(for: address("2001:db8:0:1::1")), "B")
            Check.expectEqual(table.label(for: address("2001:db8:0:9::1")), "B")
            Check.expectNil(table.label(for: address("2001:db8:0:a::1")))
        }

        Check.test("a gap that starts partway into a /64 doesn't inherit the label before it") {
            guard let table = table({
                try $0.add(from: address("2001:db8::"), to: address("2001:db8::7fff"), label: "A")
                try $0.add(from: address("2001:db8:0:5::"),
                           to: address("2001:db8:0:5:ffff:ffff:ffff:ffff"), label: "C")
            }) else { return }
            Check.expectNil(table.label(for: address("2001:db8:0:2::1")), "unassigned space")
            Check.expectEqual(table.label(for: address("2001:db8:0:5::1")), "C")
        }

        Check.test("more labels than a byte holds still read back") {
            guard let table = table({ writer in
                for index in 0..<300 {
                    let base = UInt32(index) << 8
                    try writer.add(from: .v4(base), to: .v4(base + 255), label: "L\(index)")
                }
            }) else { return }
            Check.expectEqual(table.labelCount, 300)
            Check.expectEqual(table.label(for: .v4(299 << 8 + 7)), "L299")
            Check.expectEqual(table.label(for: .v4(254 << 8)), "L254")
            Check.expectEqual(table.label(for: .v4(255 << 8)), "L255", "the value a byte reserves for none")
        }

        Check.test("refuses a file that isn't one, or is cut short") {
            Check.expectEqual(Result { try RangeTable(data: Data("not a table at all, honest".utf8)) }
                                .failureValue as? RangeTable.ReadError, .notARangeTable)
            var writer = RangeTableWriter()
            try? writer.add(from: address("10.0.0.0"), to: address("10.0.0.255"), label: "A")
            let data = writer.encoded()
            Check.expectEqual(Result { try RangeTable(data: data.prefix(data.count - 1)) }
                                .failureValue as? RangeTable.ReadError, .truncated)
            // A header that claims less label text than the labels use.
            var short = data
            let claimed = short.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: UInt32.self) }
            withUnsafeBytes(of: (claimed.littleEndian - 1).littleEndian) {
                short.replaceSubrange(20..<24, with: $0)
            }
            Check.expectEqual(Result { try RangeTable(data: short) }
                                .failureValue as? RangeTable.ReadError, .truncated)
        }

        Check.test("refuses a range across families, or backwards") {
            var writer = RangeTableWriter()
            Check.expectEqual(Result { try writer.add(from: address("10.0.0.0"), to: address("::1"), label: "A") }
                                .failureValue as? RangeTableWriter.WriteError, .mixedFamilies)
            Check.expectEqual(Result { try writer.add(from: address("10.0.0.9"), to: address("10.0.0.1"), label: "A") }
                                .failureValue as? RangeTableWriter.WriteError, .endBeforeStart)
        }
    }

    Check.suite("ServerDirectory — companies") {

        func company(_ name: String, asn: UInt32 = 64_512) -> Company {
            Company.owning(asn: asn, registeredName: name)
        }

        Check.test("drops the legal form from a registered name") {
            Check.expectEqual(company("Microsoft Corporation").name, "Microsoft")
            Check.expectEqual(company("Hangar Networks, Inc.").name, "Hangar Networks")
            Check.expectEqual(company("Example Telecom S.A.L.").name, "Example Telecom")
            Check.expectEqual(company("Anthropic, PBC").name, "Anthropic")
            Check.expectEqual(company("LIBANTELECOM").name, "Libantelecom", "capitals read as a word")
            Check.expectEqual(company("SKY UK LIMITED").name, "SKY UK", "short ones are acronyms")
            Check.expectEqual(company("Inc.").name, "Inc.", "a name that is all legal form stays")
            Check.expectEqual(company("", asn: 64_512).name, "AS64512", "no name: the network's number")
        }

        Check.test("merges the big companies' networks under the name people know") {
            Check.expectEqual(company("Facebook, Inc."), Company(name: "Meta", isHost: false))
            Check.expectEqual(company("Google LLC", asn: 15169), Company(name: "Google", isHost: false))
            Check.expectEqual(company("Apple Inc."), Company(name: "Apple", isHost: false))
            Check.expectEqual(company("Zoom Video Communications, Inc").name, "Zoom")
        }

        // Traffic to Amazon's network went to something hosted there, not
        // necessarily to Amazon, and the window must not say otherwise.
        Check.test("marks networks that host other companies") {
            Check.expectEqual(company("Amazon.com, Inc."), Company(name: "Amazon", isHost: true))
            Check.expectFalse(company("Amazon.com, Inc.").answersEverywhere, "AWS regions are real places")
            Check.expectTrue(company("Cloudflare, Inc.").answersEverywhere, "one address, every data centre")
            Check.expectEqual(company("Amazon Data Services Ireland Ltd"), Company(name: "Amazon", isHost: true))
            Check.expectEqual(company("Cloudflare, Inc.").name, "Cloudflare")
            Check.expectTrue(company("Cloudflare, Inc.").isHost)
            Check.expectEqual(company("Shenzhen Tencent Computer Systems Company Limited"),
                              Company(name: "Tencent", isHost: true))
            Check.expectEqual(company("Google LLC", asn: 396982), Company(name: "Google", isHost: true),
                              "Google Cloud is registered under Google's own name")
        }

        Check.test("matches whole words only") {
            Check.expectEqual(company("Amazonas Telecom"), Company(name: "Amazonas Telecom", isHost: false))
            Check.expectEqual(company("Pineapple Inc").name, "Pineapple")
        }
    }

    Check.suite("ServerDirectory — the data shipped in Resources/Geo") {

        let geo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Geo")
        guard let directory = try? ServerDirectory(directory: geo) else {
            Check.test("opens") { Check.expectNotNil(nil as ServerDirectory?, "can't open \(geo.path)") }
            return
        }

        Check.test("names Google's and Cloudflare's resolvers") {
            let google = directory.lookup("8.8.8.8")
            Check.expectEqual(google.owner?.asn, 15169)
            Check.expectEqual(google.owner?.company, Company(name: "Google", isHost: false))
            Check.expectEqual(google.country, "US")
            Check.expectEqual(directory.lookup("1.1.1.1").owner?.company,
                              Company(name: "Cloudflare", isHost: true, answersEverywhere: true))
            Check.expectEqual(directory.lookup("2001:4860:4860::8888").owner?.asn, 15169)
        }

        Check.test("says nothing about an address that isn't one") {
            Check.expectEqual(directory.lookup("not an address"), ServerInfo(country: nil, owner: nil))
        }

        Check.test("credits DB-IP, and says which month the data is from") {
            Check.expectEqual(ServerDirectory.credit, "IP geolocation by DB-IP")
            let month = (try? String(contentsOf: geo.appendingPathComponent("MONTH"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Check.expectTrue(month.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil,
                             "MONTH reads \(month)")
        }
    }
}

func runWorldMapTests() {
    func point(_ longitude: Double, _ latitude: Double) -> WorldMap.Point {
        let (x, y) = EqualEarth.project(longitude: longitude, latitude: latitude)
        return WorldMap.Point(x: x, y: y)
    }

    Check.suite("World map — projection and file") {

        Check.test("Equal Earth puts the origin in the middle, and is symmetric") {
            let origin = EqualEarth.project(longitude: 0, latitude: 0)
            Check.expectEqual(origin.x, 0)
            Check.expectEqual(origin.y, 0)
            let north = EqualEarth.project(longitude: 30, latitude: 40)
            let south = EqualEarth.project(longitude: -30, latitude: -40)
            Check.expectEqual(south.x, -north.x)
            Check.expectEqual(south.y, -north.y)
        }

        // The published extents of Equal Earth.
        Check.test("Equal Earth's edges are where the paper puts them") {
            Check.expectTrue(abs(EqualEarth.maxX - 2.7066) < 0.0005, "maxX \(EqualEarth.maxX)")
            Check.expectTrue(abs(EqualEarth.maxY - 1.3173) < 0.0005, "maxY \(EqualEarth.maxY)")
        }

        Check.test("a map reads back what was written, to within its precision") {
            let square = [point(0, 0), point(10, 0), point(10, 10), point(0, 10), point(0, 0)]
            let map = WorldMap(countries: [
                WorldMap.Country(code: "LB", label: point(5, 5), rings: [square]),
                WorldMap.Country(code: "", label: point(1, 1), rings: [square]),
                WorldMap.Country(code: "RE", label: point(55, -21), rings: []),
            ])
            guard let read = try? WorldMap(data: map.encoded()) else {
                Check.expectTrue(false, "couldn't read it back"); return
            }
            Check.expectEqual(read.countries.map(\.code), ["LB", "", "RE"])
            Check.expectTrue(read.countries[2].isDot)
            Check.expectTrue(abs(read.countries[0].rings[0][1].x - square[1].x) < 0.0002)
        }

        Check.test("refuses a file that isn't one, or is cut short") {
            Check.expectEqual(Result { try WorldMap(data: Data("not a map".utf8)) }
                                .failureValue as? WorldMap.ReadError, .notAWorldMap)
            let data = WorldMap(countries: [WorldMap.Country(code: "LB", label: point(0, 0),
                                                             rings: [[point(0, 0), point(1, 1), point(0, 1)]])])
                .encoded()
            Check.expectEqual(Result { try WorldMap(data: data.prefix(data.count - 2)) }
                                .failureValue as? WorldMap.ReadError, .truncated)
        }

        Check.test("a point in a lake is not in its country") {
            let outer = [point(0, 0), point(20, 0), point(20, 20), point(0, 20)]
            let lake = [point(5, 5), point(15, 5), point(15, 15), point(5, 15)]
            Check.expectTrue(WorldMap.contains(point(2, 2), rings: [outer, lake]))
            Check.expectFalse(WorldMap.contains(point(10, 10), rings: [outer, lake]))
            Check.expectFalse(WorldMap.contains(point(30, 30), rings: [outer, lake]))
        }
    }

    Check.suite("World map — the data shipped in Resources/Geo") {

        let geo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Geo")
        guard let map = try? WorldMap(contentsOf: geo.appendingPathComponent("world.bin")),
              let countries = try? RangeTable(contentsOf: geo.appendingPathComponent("countries.bin")) else {
            Check.test("opens") { Check.expectTrue(false, "can't open \(geo.path)") }
            return
        }
        func country(_ code: String) -> WorldMap.Country? { map.countries.first { $0.code == code } }

        // Anything the list can name, the map can show and click.
        Check.test("every country DB-IP can name has a place on the map") {
            let mapped = Set(map.countries.map(\.code))
            let named = (0..<UInt32(countries.labelCount)).map(countries.label(at:))
            Check.expectEqual(named.filter { !mapped.contains($0) }, [])
        }

        // Inland on purpose: outlines are simplified to within about 11 km, so
        // a city on the coast, such as Beirut, can fall just outside.
        Check.test("Zahlé is in Lebanon and Paris in France") {
            Check.expectTrue(country("LB").map { WorldMap.contains(point(35.90, 33.85), rings: $0.rings) } ?? false)
            Check.expectTrue(country("FR").map { WorldMap.contains(point(2.35, 48.86), rings: $0.rings) } ?? false)
            Check.expectFalse(country("FR").map { WorldMap.contains(point(35.90, 33.85), rings: $0.rings) } ?? true)
        }

        Check.test("places drawn inside another country are dots of their own") {
            Check.expectEqual(country("RE")?.isDot, true)
            Check.expectEqual(country("SJ")?.isDot, true)
        }
    }
}

private extension Result where Failure == Error {
    var failureValue: Error? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
