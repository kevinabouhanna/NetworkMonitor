import CryptoKit
import FilterProtocol
import Foundation
import HandshakeName

// #196: the site name in a connection's opening handshake. The QUIC packets
// are the RFCs' own test vectors, so the key derivation, header protection
// and decryption are checked against published bytes; the rest is built here
// with the same keys, the way Chrome sends it.

func runHandshakeNameTests() {
    let hello = HandshakeVectors.helloRFC

    Check.suite("Handshake name — TLS over TCP (#196)") {

        Check.test("reads the server name from a ClientHello record") {
            Check.expectEqual(HandshakeName.tls(HandshakeVectors.record(hello)), .name("example.com"))
        }

        Check.test("waits for the rest of a ClientHello cut short") {
            let record = HandshakeVectors.record(hello)
            Check.expectEqual(HandshakeName.tls(Array(record.prefix(3))), .needMore)
            Check.expectEqual(HandshakeName.tls(Array(record.prefix(40))), .needMore)
            // The name ends 74 bytes into the record; the rest isn't needed.
            Check.expectEqual(HandshakeName.tls(Array(record.prefix(74))), .name("example.com"))
        }

        Check.test("reads a ClientHello split across two records") {
            let split = HandshakeVectors.record(Array(hello.prefix(30))) + HandshakeVectors.record(Array(hello.dropFirst(30)))
            Check.expectEqual(HandshakeName.tls(split), .name("example.com"))
        }

        Check.test("doesn't read what isn't a TLS handshake") {
            Check.expectEqual(HandshakeName.tls(Array("GET / HTTP/1.1\r\nHost: a\r\n".utf8)), .none)
            Check.expectEqual(HandshakeName.tls([0x17, 0x03, 0x03, 0x00, 0x10] + [UInt8](repeating: 0, count: 16)), .none)
            Check.expectEqual(HandshakeName.tls([0x16, 0x09, 0x09, 0x00, 0x10]), .none)
        }

        Check.test("a ClientHello without a server name has no name") {
            Check.expectEqual(HandshakeName.tls(HandshakeVectors.record(HandshakeVectors.withoutServerName(hello))), .none)
        }

        Check.test("names are lowercase, without a trailing dot, and only DNS characters") {
            Check.expectEqual(HandshakeName.tls(HandshakeVectors.record(HandshakeVectors.renamed(hello, "Ads.Example.COM."))),
                              .name("ads.example.com"))
            Check.expectEqual(HandshakeName.tls(HandshakeVectors.record(HandshakeVectors.renamed(hello, "bad name.com"))), .none)
            Check.expectEqual(HandshakeName.tls(HandshakeVectors.record(HandshakeVectors.renamed(hello, "a..b.com"))), .none)
        }
    }

    Check.suite("Handshake name — QUIC Initial packets (#196)") {

        Check.test("decrypts RFC 9001's Initial and reads its server name") {
            Check.expectEqual(HandshakeVectors.initialV1.count, 1200)
            Check.expectEqual(HandshakeName.quic(HandshakeVectors.initialV1), .name("example.com"))
        }

        Check.test("decrypts RFC 9369's version 2 Initial too") {
            Check.expectEqual(HandshakeName.quic(HandshakeVectors.initialV2), .name("example.com"))
        }

        Check.test("waits for the rest of a datagram cut short") {
            Check.expectEqual(HandshakeName.quic(Array(HandshakeVectors.initialV1.prefix(600))), .needMore)
            Check.expectEqual(HandshakeName.quic(Array(HandshakeVectors.initialV1.prefix(3))), .needMore)
        }

        Check.test("a damaged packet, or another version, has no name") {
            var damaged = HandshakeVectors.initialV1
            damaged[damaged.count - 1] ^= 0xff
            Check.expectEqual(HandshakeName.quic(damaged), .none)
            var other = HandshakeVectors.initialV1
            other[4] = 0x02
            Check.expectEqual(HandshakeName.quic(other), .none)
            Check.expectEqual(HandshakeName.quic([0x40, 0x01, 0x02]), .none)
        }

        // Chrome shuffles its ClientHello into CRYPTO frames, and with a
        // post-quantum key share needs two packets for it.
        Check.test("puts shuffled CRYPTO frames from two packets back together") {
            let dcid: [UInt8] = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]
            let first = HandshakeVectors.initial(
                dcid: dcid, keysFrom: dcid, packetNumber: 0,
                frames: HandshakeVectors.crypto(hello, 100..<241) + [0x01] + HandshakeVectors.crypto(hello, 0..<50))
            let second = HandshakeVectors.initial(
                dcid: [0x99, 0x98], keysFrom: dcid, packetNumber: 1,
                frames: HandshakeVectors.crypto(hello, 50..<100))
            Check.expectEqual(HandshakeName.quic(first), .needMore, "the name is in the second packet")
            Check.expectEqual(HandshakeName.quic(first + second), .name("example.com"))
        }

        Check.test("steps over ACK, PING and PADDING frames") {
            let dcid: [UInt8] = [0x01, 0x02, 0x03, 0x04]
            let ack: [UInt8] = [0x02, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00]
            let packet = HandshakeVectors.initial(dcid: dcid, keysFrom: dcid, packetNumber: 2,
                                                  frames: ack + [0x01, 0x00, 0x00] + HandshakeVectors.crypto(hello, 0..<241))
            Check.expectEqual(HandshakeName.quic(packet), .name("example.com"))
        }
    }

    Check.suite("Handshake name — reading a flow as the filter hands it over (#196)") {

        Check.test("waits, then names the flow, whether bytes come again from the start or only the new ones") {
            let record = HandshakeVectors.record(hello)
            var fromStart = HandshakeReader(.stream)
            guard case .peek(let more) = fromStart.read(at: 0, Data(record.prefix(30))) else {
                return Check.expectTrue(false, "should ask for more")
            }
            Check.expectTrue(more > 30, "asks to see further")
            Check.expectEqual(fromStart.read(at: 0, Data(record)), .done("example.com"))

            var newOnly = HandshakeReader(.stream)
            _ = newOnly.read(at: 0, Data(record.prefix(30)))
            Check.expectEqual(newOnly.read(at: 30, Data(record.dropFirst(30))), .done("example.com"))
        }

        Check.test("gives up on a gap, on what isn't a handshake, and after a few looks") {
            var gap = HandshakeReader(.stream)
            _ = gap.read(at: 0, Data(HandshakeVectors.record(hello).prefix(10)))
            Check.expectEqual(gap.read(at: 50, Data([1, 2, 3])), .done(nil))

            var plain = HandshakeReader(.stream)
            Check.expectEqual(plain.read(at: 0, Data("GET / HTTP/1.1".utf8)), .done(nil))

            var stuck = HandshakeReader(.stream)
            var last = HandshakeReader.Step.peek(0)
            for _ in 0..<HandshakeReader.maxReads { last = stuck.read(at: 0, Data([0x16, 0x03, 0x01])) }
            Check.expectEqual(last, .done(nil))
        }

        Check.test("reads QUIC datagram by datagram") {
            let dcid: [UInt8] = [0xaa, 0xbb, 0xcc, 0xdd]
            let first = HandshakeVectors.initial(dcid: dcid, keysFrom: dcid, packetNumber: 0,
                                                 frames: HandshakeVectors.crypto(hello, 0..<40))
            let second = HandshakeVectors.initial(dcid: dcid, keysFrom: dcid, packetNumber: 1,
                                                  frames: HandshakeVectors.crypto(hello, 40..<241))
            var reader = HandshakeReader(.datagram)
            guard case .peek = reader.read(at: 0, Data(first)) else {
                return Check.expectTrue(false, "should ask for the next datagram")
            }
            Check.expectEqual(reader.read(at: first.count, Data(second)), .done("example.com"))
        }
    }

    Check.suite("Server names from the filter's reports (#196)") {

        // macOS's resolver reports the name it's looking up on a flow to
        // the DNS server, which made 1.1.1.1 read as developer.apple.com.
        Check.test("a DNS lookup doesn't name the resolver") {
            func report(_ port: Int, _ name: String?) -> FlowReport {
                FlowReport(address: "1.1.1.1", port: port, hostname: name, pid: 1, time: Date())
            }
            Check.expectNil(report(53, "developer.apple.com").serverName)
            Check.expectNil(report(853, "developer.apple.com").serverName)
            Check.expectEqual(report(443, "one.one.one.one").serverName, "one.one.one.one")
            Check.expectNil(report(443, nil).serverName)
            Check.expectNil(report(443, "").serverName)
        }
    }
}

