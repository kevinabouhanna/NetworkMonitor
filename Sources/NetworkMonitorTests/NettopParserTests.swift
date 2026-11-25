import Foundation
import NetworkMonitorCore
import PacketUsage

/// Fixtures are verbatim `nettop` output captured on macOS 26.5.2 from
/// `nettop -P -x -d -L 0 -s 1 -J time,bytes_in,bytes_out`.
func runNettopParserTests() {
    Check.suite("NettopParser — row parsing") {

        Check.test("parses a standard row") {
            let row = NettopParser.parseRow("02:21:32.760799,mDNSResponder.501,7845,6862,")
            Check.expectEqual(row, NettopRow(pid: 501, processName: "mDNSResponder",
                                             bytesIn: 7845, bytesOut: 6862))
        }

        // nettop truncates names to the kernel's 15-char `p_comm` limit. The
        // truncated name survives as a display fallback; the pid is what matters.
        Check.test("parses a truncated name containing spaces") {
            let row = NettopParser.parseRow("02:21:32.760799,Google Chrome H.1578,4529465,414001,")
            Check.expectEqual(row?.processName, "Google Chrome H")
            Check.expectEqual(row?.pid, 1578)
        }

        // Names contain dots (`com.apple.WebKit`, `launchd.develop`), so the pid
        // must be split off at the LAST dot, not the first.
        Check.test("splits the pid at the last dot") {
            let row = NettopParser.parseRow("02:21:32.760799,com.apple.WebKit.12345,10,20,")
            Check.expectEqual(row?.processName, "com.apple.WebKit")
            Check.expectEqual(row?.pid, 12345)
        }

        // nettop does not quote CSV fields, so a comma in a process name would
        // break left-to-right indexing. Fields are read from the right instead.
        Check.test("survives a comma inside a process name") {
            let row = NettopParser.parseRow("02:21:32.760799,Weird,App.999,111,222,")
            Check.expectEqual(row?.pid, 999)
            Check.expectEqual(row?.bytesIn, 111)
            Check.expectEqual(row?.bytesOut, 222)
        }

        // Idle sockets emit empty numeric fields rather than zeros.
        Check.test("empty counters become zero") {
            let row = NettopParser.parseRow("02:21:32.760799,airportd.494,,,")
            Check.expectEqual(row?.pid, 494)
            Check.expectEqual(row?.bytesIn, 0)
            Check.expectEqual(row?.bytesOut, 0)
        }

        // `-P` is not passed, so these sub-rows are in every sample. Counting them
        // would double the parent process's traffic. They are carried on purpose:
        // the bytes they add to the stream are what keeps nettop's 16 KB pipe
        // buffer flushing every few seconds instead of every ~30.
        Check.test("rejects per-connection sub-rows") {
            Check.expectNil(NettopParser.parseRow(
                "02:21:32,tcp4 192.168.1.107:60282<->192.168.1.1:445,263,287,"))
            Check.expectNil(NettopParser.parseRow("02:21:32,udp4 *:*<->*:*,,,"))
        }

        // A whole sample of mixed rows must yield one entry per process and none
        // per socket, with each socket's bytes folded into its parent's local
        // total. This is the invariant the whole internet/LAN split rests on.
        Check.test("a mixed sample yields process rows only") {
            var parser = NettopParser()
            let sample = """
            time,,bytes_in,bytes_out,
            02:21:32,mDNSResponder.501,7845,6862,
            02:21:32,udp4 *:5353<->*:*,7845,6862,
            02:21:32,Google Chrome H.9312,4000,900,
            02:21:32,tcp4 10.0.0.2:51000<->142.250.0.1:443,4000,900,
            time,,bytes_in,bytes_out,
            02:21:33,mDNSResponder.501,10,20,
            02:21:33,udp4 *:5353<->*:*,10,20,
            time,,bytes_in,bytes_out,
            """
            // The trailing newline matters: `consume` only acts on completed lines,
            // and it is the *next* header that closes the sample before it.
            let samples = parser.consume(sample + "\n")
            // First sample is the cumulative priming one and is discarded.
            Check.expectEqual(samples.count, 1, "one delta sample should survive priming")
            Check.expectEqual(samples.first?.count, 1, "only the process row counts")
            Check.expectEqual(samples.first?.first?.pid, 501)
            Check.expectEqual(samples.first?.first?.bytesIn, 10)
            // mDNS is multicast, so every byte of it is local and none is internet.
            Check.expectEqual(samples.first?.first?.localBytesIn, 10)
            Check.expectEqual(samples.first?.first?.internetBytesIn, 0)
            Check.expectEqual(samples.first?.first?.subtractableLocalIn, 0,
                              "multicast is excluded from rows but never subtracted")
        }

        // The mirroring scenario end to end: one process, one LAN socket and one
        // internet socket, and only the internet half may reach a row.
        Check.test("a process split between LAN and internet reports only internet") {
            var parser = NettopParser()
            let sample = """
            time,,bytes_in,bytes_out,
            02:21:32,replayd.700,1,1,
            time,,bytes_in,bytes_out,
            02:21:33,replayd.700,5000,300,
            02:21:33,tcp4 192.168.1.107:51000<->192.168.1.42:7000,4000,200,
            02:21:33,tcp4 192.168.1.107:51001<->17.253.144.10:443,1000,100,
            time,,bytes_in,bytes_out,
            """
            let samples = parser.consume(sample + "\n")
            guard let row = samples.first?.first else {
                Check.expectNotNil(samples.first?.first, "no row parsed"); return
            }
            Check.expectEqual(row.bytesIn, 5000, "the parent row is the whole truth")
            Check.expectEqual(row.localBytesIn, 4000, "the Apple TV stream is local")
            Check.expectEqual(row.subtractableLocalIn, 4000,
                              "a unicast LAN peer is safe to take off the headline")
            Check.expectEqual(row.internetBytesIn, 1000, "only the routable socket counts")
            Check.expectEqual(row.internetBytesOut, 100)
        }

        // Sockets churn mid-sample, so children can momentarily exceed the parent.
        // That must clamp, never report a negative usage figure.
        Check.test("local bytes exceeding the parent clamp to zero") {
            let row = NettopRow(pid: 1, processName: "x", bytesIn: 100, bytesOut: 100,
                                localBytesIn: 500, localBytesOut: 500)
            Check.expectEqual(row.internetBytesIn, 0)
            Check.expectEqual(row.internetBytesOut, 0)
        }

        Check.test("rejects malformed rows") {
            Check.expectNil(NettopParser.parseRow(""))
            Check.expectNil(NettopParser.parseRow("garbage"))
            Check.expectNil(NettopParser.parseRow("02:21:32,noPidHere,1,2,"))
        }

        Check.test("recognises both header forms") {
            Check.expectTrue(NettopParser.isHeader("time,,bytes_in,bytes_out,"))
            Check.expectTrue(NettopParser.isHeader(",bytes_in,bytes_out,"))
            Check.expectFalse(NettopParser.isHeader("02:21:32.760799,mDNSResponder.501,1,2,"))
        }
    }

    Check.suite("Your own network's traffic on unconnected UDP sockets (#753)") {
        func sample(_ rows: String) -> [NettopRow] {
            var parser = NettopParser()
            let csv = "time,,interface,bytes_in,bytes_out,\n14:13:04,ExampleApp.1234,,20000,309,\n"
                + "time,,interface,bytes_in,bytes_out,\n" + rows + "\ntime,,interface,bytes_in,bytes_out,\n"
            return parser.consume(csv).first ?? []
        }
        let mixed = sample("""
        14:13:05,ExampleApp.1234,,120000,11000,
        14:13:05,udp4 *:63259<->*:*,en0,100000,10000,
        14:13:05,tcp4 192.168.1.2:58487<->203.0.113.55:443,en0,20000,1000,
        """)
        let epoch = UUID()
        func socket(pid: Int32 = 1234, interface: String = "en0", family: Int = 4, port: Int = 63259) -> UDPObservation.Socket {
            .init(pid: pid, interface: interface, family: family, port: port)
        }
        func usage(_ bytesIn: Int64, _ bytesOut: Int64, _ socket: UDPObservation.Socket = socket()) -> UDPUsageSnapshot {
            .init(epoch: epoch, sockets: [.init(socket: socket, bytesIn: bytesIn, bytesOut: bytesOut)])
        }
        let started = UDPUsageSnapshot(epoch: epoch, sockets: [])
        /// The last sample's row, after the helper gave each of `answers` in turn.
        func credited(_ sample: [NettopRow], _ answers: [UDPUsageSnapshot?], carrier: Bool = false) -> [NettopRow] {
            var credit = UDPUsageCredit(isCarrier: { _, _ in carrier })
            var result = sample
            for answer in answers { result = credit.apply(to: sample, interfaces: { ["en0"] }, snapshot: { answer }) }
            return result
        }

        Check.test("what stayed on your own network comes off, the rest stays internet") {
            let row = credited(mixed, [started, usage(75000, 5000)]).first
            Check.expectEqual(row?.subtractableLocalIn, 75000)
            Check.expectEqual(row?.subtractableLocalOut, 5000)
            Check.expectEqual(row?.internetBytesIn, 45000)
            Check.expectEqual(row?.internetBytesOut, 6000)
        }

        Check.test("it's never more than the socket moved") {
            let row = credited(mixed, [started, usage(900_000, 900_000)]).first
            Check.expectEqual(row?.internetBytesIn, 20000)
            Check.expectEqual(row?.internetBytesOut, 1000)
        }

        Check.test("only what was seen since the last sample counts") {
            let row = credited(mixed, [usage(500_000, 500_000), usage(510_000, 500_000)]).first
            Check.expectEqual(row?.localBytesIn, 10000)
            Check.expectEqual(row?.localBytesOut, 0)
        }

        Check.test("a dual-stack socket is udp6 to nettop and IPv4 on the wire") {
            let dual = sample("""
            14:13:05,ExampleApp.1234,,100000,0,
            14:13:05,udp6 *.63259<->*.*,en0,100000,0,
            """)
            Check.expectEqual(credited(dual, [started, usage(100_000, 0)]).first?.internetBytesIn, 0)
        }

        Check.test("a socket nettop names no interface for is matched too") {
            let receiver = sample("""
            14:13:05,ExampleApp.1234,,100000,0,
            14:13:05,udp4 *:63259<->*:*,,100000,0,
            """)
            Check.expectEqual(credited(receiver, [started, usage(100_000, 0)]).first?.internetBytesIn, 0)
        }

        Check.test("what's seen a moment before nettop counts it comes off the next sample, and no later") {
            var credit = UDPUsageCredit(isCarrier: { _, _ in false })
            let quiet = sample("""
            14:13:05,ExampleApp.1234,,20,0,
            14:13:05,udp4 *:63259<->*:*,en0,20,0,
            """)
            func next(_ sample: [NettopRow], _ answer: UDPUsageSnapshot) -> Int64? {
                credit.apply(to: sample, interfaces: { ["en0"] }, snapshot: { answer }).first?.internetBytesIn
            }
            Check.expectEqual(next(mixed, started), 120_000)
            Check.expectEqual(next(quiet, usage(90000, 0)), 0)
            Check.expectEqual(next(mixed, usage(90000, 0)), 120_000 - 89980)
            Check.expectEqual(next(mixed, usage(90000, 0)), 120_000)
        }

        Check.test("another process, another port or an interface that isn't counted takes nothing off") {
            for other in [socket(pid: 999), socket(port: 1), socket(interface: "en1")] {
                Check.expectEqual(credited(mixed, [started, usage(90000, 900, other)]), mixed)
            }
        }

        Check.test("no helper, a capture just started or counts that started again take nothing off") {
            Check.expectEqual(credited(mixed, [nil]), mixed)
            Check.expectEqual(credited(mixed, [usage(90000, 900)]), mixed)
            Check.expectEqual(credited(mixed, [started, nil, usage(90000, 900)]), mixed)
            let again = UDPUsageSnapshot(epoch: UUID(), sockets: usage(90000, 900).sockets)
            Check.expectEqual(credited(mixed, [started, again]), mixed)
        }

        Check.test("a connected socket on the same port is left to its own address") {
            let both = sample("""
            14:13:05,ExampleApp.1234,,200000,0,
            14:13:05,udp4 *:63259<->*:*,en0,100000,0,
            14:13:05,udp4 192.168.1.2:63259<->203.0.113.9:443,en0,100000,0,
            """)
            Check.expectEqual(credited(both, [started, usage(90000, 0)]), both)
        }

        Check.test("a VPN's own traffic to a gateway on your network is its apps' internet") {
            Check.expectEqual(credited(mixed, [started, usage(75000, 5000)], carrier: true), mixed)
        }

        Check.test("the helper isn't asked when there's next to nothing to place, or nothing") {
            let little = sample("""
            14:13:05,ExampleApp.1234,,100300,0,
            14:13:05,udp4 *:63259<->*:*,en0,300,0,
            14:13:05,udp4 *:5353<->*:*,en0,100000,0,
            """)
            var asked = 0
            var credit = UDPUsageCredit(isCarrier: { _, _ in false })
            _ = credit.apply(to: little, interfaces: { ["en0"] }, snapshot: { asked += 1; return started })
            Check.expectEqual(asked, 0)
            _ = credit.apply(to: mixed, interfaces: { ["en0"] }, snapshot: { asked += 1; return started })
            // Once it's counting, small samples are placed as well.
            _ = credit.apply(to: little, interfaces: { ["en0"] }, snapshot: { asked += 1; return started })
            Check.expectEqual(asked, 2)
        }

        Check.test("PKTAP's lines give the socket, the direction and the size") {
            let inbound = UDPObservation(
                line: "(en0, proc ExampleApp:1234, in) IP 192.168.1.42.4000 > 192.168.1.2.63259: UDP, length 519")
            Check.expectEqual(inbound?.socket, socket())
            Check.expectEqual(inbound?.remoteAddress, "192.168.1.42")
            Check.expectEqual(inbound?.bytes, 519)
            Check.expectEqual(inbound?.inbound, true)
            let outbound = UDPObservation(
                line: "(en0, proc ExampleApp:1234, eproc ExampleParent:321, out) IP6 fd00::2.63259 > fd00::42.4000: UDP, length 519")
            Check.expectEqual(outbound?.socket, socket(family: 6))
            Check.expectEqual(outbound?.remoteAddress, "fd00::42")
            Check.expectEqual(outbound?.inbound, false)
            Check.expectNil(UDPObservation(
                line: "(en0, in) IP 192.168.1.42.4000 > 192.168.1.2.63259: UDP, length 519"))
        }

        Check.test("the capture's filter is every range that counts as your own network, at both ends") {
            let filter = UDPObservation.filter
            for (range, address) in [("10.0.0.0/8", "10.1.2.3"), ("172.16.0.0/12", "172.31.255.1"),
                                     ("192.168.0.0/16", "192.168.64.1"), ("169.254.0.0/16", "169.254.3.4")] {
                Check.expectEqual(RemoteEndpoint.scopeOfIPv4(address), .localUnicast)
                Check.expectTrue(filter.contains("src net \(range)") && filter.contains("dst net \(range)"), range)
            }
            for (range, address) in [("fe80::/10", "febf::1"), ("fc00::/7", "fd12::1")] {
                Check.expectEqual(RemoteEndpoint.scopeOfIPv6(address), .localUnicast)
                Check.expectTrue(filter.contains("src net \(range)") && filter.contains("dst net \(range)"), range)
            }
        }

        Check.test("running counts add up per socket, and start again when there are too many") {
            var counts = UDPUsageCounts()
            let first = counts.epoch
            func packet(_ port: Int) -> UDPObservation {
                UDPObservation(line: "(en0, proc A:1, out) IP 192.168.1.2.\(port) > 192.168.1.3.9: UDP, length 10")!
            }
            counts.record(packet(1)); counts.record(packet(1))
            Check.expectEqual(counts.snapshot.sockets.first?.bytesOut, 20)
            for port in 2...UDPUsageCounts.maximumSockets { counts.record(packet(port)) }
            Check.expectEqual(counts.epoch, first)
            counts.record(packet(60000))
            Check.expectTrue(counts.epoch != first, "a new epoch")
            Check.expectEqual(counts.snapshot.sockets.count, 1)
        }
    }

    Check.suite("NettopParser — sample framing") {

        // The single most important behaviour in the app: nettop's first sample
        // is cumulative-since-process-start, not a delta. Counting it would
        // credit every process with all its traffic since boot — mDNSResponder
        // alone would arrive with 251 MB already on the clock.
        Check.test("discards the cumulative priming sample") {
            var parser = NettopParser()
            let stream = """
            time,,bytes_in,bytes_out,
            02:21:31.761125,mDNSResponder.501,263630067,238967705,
            time,,bytes_in,bytes_out,
            02:21:32.760799,mDNSResponder.501,7845,6862,
            time,,bytes_in,bytes_out,

            """
            let samples = parser.consume(stream)
            Check.expectEqual(samples.count, 1, "priming sample must be dropped")
            Check.expectEqual(samples.first?.first?.bytesIn, 7845)
        }

        // stdout arrives in arbitrary chunks; a row split mid-line must not be lost.
        Check.test("reassembles writes split mid-line") {
            var parser = NettopParser()
            Check.expectTrue(parser.consume("time,,bytes_in,bytes_out,\n").isEmpty)
            Check.expectTrue(parser.consume("02:21:31,mDNSResponder.501,100,200,\n").isEmpty)
            Check.expectTrue(parser.consume("time,,bytes_in,byt").isEmpty)
            Check.expectTrue(parser.consume("es_out,\n02:21:32,mDNSRespo").isEmpty)
            let samples = parser.consume("nder.501,7845,6862,\ntime,,bytes_in,bytes_out,\n")
            Check.expectEqual(samples.count, 1)
            Check.expectEqual(samples.first?.first?.bytesIn, 7845)
        }

        // After a restart the stream begins with a cumulative sample again.
        Check.test("restart discards the new priming sample") {
            var parser = NettopParser()
            _ = parser.consume("time,,a,b,\n02:21:31,proc.1,5,5,\ntime,,a,b,\n02:21:32,proc.1,7,7,\n")
            parser.resetForRestart()
            let samples = parser.consume("""
            time,,bytes_in,bytes_out,
            02:30:00,proc.1,999999,999999,
            time,,bytes_in,bytes_out,
            02:30:01,proc.1,42,42,
            time,,bytes_in,bytes_out,

            """)
            Check.expectEqual(samples.count, 1)
            Check.expectEqual(samples.first?.first?.bytesIn, 42,
                              "post-restart cumulative sample must be discarded")
        }

        Check.test("parses a multi-process sample in order") {
            var parser = NettopParser()
            _ = parser.consume("time,,bytes_in,bytes_out,\n02:21:31,proc.1,1,1,\n")
            let samples = parser.consume("""
            time,,bytes_in,bytes_out,
            02:21:32,Slack Helper.1532,168,162,
            02:21:32,Google Chrome H.1578,0,32,
            02:21:32,Claude Helper.63144,39,46,
            time,,bytes_in,bytes_out,

            """)
            Check.expectEqual(samples.count, 1)
            Check.expectEqual(samples.first?.count, 3)
            Check.expectEqual(samples.first?.map(\.pid) ?? [], [1532, 1578, 63144])
        }
    }

    /// The stream never marks the end of a sample, only the start of the next
    /// one, so waiting for a header published every app figure a whole sample
    /// interval after it was true. `NettopStream` closes on silence instead.
    Check.suite("NettopParser — closing a sample on silence") {

        Check.test("a complete sample closes without waiting for the next header") {
            var parser = NettopParser()
            _ = parser.consume("time,,bytes_in,bytes_out,\n02:21:31,proc.1,999,999,\n")
            Check.expectTrue(parser.closeOnQuiet() == nil, "the priming sample is dropped")

            _ = parser.consume("time,,bytes_in,bytes_out,\n02:21:32,proc.1,42,42,\n")
            Check.expectEqual(parser.closeOnQuiet()?.first?.bytesIn, 42)
        }

        // Closing mid-line would strand the connection rows that follow, and
        // `foldConnection` attaches those to the process row above — with nothing
        // pending they are dropped, and LAN bytes get counted as internet.
        Check.test("refuses while a line is half-delivered") {
            var parser = NettopParser()
            _ = parser.consume("time,,a,b,\n02:21:31,proc.1,9,9,\ntime,,a,b,\n")
            _ = parser.consume("02:21:32,proc.1,50,50,\n02:21:32,tcp4 10.0.0.2:1<->10.0.0")

            Check.expectTrue(parser.hasPartialLine)
            Check.expectTrue(parser.closeOnQuiet() == nil)

            // The rest arrives; the LAN row is folded into its parent, and only
            // then may the sample close.
            _ = parser.consume(".3:445,20,20,\n")
            let sample = parser.closeOnQuiet()
            Check.expectEqual(sample?.count, 1)
            Check.expectEqual(sample?.first?.internetBytesIn, 30)
        }

        // Whichever boundary comes first wins; the other must find nothing left.
        Check.test("a sample closed on silence is not published twice") {
            var parser = NettopParser()
            _ = parser.consume("time,,a,b,\n02:21:31,proc.1,9,9,\n")
            _ = parser.closeOnQuiet()
            _ = parser.consume("time,,a,b,\n02:21:32,proc.1,42,42,\n")
            Check.expectEqual(parser.closeOnQuiet()?.first?.bytesIn, 42)

            // The next header arrives with the sample already gone.
            Check.expectTrue(parser.consume("time,,a,b,\n").isEmpty)
            Check.expectTrue(parser.closeOnQuiet() == nil)
        }

        Check.test("silence with nothing pending yields nothing") {
            var parser = NettopParser()
            Check.expectTrue(parser.closeOnQuiet() == nil)
            _ = parser.consume("time,,a,b,\n")
            Check.expectTrue(parser.closeOnQuiet() == nil)
        }
    }

    Check.suite("NettopParser — servers") {

        // What Connections records: each internet socket's bytes, under the
        // address it talked to. LAN sockets never become servers.
        Check.test("splits a process's internet bytes by server, and leaves the LAN out") {
            var parser = NettopParser()
            let samples = parser.consume("""
            time,,bytes_in,bytes_out,
            02:21:32,Teams.700,1,1,
            time,,bytes_in,bytes_out,
            02:21:33,Teams.700,9000,900,
            02:21:33,tcp4 192.168.1.107:51000<->192.168.1.42:7000,4000,200,
            02:21:33,tcp4 192.168.1.107:51001<->52.112.0.1:443,3000,300,
            02:21:33,tcp4 192.168.1.107:51002<->52.112.0.1:443,1000,100,
            02:21:33,tcp6 2a02:a03f::1.51003<->2a00:1450:4001:82b::200e.443,1000,300,
            time,,bytes_in,bytes_out,

            """)
            guard let row = samples.first?.first else {
                Check.expectNotNil(samples.first?.first, "no row parsed"); return
            }
            Check.expectEqual(row.servers, [
                "52.112.0.1": ByteCounts(bytesIn: 4000, bytesOut: 400),
                "2a00:1450:4001:82b::200e": ByteCounts(bytesIn: 1000, bytesOut: 300),
            ], "two sockets to one server add up; the LAN peer isn't a server")
            Check.expectEqual(row.internetBytesIn, 5000, "the app's own figure is unchanged")
        }

        // A wildcard peer has no address, and an idle socket moved nothing.
        Check.test("records no server for a wildcard peer or an idle socket") {
            var parser = NettopParser()
            let samples = parser.consume("""
            time,,bytes_in,bytes_out,
            02:21:32,quic.800,1,1,
            time,,bytes_in,bytes_out,
            02:21:33,quic.800,500,50,
            02:21:33,udp4 *:61000<->*:*,500,50,
            02:21:33,tcp4 10.0.0.2:51000<->142.250.0.1:443,,,
            time,,bytes_in,bytes_out,

            """)
            Check.expectEqual(samples.first?.first?.servers, [:])
            Check.expectEqual(samples.first?.first?.internetBytesIn, 500, "still counted as internet")
        }

        Check.test("reads the remote address without its port") {
            Check.expectEqual(RemoteEndpoint.remoteHost(
                connectionLabel: "tcp4 192.168.1.107:54524<->142.251.173.188:443"), "142.251.173.188")
            Check.expectEqual(RemoteEndpoint.remoteHost(
                connectionLabel: "tcp6 fe80::1%en0.5000<->2a00:1450:4001:82b::200e.443"),
                              "2a00:1450:4001:82b::200e")
            Check.expectNil(RemoteEndpoint.remoteHost(connectionLabel: "udp4 *:5353<->*:*"))
        }

        // nettop reports QUIC as quic4 and quic6. Read as IPv4, a quic6 address
        // would be cut at its last colon.
        Check.test("reads a quic6 row as IPv6") {
            let label = "quic6 2a02:a03f::1.51003<->2a00:1450:4001:82b::200e.443"
            Check.expectEqual(RemoteEndpoint.remoteHost(connectionLabel: label), "2a00:1450:4001:82b::200e")
            Check.expectEqual(RemoteEndpoint.scope(connectionLabel: label), .internet)
            Check.expectEqual(RemoteEndpoint.scope(
                connectionLabel: "quic6 fe80::1%en0.51003<->fd00::42.443"), .localUnicast)
        }

        // One server must not be stored twice, once per socket family.
        Check.test("reads an IPv4-mapped peer as the IPv4 address, for scope and server alike") {
            Check.expectEqual(RemoteEndpoint.remoteHost(
                connectionLabel: "tcp6 ::ffff:192.168.1.107.51000<->::ffff:142.250.0.1.443"), "142.250.0.1")
            Check.expectEqual(RemoteEndpoint.scope(
                connectionLabel: "tcp6 ::ffff:192.168.1.107.51000<->::ffff:192.168.1.42.7000"), .localUnicast,
                              "a LAN peer is local whichever way it's written")
        }
    }
}
