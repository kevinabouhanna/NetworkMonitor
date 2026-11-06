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

        Check.test("kept at least five minutes, at most an hour, and forgotten after") {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            var memory = AliasMemory()
            memory.learn(DNSAnswer.Aliases(name: "metrics.example.com", chain: ["t.omtrdc.net"], ttl: 20), now: now)
            Check.expectEqual(memory.chain(of: "Metrics.Example.com", now: now + 299), ["t.omtrdc.net"])
            Check.expectEqual(memory.chain(of: "metrics.example.com", now: now + 301), [])
            memory.learn(DNSAnswer.Aliases(name: "x.example.com", chain: ["y.example.net"], ttl: 86_400), now: now)
            Check.expectEqual(memory.chain(of: "x.example.com", now: now + 3599), ["y.example.net"])
            Check.expectEqual(memory.chain(of: "x.example.com", now: now + 3601), [])
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
}