enum HandshakeVectors {

    static func bytes(_ lines: [String]) -> [UInt8] {
        let hex = Array(lines.joined().utf8)
        return stride(from: 0, to: hex.count, by: 2).map { UInt8(String(decoding: hex[$0..<$0 + 2], as: UTF8.self), radix: 16)! }
    }

    /// The ClientHello in RFC 9001 Appendix A.2: TLS 1.3, server_name example.com.
    static let helloRFC = bytes([
        "010000ed0303ebf8fa56f12939b9584a3896472ec40bb863cfd3e86804fe3a47",
        "f06a2b69484c00000413011302010000c000000010000e00000b6578616d706c",
        "652e636f6dff01000100000a00080006001d0017001800100007000504616c70",
        "6e000500050100000000003300260024001d00209370b2c9caa47fbabaf4559f",
        "edba753de171fa71f50f1ce15d43e994ec74d748002b0003020304000d001000",
        "0e0403050306030203080408050806002d00020101001c000240010039003204",
        "08ffffffffffffffff05048000ffff07048000ffff0801100104800075300901",
        "100f088394c8f03e51570806048000ffff",
    ])

    /// RFC 9001 Appendix A.2: the client's protected Initial packet, QUIC version 1.
    static let initialV1 = bytes([
        "c000000001088394c8f03e5157080000449e7b9aec34d1b1c98dd7689fb8ec11",
        "d242b123dc9bd8bab936b47d92ec356c0bab7df5976d27cd449f63300099f399",
        "1c260ec4c60d17b31f8429157bb35a1282a643a8d2262cad67500cadb8e7378c",
        "8eb7539ec4d4905fed1bee1fc8aafba17c750e2c7ace01e6005f80fcb7df6212",
        "30c83711b39343fa028cea7f7fb5ff89eac2308249a02252155e2347b63d58c5",
        "457afd84d05dfffdb20392844ae812154682e9cf012f9021a6f0be17ddd0c208",
        "4dce25ff9b06cde535d0f920a2db1bf362c23e596d11a4f5a6cf3948838a3aec",
        "4e15daf8500a6ef69ec4e3feb6b1d98e610ac8b7ec3faf6ad760b7bad1db4ba3",
        "485e8a94dc250ae3fdb41ed15fb6a8e5eba0fc3dd60bc8e30c5c4287e53805db",
        "059ae0648db2f64264ed5e39be2e20d82df566da8dd5998ccabdae053060ae6c",
        "7b4378e846d29f37ed7b4ea9ec5d82e7961b7f25a9323851f681d582363aa5f8",
        "9937f5a67258bf63ad6f1a0b1d96dbd4faddfcefc5266ba6611722395c906556",
        "be52afe3f565636ad1b17d508b73d8743eeb524be22b3dcbc2c7468d54119c74",
        "68449a13d8e3b95811a198f3491de3e7fe942b330407abf82a4ed7c1b311663a",
        "c69890f4157015853d91e923037c227a33cdd5ec281ca3f79c44546b9d90ca00",
        "f064c99e3dd97911d39fe9c5d0b23a229a234cb36186c4819e8b9c5927726632",
        "291d6a418211cc2962e20fe47feb3edf330f2c603a9d48c0fcb5699dbfe58964",
        "25c5bac4aee82e57a85aaf4e2513e4f05796b07ba2ee47d80506f8d2c25e50fd",
        "14de71e6c418559302f939b0e1abd576f279c4b2e0feb85c1f28ff18f58891ff",
        "ef132eef2fa09346aee33c28eb130ff28f5b766953334113211996d20011a198",
        "e3fc433f9f2541010ae17c1bf202580f6047472fb36857fe843b19f5984009dd",
        "c324044e847a4f4a0ab34f719595de37252d6235365e9b84392b061085349d73",
        "203a4a13e96f5432ec0fd4a1ee65accdd5e3904df54c1da510b0ff20dcc0c77f",
        "cb2c0e0eb605cb0504db87632cf3d8b4dae6e705769d1de354270123cb11450e",
        "fc60ac47683d7b8d0f811365565fd98c4c8eb936bcab8d069fc33bd801b03ade",
        "a2e1fbc5aa463d08ca19896d2bf59a071b851e6c239052172f296bfb5e724047",
        "90a2181014f3b94a4e97d117b438130368cc39dbb2d198065ae3986547926cd2",
        "162f40a29f0c3c8745c0f50fba3852e566d44575c29d39a03f0cda721984b6f4",
        "40591f355e12d439ff150aab7613499dbd49adabc8676eef023b15b65bfc5ca0",
        "6948109f23f350db82123535eb8a7433bdabcb909271a6ecbcb58b936a88cd4e",
        "8f2e6ff5800175f113253d8fa9ca8885c2f552e657dc603f252e1a8e308f76f0",
        "be79e2fb8f5d5fbbe2e30ecadd220723c8c0aea8078cdfcb3868263ff8f09400",
        "54da48781893a7e49ad5aff4af300cd804a6b6279ab3ff3afb64491c85194aab",
        "760d58a606654f9f4400e8b38591356fbf6425aca26dc85244259ff2b19c41b9",
        "f96f3ca9ec1dde434da7d2d392b905ddf3d1f9af93d1af5950bd493f5aa731b4",
        "056df31bd267b6b90a079831aaf579be0a39013137aac6d404f518cfd4684064",
        "7e78bfe706ca4cf5e9c5453e9f7cfd2b8b4c8d169a44e55c88d4a9a7f9474241",
        "e221af44860018ab0856972e194cd934",
    ])

