import FilterProtocol
import FirewallPolicy
import Foundation

// #255: trackers behind a site's own name, uncovered from the aliases in
// lookups' answers.

func runDNSAliasTests() {
    func label(_ name: String) -> [UInt8] {
        name.split(separator: ".").flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) } + [0]
    }
    func u16(_ v: Int) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
    func u32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }

    /// metrics.example.com → example.com.sc.omtrdc.net → edge.omtrdc.net → 192.0.2.7,
    /// with the owners as compression pointers, as servers send them.
    func cloakedAnswer(flags: Int = 0x8180) -> Data {
        var bytes = u16(0x1234) + u16(flags) + u16(1) + u16(3) + u16(0) + u16(0)
        bytes += label("Metrics.Example.com") + u16(1) + u16(1)              // question at 12
        let first = label("example.com.sc.omtrdc.net")
        bytes += [0xc0, 12] + u16(5) + u16(1) + u32(300) + u16(first.count)
        let firstAt = bytes.count
        bytes += first
        let second = label("edge").dropLast() + [0xc0, UInt8(firstAt + 15)] // edge + "omtrdc.net"
        bytes += [0xc0, UInt8(firstAt)] + u16(5) + u16(1) + u32(60) + u16(second.count)
        let secondAt = bytes.count
        bytes += second
        bytes += [0xc0, UInt8(secondAt)] + u16(1) + u16(1) + u32(20) + u16(4) + [192, 0, 2, 7]
        return Data(bytes)
    }

    Check.suite("Aliases in lookups (#255)") {

        Check.test("an answer's alias chain, through compressed names, with its shortest time") {
            let found = DNSAnswer.aliases(in: cloakedAnswer())
            Check.expectEqual(found?.name, "metrics.example.com")
            Check.expectEqual(found?.chain, ["example.com.sc.omtrdc.net", "edge.omtrdc.net"])
            Check.expectEqual(found?.ttl, 60)
        }

        Check.test("no alias, a question, an error or a cut-off answer gives nothing") {
            var plain = u16(1) + u16(0x8180) + u16(1) + u16(1) + u16(0) + u16(0)
            plain += label("example.com") + u16(1) + u16(1)
            plain += [0xc0, 12] + u16(1) + u16(1) + u32(60) + u16(4) + [192, 0, 2, 1]
            Check.expectNil(DNSAnswer.aliases(in: Data(plain)))
            Check.expectNil(DNSAnswer.aliases(in: cloakedAnswer(flags: 0x0100)), "a query")
            Check.expectNil(DNSAnswer.aliases(in: cloakedAnswer(flags: 0x8183)), "NXDOMAIN")
            Check.expectNil(DNSAnswer.aliases(in: cloakedAnswer().dropLast(9)))
            Check.expectNil(DNSAnswer.aliases(in: Data([1, 2, 3])))
        }

        Check.test("a pointer loop or an alias back to the name ends the chain") {
            var looped = u16(1) + u16(0x8180) + u16(1) + u16(1) + u16(0) + u16(0)
            looped += [0xc0, 12] + u16(1) + u16(1)
            Check.expectNil(DNSAnswer.aliases(in: Data(looped)))
            var circle = u16(1) + u16(0x8180) + u16(1) + u16(2) + u16(0) + u16(0)
            circle += label("a.example") + u16(1) + u16(1)
            let b = label("b.example")
            circle += [0xc0, 12] + u16(5) + u16(1) + u32(60) + u16(b.count)
            let bAt = circle.count
            circle += b
            circle += [0xc0, UInt8(bAt)] + u16(5) + u16(1) + u32(60) + u16(2) + [0xc0, 12]
            Check.expectEqual(DNSAnswer.aliases(in: Data(circle))?.chain, ["b.example"])
        }

        Check.test("kept at least five minutes, at most a day, and forgotten after (#321)") {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            var memory = AliasMemory()
            memory.learn(DNSAnswer.Aliases(name: "metrics.example.com", chain: ["t.omtrdc.net"], ttl: 20), now: now)
            Check.expectEqual(memory.chain(of: "Metrics.Example.com", now: now + 299), ["t.omtrdc.net"])
            Check.expectEqual(memory.chain(of: "metrics.example.com", now: now + 301), [])
            memory.learn(DNSAnswer.Aliases(name: "x.example.com", chain: ["y.example.net"], ttl: 7_200), now: now)
            Check.expectEqual(memory.chain(of: "x.example.com", now: now + 7_199), ["y.example.net"])
            Check.expectEqual(memory.chain(of: "x.example.com", now: now + 7_201), [])
            memory.learn(DNSAnswer.Aliases(name: "z.example.com", chain: ["y.example.net"], ttl: 604_800), now: now)
            Check.expectEqual(memory.chain(of: "z.example.com", now: now + 86_399), ["y.example.net"])
            Check.expectEqual(memory.chain(of: "z.example.com", now: now + 86_401), [])
        }

        Check.test("answers over TCP, each after its length, however the bytes arrive (#321)") {
            let answer = cloakedAnswer()
            let framed = Data(u16(answer.count)) + answer
            var whole = DNSStream()
            Check.expectEqual(whole.append(framed + framed), [answer, answer])
            var pieces = DNSStream()
            var found: [Data] = []
            for byte in framed { found += pieces.append(Data([byte])) }
            Check.expectEqual(found, [answer])
            Check.expectEqual(found.first.flatMap(DNSAnswer.aliases(in:))?.chain,
                              ["example.com.sc.omtrdc.net", "edge.omtrdc.net"])
            var cut = DNSStream()
            Check.expectEqual(cut.append(framed.dropLast()), [])
            Check.expectEqual(cut.append(Data()), [])
        }

        Check.test("never holds more than its capacity") {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            var memory = AliasMemory()
            for index in 0...AliasMemory.capacity {
                memory.learn(DNSAnswer.Aliases(name: "n\(index).example.com", chain: ["t.example.net"],
                                               ttl: UInt32(300 + index)), now: now)
            }
            Check.expectTrue(memory.count <= AliasMemory.capacity)
            Check.expectEqual(memory.chain(of: "n\(AliasMemory.capacity).example.com", now: now), ["t.example.net"],
                              "the newest is kept")
        }
    }

    Check.suite("Encrypted lookups (#291)") {
        func query(_ name: String) -> Data {
            Data(u16(0xbeef) + u16(0x0100) + u16(1) + u16(0) + u16(0) + u16(0) + label(name) + u16(1) + u16(1))
        }

        Check.test("reads the name a query asks about") {
            Check.expectEqual(EncryptedDNS.questionName(query("WWW.Example.com")), "www.example.com")
            Check.expectNil(EncryptedDNS.questionName(Data([0, 1, 2])))
            Check.expectNil(EncryptedDNS.questionName(query("example.com").dropLast(6)))
        }

        Check.test("names only the network knows stay on it") {
            for name in ["router", "printer.local", "nas.lan", "box.home.arpa", "wiki.corp", "1.1.168.192.in-addr.arpa",
                         "5.0.0.10.in-addr.arpa", "3.20.16.172.in-addr.arpa",
                         "1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.e.f.ip6.arpa"] {
                Check.expectTrue(EncryptedDNS.staysOnNetwork(name), name)
            }
            for name in ["example.com", "apple.com", "8.8.8.8.in-addr.arpa", "3.20.32.172.in-addr.arpa",
                         "local.example.com"] {
                Check.expectFalse(EncryptedDNS.staysOnNetwork(name), name)
            }
        }

        Check.test("the answer goes back with the question's ID") {
            var answer = [UInt8](query("example.com"))
            answer[0] = 0
            answer[1] = 0
            answer[2] = 0x81
            let fixed = EncryptedDNS.answer(Data(answer), for: query("example.com"))
            Check.expectEqual(fixed.map { Array($0.prefix(3)) }, [0xbe, 0xef, 0x81])
            Check.expectNil(EncryptedDNS.answer(Data([1, 2]), for: query("example.com")))
        }

        Check.test("three failures in a row send lookups to the network for a minute") {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            var fallback = EncryptedDNS.Fallback()
            fallback.failed(now: now)
            fallback.failed(now: now)
            Check.expectTrue(fallback.triesEncrypted(now: now))
            fallback.succeeded()
            fallback.failed(now: now)
            fallback.failed(now: now)
            Check.expectTrue(fallback.triesEncrypted(now: now), "an answer in between starts the count again")
            fallback.failed(now: now)
            Check.expectFalse(fallback.triesEncrypted(now: now.addingTimeInterval(59)))
            Check.expectTrue(fallback.triesEncrypted(now: now.addingTimeInterval(60)))
            fallback.succeeded()
            Check.expectFalse(fallback.isPaused)
        }

        Check.test("every resolver answers at an address, and an unknown one means the first") {
            for resolver in EncryptedDNS.resolvers {
                Check.expectEqual(resolver.url.scheme, "https")
                Check.expectTrue(FirewallPolicy.isLocal(resolver.url.host ?? "") == false)
                Check.expectTrue(resolver.url.host?.allSatisfy { $0.isNumber || $0 == "." } == true, resolver.id)
            }
            Check.expectEqual(EncryptedDNS.resolver("nonsense").id, EncryptedDNS.defaultResolver)
        }

        Check.test("the resolver travels with the policy, and an old policy has none") {
            let policy = FirewallPolicy(lists: [.ads], lookupResolver: "quad9")
            Check.expectEqual(FirewallPolicy.decode(policy.encoded())?.lookupResolver, "quad9")
            Check.expectNil(FirewallPolicy.decode(Data(#"{"mode":"anywhere","rules":[]}"#.utf8))?.lookupResolver)
        }
    }
}
