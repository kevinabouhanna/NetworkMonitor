import Foundation
import NetworkMonitorCore

/// Traffic through a proxy or VPN, credited to the apps behind it (#356).
/// The nettop lines are from a VM running Mihomo 1.19.34 in TUN mode (system
/// stack) while `curl` downloaded through it, from
/// `nettop -n -x -d -L 0 -s 2 -J time,interface,bytes_in,bytes_out`.
func runTunnelCreditTests() {
    let header = "time,,interface,bytes_in,bytes_out,"
    let tunSample = [
        "19:14:23.462073,mihomo.733,,2100001,2123166,",
        "19:14:23.461581,tcp6 fdfe:dcba:9876::1.49170<->*.*,utun4,,,",
        "19:14:23.461537,tcp4 127.0.0.1:7890<->*:*,lo0,,,",
        "19:14:23.460952,tcp4 198.18.0.1:49167<->198.18.0.2:10000,utun4,0,2120766,",
        "19:14:23.460919,tcp4 192.168.64.67:49173<->162.159.140.220:443,en0,2098454,0,",
        "19:14:23.462141,curl.782,,2120766,0,",
        "19:14:23.460985,tcp4 198.18.0.1:49172<->162.159.140.220:443,utun4,2120766,0,",
    ]
    // The same moment through Mihomo set as the system's proxy: the app talks
    // to 127.0.0.1:7890, and Mihomo also asks a DNS server on loopback.
    let proxySample = [
        "10:00:01.000000,mihomo.733,,5300,5600,",
        "10:00:01.000000,tcp4 127.0.0.1:7890<->127.0.0.1:51234,lo0,300,5000,",
        "10:00:01.000000,udp4 127.0.0.1:50123<->127.0.0.1:53,lo0,80,40,",
        "10:00:01.000000,tcp4 192.168.64.67:49180<->162.159.140.220:443,en0,4920,260,",
        "10:00:01.000000,Safari.900,,5000,300,",
        "10:00:01.000000,tcp4 127.0.0.1:51234<->127.0.0.1:7890,lo0,5000,300,",
        "10:00:01.000000,dnsd.40,,40,80,",
        "10:00:01.000000,udp4 127.0.0.1:53<->127.0.0.1:50123,lo0,40,80,",
    ]
    func parse(_ lines: [String]) -> [NettopRow] {
        // The first sample is a baseline, and is discarded.
        var parser = NettopParser()
        let samples = parser.consume(([header] + lines + [header] + lines + [header]).joined(separator: "\n") + "\n")
        return samples.last ?? []
    }
    // What `-t external` showed in the VM: everything as Mihomo's.
    let main = [NettopRow(pid: 733, processName: "mihomo", bytesIn: 21_525_992, bytesOut: 91_068),
                NettopRow(pid: 300, processName: "mobileassetd", bytesIn: 1000, bytesOut: 10)]
    let byName: (NettopRow) -> Bool = { TunnelCarrier.isCarrier(processName: $0.processName, path: nil) }

    Check.suite("Tunnel credit — reading nettop with interfaces (#356)") {
        Check.test("an app's bytes into a proxy's tunnel are its tunnel bytes") {
            let rows = parse(tunSample)
            let curl = rows.first { $0.processName == "curl" }
            Check.expectEqual(curl?.tunnels["utun4"], ByteCounts(bytesIn: 2_120_766, bytesOut: 0))
            Check.expectEqual(curl?.internetBytesIn, 2_120_766)
            Check.expectEqual(curl?.servers["162.159.140.220"]?.bytesIn, 2_120_766)
            let mihomo = rows.first { $0.processName == "mihomo" }
            Check.expectEqual(mihomo?.bytesIn, 2_100_001, "the process row's own figure")
        }

        Check.test("a socket on loopback is kept by its ports, and isn't LAN traffic") {
            let rows = parse(proxySample)
            let safari = rows.first { $0.processName == "Safari" }
            Check.expectEqual(safari?.loopback, [LoopbackSocket(localPort: 51234, remotePort: 7890,
                                                                bytesIn: 5000, bytesOut: 300)])
            Check.expectEqual(safari?.localBytesIn, 0)
            Check.expectEqual(safari?.subtractableLocalIn, 0)
        }

        Check.test("rows without an interface column read as before") {
            var parser = NettopParser()
            let text = ["time,,bytes_in,bytes_out,", "1,curl.7,10,20,", "time,,bytes_in,bytes_out,",
                        "2,curl.7,30,40,", "2,tcp4 10.0.0.2:5<->1.1.1.1:443,30,40,", "time,,bytes_in,bytes_out,"]
            let samples = parser.consume(text.joined(separator: "\n") + "\n")
            Check.expectEqual(samples.last?.first?.bytesIn, 30)
            Check.expectEqual(samples.last?.first?.servers["1.1.1.1"], ByteCounts(bytesIn: 30, bytesOut: 40))
            Check.expectTrue(samples.last?.first?.tunnels.isEmpty == true)
        }

        Check.test("a tunnel is utun, ipsec…, never a link") {
            Check.expectTrue(NettopParser.isTunnel("utun4") && NettopParser.isTunnel("ipsec0"))
            Check.expectFalse(NettopParser.isTunnel("en0") || NettopParser.isTunnel("lo0"))
        }
    }

    Check.suite("Tunnel credit — who carries the traffic (#356)") {
        Check.test("proxies by name") {
            for name in ["mihomo", "verge-mihomo", "Clash Verge", "sing-box", "FlClashCore", "xray"] {
                Check.expectTrue(TunnelCarrier.isCarrier(processName: name, path: nil), name)
            }
            Check.expectTrue(TunnelCarrier.isCarrier(processName: "verge-mihomo-al",
                                                     path: "/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo-alpha"))
            for name in ["Safari", "curl", "Google Chrome H"] {
                Check.expectFalse(TunnelCarrier.isCarrier(processName: name, path: nil), name)
            }
        }

        Check.test("any Network Extension packet tunnel, an app extension's or a system extension's") {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("carrier-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            func bundle(_ name: String, _ plist: [String: Any]) -> String {
                let contents = dir.appendingPathComponent("\(name)/Contents")
                try? FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"),
                                                         withIntermediateDirectories: true)
                let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try? data.write(to: contents.appendingPathComponent("Info.plist"))
                return contents.appendingPathComponent("MacOS/provider").path
            }
            let appex = bundle("VPN.app/Contents/PlugIns/Tunnel.appex",
                               ["NSExtension": ["NSExtensionPointIdentifier": "com.apple.networkextension.packet-tunnel"]])
            let sysext = bundle("Library/SystemExtensions/x/com.example.tunnel.systemextension",
                                ["NetworkExtension": ["NEProviderClasses": ["com.apple.networkextension.packet-tunnel": "Provider"]]])
            let filter = bundle("Filter.systemextension",
                                ["NetworkExtension": ["NEProviderClasses": ["com.apple.networkextension.filter-data": "Filter"]]])
            Check.expectTrue(TunnelCarrier.isCarrier(processName: "provider", path: appex))
            Check.expectTrue(TunnelCarrier.isCarrier(processName: "provider", path: sysext))
            Check.expectFalse(TunnelCarrier.isCarrier(processName: "provider", path: filter), "a content filter carries nothing")
            Check.expectFalse(TunnelCarrier.isCarrier(processName: "Safari",
                                                      path: "/Applications/Safari.app/Contents/MacOS/Safari"))
        }
    }

    Check.suite("Tunnel credit — crediting the apps (#356)") {
        Check.test("an app's bytes into a tunnel the main stream can't see are what it has hidden") {
            let hidden = TunnelCredit.hidden(in: parse(tunSample), visibleTunnels: [], isCarrier: byName)
            Check.expectEqual(hidden[782], TunnelCredit.Hidden(processName: "curl",
                                                              bytes: ByteCounts(bytesIn: 2_120_766, bytesOut: 0)))
            Check.expectNil(hidden[733], "the carrier's own tunnel rows are its copy")
            Check.expectTrue(TunnelCredit.hidden(in: parse(tunSample), visibleTunnels: ["utun4"], isCarrier: byName).isEmpty,
                             "a tunnel the main stream shows is counted there")
            Check.expectTrue(TunnelCredit.hidden(in: parse(tunSample), visibleTunnels: [], isCarrier: { _ in false }).isEmpty,
                             "with no carrier, nothing is moved")
        }

        Check.test("an app using the proxy over loopback; not a server the proxy asks") {
            let hidden = TunnelCredit.hidden(in: parse(proxySample), visibleTunnels: [], isCarrier: byName)
            Check.expectEqual(hidden[900]?.bytes, ByteCounts(bytesIn: 5000, bytesOut: 300))
            Check.expectNil(hidden[40], "the DNS server Mihomo asked isn't using the proxy")
        }

        Check.test("credited to the app, taken off the carrier, adding up to the same") {
            let hidden: [Int32: TunnelCredit.Hidden] = [
                782: .init(processName: "curl", bytes: ByteCounts(bytesIn: 20_053_748, bytesOut: 544)),
            ]
            let result = TunnelCredit.apply(to: main, hidden: hidden, isCarrier: byName)
            let curl = result.rows.first { $0.pid == 782 }
            Check.expectEqual(curl?.internetBytesIn, 20_053_748)
            Check.expectEqual(curl?.processName, "curl")
            Check.expectEqual(result.rows.first { $0.pid == 733 }?.internetBytesIn, 21_525_992 - 20_053_748)
            Check.expectEqual(result.rows.first { $0.pid == 300 }?.bytesIn, 1000)
            Check.expectEqual(result.rows.reduce(0) { $0 + $1.internetBytesIn }, main.reduce(0) { $0 + $1.internetBytesIn })
            Check.expectEqual(result.carriers, [733])
            Check.expectTrue(result.left.isEmpty)
        }

        Check.test("never more than the carrier moved; the rest waits") {
            let hidden: [Int32: TunnelCredit.Hidden] = [
                1: .init(processName: "a", bytes: ByteCounts(bytesIn: 30_000_000, bytesOut: 0)),
                2: .init(processName: "b", bytes: ByteCounts(bytesIn: 10_000_000, bytesOut: 0)),
            ]
            let result = TunnelCredit.apply(to: main, hidden: hidden, isCarrier: byName)
            let a = result.rows.first { $0.pid == 1 }?.bytesIn ?? 0
            let b = result.rows.first { $0.pid == 2 }?.bytesIn ?? 0
            Check.expectTrue(a + b <= 21_525_992 && a + b > 21_525_990, "credited \(a + b)")
            Check.expectEqual(Double(a) / Double(b), 3, accuracy: 0.001)
            Check.expectEqual(Double(result.rows.first { $0.pid == 733 }?.internetBytesIn ?? -1), 0, accuracy: 2)
            Check.expectEqual((result.left[1]?.bytes.bytesIn ?? 0) + (result.left[2]?.bytes.bytesIn ?? 0) + a + b,
                              40_000_000)
        }

        Check.test("with no carrier in the sample, nothing changes") {
            let hidden: [Int32: TunnelCredit.Hidden] = [1: .init(processName: "a", bytes: ByteCounts(bytesIn: 5, bytesOut: 5))]
            let rows = [NettopRow(pid: 9, processName: "Safari", bytesIn: 100, bytesOut: 10)]
            let result = TunnelCredit.apply(to: rows, hidden: hidden, isCarrier: byName)
            Check.expectEqual(result.rows, rows)
            Check.expectTrue(result.carriers.isEmpty)
        }

        Check.test("a VPN's tunnel the main stream shows: counted once, as the app's") {
            let rows = [NettopRow(pid: 50, processName: "sing-box", bytesIn: 1_100_000, bytesOut: 60_000),
                        NettopRow(pid: 51, processName: "Safari", bytesIn: 1_000_000, bytesOut: 50_000,
                                  tunnels: ["utun3": ByteCounts(bytesIn: 1_000_000, bytesOut: 50_000)])]
            let result = TunnelCredit.apply(to: rows, hidden: [:], isCarrier: byName)
            Check.expectEqual(result.rows.first { $0.pid == 51 }?.bytesIn, 1_000_000)
            Check.expectEqual(result.rows.first { $0.pid == 50 }?.bytesIn, 100_000)
            Check.expectEqual(result.rows.first { $0.pid == 50 }?.bytesOut, 10_000)
        }
    }

    Check.suite("Tunnel credit — the second nettop (#356)") {
        Check.test("runs only while a carrier moves traffic, and credits what it saw") {
            let creditor = TunnelCreditor(stream: NettopStream(executable: "/nonexistent/nettop", interfaces: .all),
                                          isCarrier: { _, name in TunnelCarrier.isCarrier(processName: name, path: nil) })
            defer { creditor.stop() }
            var active: [Int32?] = []
            creditor.onActiveCarrierChange = { active.append($0) }
            let start = Date()
            let quiet = [NettopRow(pid: 9, processName: "Safari", bytesIn: 100, bytesOut: 10)]
            _ = creditor.credit(quiet, now: start)
            Check.expectFalse(creditor.isRunning, "started with no carrier")

            _ = creditor.credit(main, now: start.addingTimeInterval(1))
            Check.expectTrue(creditor.isRunning, "didn't start for Mihomo's traffic")
            creditor.record(parse(tunSample))
            let rows = creditor.credit(main, now: start.addingTimeInterval(2))
            Check.expectEqual(rows.first { $0.pid == 782 }?.bytesIn, 2_120_766)
            Check.expectEqual(active, [733])

            // Credited once: the next sample has nothing new to give.
            let next = creditor.credit(main, now: start.addingTimeInterval(3))
            Check.expectNil(next.first { $0.pid == 782 })

            _ = creditor.credit(quiet, now: start.addingTimeInterval(70))
            Check.expectEqual(active, [733, nil], "Network still names the carrier a minute later")
            _ = creditor.credit(quiet, now: start.addingTimeInterval(130))
            Check.expectFalse(creditor.isRunning, "still running two minutes after the carrier went quiet")
        }
    }
}