    /// RFC 9369 Appendix A.2: the same Initial, QUIC version 2.
    static let initialV2 = bytes([
        "d76b3343cf088394c8f03e5157080000449ea0c95e82ffe67b6abcdb4298b485",
        "dd04de806071bf03dceebfa162e75d6c96058bdbfb127cdfcbf903388e99ad04",
        "9f9a3dd4425ae4d0992cfff18ecf0fdb5a842d09747052f17ac2053d21f57c5d",
        "250f2c4f0e0202b70785b7946e992e58a59ac52dea6774d4f03b55545243cf1a",
        "12834e3f249a78d395e0d18f4d766004f1a2674802a747eaa901c3f10cda5500",
        "cb9122faa9f1df66c392079a1b40f0de1c6054196a11cbea40afb6ef5253cd68",
        "18f6625efce3b6def6ba7e4b37a40f7732e093daa7d52190935b8da58976ff33",
        "12ae50b187c1433c0f028edcc4c2838b6a9bfc226ca4b4530e7a4ccee1bfa2a3",
        "d396ae5a3fb512384b2fdd851f784a65e03f2c4fbe11a53c7777c023462239dd",
        "6f7521a3f6c7d5dd3ec9b3f233773d4b46d23cc375eb198c63301c21801f6520",
        "bcfb7966fc49b393f0061d974a2706df8c4a9449f11d7f3d2dcbb90c6b877045",
        "636e7c0c0fe4eb0f697545460c806910d2c355f1d253bc9d2452aaa549e27a1f",
        "ac7cf4ed77f322e8fa894b6a83810a34b361901751a6f5eb65a0326e07de7c12",
        "16ccce2d0193f958bb3850a833f7ae432b65bc5a53975c155aa4bcb4f7b2c4e5",
        "4df16efaf6ddea94e2c50b4cd1dfe06017e0e9d02900cffe1935e0491d77ffb4",
        "fdf85290fdd893d577b1131a610ef6a5c32b2ee0293617a37cbb08b847741c3b",
        "8017c25ca9052ca1079d8b78aebd47876d330a30f6a8c6d61dd1ab5589329de7",
        "14d19d61370f8149748c72f132f0fc99f34d766c6938597040d8f9e2bb522ff9",
        "9c63a344d6a2ae8aa8e51b7b90a4a806105fcbca31506c446151adfeceb51b91",
        "abfe43960977c87471cf9ad4074d30e10d6a7f03c63bd5d4317f68ff325ba3bd",
        "80bf4dc8b52a0ba031758022eb025cdd770b44d6d6cf0670f4e990b22347a7db",
        "848265e3e5eb72dfe8299ad7481a408322cac55786e52f633b2fb6b614eaed18",
        "d703dd84045a274ae8bfa73379661388d6991fe39b0d93debb41700b41f90a15",
        "c4d526250235ddcd6776fc77bc97e7a417ebcb31600d01e57f32162a8560cacc",
        "7e27a096d37a1a86952ec71bd89a3e9a30a2a26162984d7740f81193e8238e61",
        "f6b5b984d4d3dfa033c1bb7e4f0037febf406d91c0dccf32acf423cfa1e70710",
        "10d3f270121b493ce85054ef58bada42310138fe081adb04e2bd901f2f13458b",
        "3d6758158197107c14ebb193230cd1157380aa79cae1374a7c1e5bbcb80ee23e",
        "06ebfde206bfb0fcbc0edc4ebec309661bdd908d532eb0c6adc38b7ca7331dce",
        "8dfce39ab71e7c32d318d136b6100671a1ae6a6600e3899f31f0eed19e3417d1",
        "34b90c9058f8632c798d4490da4987307cba922d61c39805d072b589bd52fdf1",
        "e86215c2d54e6670e07383a27bbffb5addf47d66aa85a0c6f9f32e59d85a44dd",
        "5d3b22dc2be80919b490437ae4f36a0ae55edf1d0b5cb4e9a3ecabee93dfc6e3",
        "8d209d0fa6536d27a5d6fbb17641cde27525d61093f1b28072d111b2b4ae5f89",
        "d5974ee12e5cf7d5da4d6a31123041f33e61407e76cffcdcfd7e19ba58cf4b53",
        "6f4c4938ae79324dc402894b44faf8afbab35282ab659d13c93f70412e85cb19",
        "9a37ddec600545473cfb5a05e08d0b209973b2172b4d21fb69745a262ccde96b",
        "a18b2faa745b6fe189cf772a9f84cbfc",
    ])

    /// One TLS handshake record around `body`.
    static func record(_ body: [UInt8]) -> [UInt8] {
        [0x16, 0x03, 0x01, UInt8(body.count >> 8), UInt8(body.count & 0xff)] + body
    }

    /// Where the RFC hello's extensions length sits, and its server_name
    /// extension, which comes first.
    private static let extensionsLengthAt = 47
    private static let serverNameAt = 49

    static func withoutServerName(_ hello: [UInt8]) -> [UInt8] {
        replacingServerName(hello, with: [])
    }

    static func renamed(_ hello: [UInt8], _ name: String) -> [UInt8] {
        let host = Array(name.utf8)
        let entry: [UInt8] = [0x00] + u16(host.count) + host
        let list = u16(entry.count) + entry
        return replacingServerName(hello, with: [0x00, 0x00] + u16(list.count) + list)
    }

    private static func replacingServerName(_ hello: [UInt8], with replacement: [UInt8]) -> [UInt8] {
        let oldSize = 4 + (Int(hello[serverNameAt + 2]) << 8 | Int(hello[serverNameAt + 3]))
        var result = Array(hello[..<serverNameAt]) + replacement + Array(hello[(serverNameAt + oldSize)...])
        let delta = replacement.count - oldSize
        let length = (Int(hello[1]) << 16 | Int(hello[2]) << 8 | Int(hello[3])) + delta
        result[1] = UInt8(length >> 16); result[2] = UInt8((length >> 8) & 0xff); result[3] = UInt8(length & 0xff)
        let extensions = (Int(hello[extensionsLengthAt]) << 8 | Int(hello[extensionsLengthAt + 1])) + delta
        result[extensionsLengthAt] = UInt8(extensions >> 8); result[extensionsLengthAt + 1] = UInt8(extensions & 0xff)
        return result
    }

    static func u16(_ value: Int) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xff)] }

    static func varint(_ value: Int) -> [UInt8] {
        value < 64 ? [UInt8(value)] : [0x40 | UInt8(value >> 8), UInt8(value & 0xff)]
    }

    /// A CRYPTO frame carrying part of the ClientHello at its own offset.
    static func crypto(_ hello: [UInt8], _ range: Range<Int>) -> [UInt8] {
        [0x06] + varint(range.lowerBound) + varint(range.count) + Array(hello[range])
    }

    /// A client Initial packet, version 1, protected as RFC 9001 §5 says,
    /// with keys from the first packet's connection ID.
    static func initial(dcid: [UInt8], keysFrom firstDCID: [UInt8], packetNumber: UInt64, frames: [UInt8]) -> [UInt8] {
        let keys = QUICInitial.Keys(destinationConnectionID: firstDCID, version: QUICInitial.version1)!
        let payload = frames + [UInt8](repeating: 0, count: max(0, 40 - frames.count))
        let length = 4 + payload.count + 16
        var header: [UInt8] = [0xc3, 0x00, 0x00, 0x00, 0x01, UInt8(dcid.count)] + dcid + [0x00, 0x00]
        header += [0x40 | UInt8(length >> 8), UInt8(length & 0xff)]
        let numberAt = header.count
        header += (0..<4).map { UInt8(truncatingIfNeeded: packetNumber >> (8 * (3 - $0))) }
        let nonce = try! AES.GCM.Nonce(data: keys.nonce(packetNumber: packetNumber))
        let sealed = try! AES.GCM.seal(payload, using: keys.key, nonce: nonce, authenticating: header)
        let body = Array(sealed.ciphertext) + Array(sealed.tag)
        let mask = keys.mask(sample: Array(body[0..<16]))!
        header[0] ^= mask[0] & 0x0f
        for index in 0..<4 { header[numberAt + index] ^= mask[1 + index] }
        return header + body
    }
}
