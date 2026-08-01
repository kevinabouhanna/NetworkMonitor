import Foundation
import NetworkMonitorCore

func runTrafficScopeTests() {

    /// Real labels, captured verbatim from `nettop -n` on the development machine.
    Check.suite("RemoteEndpoint — classifying real nettop labels") {

        Check.test("routable addresses are internet") {
            for label in [
                "tcp4 192.168.1.107:54530<->160.79.104.10:443",
                "tcp4 192.168.1.107:54524<->142.251.173.188:5228",
                "tcp4 192.168.1.107:54594<->140.82.113.26:443",
                "tcp4 192.168.1.107:54595<->20.184.175.13:443",
            ] {
                Check.expectEqual(RemoteEndpoint.scope(connectionLabel: label), .internet,
                                  "should be internet: \(label)")
            }
        }

        // The mirroring case. An Apple TV on the same Wi-Fi is 192.168.x.x, and its
        // stream crosses en0 exactly like a download does. These are unicast, so
        // their byte counts can be trusted and subtracted.
        Check.test("named LAN peers are local unicast") {
            for label in [
                "tcp4 192.168.1.107:54630<->192.168.1.1:445",      // SMB to the router
                "tcp4 192.168.1.107:51000<->192.168.1.42:7000",    // AirPlay to an Apple TV
                "tcp4 10.0.0.5:51000<->10.0.0.9:445",              // 10/8
                "tcp4 172.16.0.5:51000<->172.20.1.9:443",          // 172.16/12
                "tcp4 169.254.1.2:100<->169.254.9.9:80",           // link-local
            ] {
                let scope = RemoteEndpoint.scope(connectionLabel: label)
                Check.expectEqual(scope, .localUnicast, "should be local unicast: \(label)")
                Check.expectTrue(scope.isLocal)
                Check.expectTrue(scope.isSubtractable, "unicast LAN is trustworthy")
            }
        }

        // 73.6% of all connection bytes measured on this machine. Local beyond
        // doubt, but the *quantity* is fiction: these sockets are multi-homed and
        // nettop bills their full byte count under every interface type they
        // match. Over 90 s it claimed 1,360 KB of multicast while the kernel's own
        // packet counters recorded 72 multicast packets on en0 — 108 KB even at
        // full MTU, so the claim exceeds the physical maximum by at least 12.6x.
        // Subtracting it once produced a headline smaller than its own rows.
        Check.test("multicast is local but never subtractable") {
            for label in [
                "udp4 *:5353<->*:*",
                "udp6 *.5353<->*.*",
                "udp4 *:1900<->*:*",
                "udp4 192.168.1.107:5353<->224.0.0.251:5353",
                "udp4 10.0.0.2:137<->255.255.255.255:137",
            ] {
                let scope = RemoteEndpoint.scope(connectionLabel: label)
                Check.expectEqual(scope, .localMulticast, "should be multicast: \(label)")
                Check.expectTrue(scope.isLocal, "still kept out of the app rows")
                Check.expectFalse(scope.isSubtractable,
                                  "its size is inflated by multi-homed accounting")
            }
        }

        // IPv6 punctuates the port with a dot and may carry a zone; splitting on
        // the last colon would truncate the address and misclassify it.
        Check.test("IPv6 link-local, with a zone, is local") {
            let label = "tcp6 fe80::1c98:eeba:57c2:d2da%en0.54527"
                + "<->fe80::c83:7ffb:2270:1a03%en0.60614"
            Check.expectEqual(RemoteEndpoint.scope(connectionLabel: label), .localUnicast)
            Check.expectEqual(RemoteEndpoint.host(of: "fe80::c83:7ffb:2270:1a03%en0.60614",
                                                  isIPv6: true),
                              "fe80::c83:7ffb:2270:1a03")
        }

        Check.test("IPv6 unique-local and multicast are local, global is not") {
            Check.expectEqual(RemoteEndpoint.scopeOfIPv6("fd00::1"), .localUnicast)
            Check.expectEqual(RemoteEndpoint.scopeOfIPv6("ff02::fb"), .localMulticast)
            Check.expectEqual(RemoteEndpoint.scopeOfIPv6("::1"), .localUnicast)
            Check.expectEqual(RemoteEndpoint.scopeOfIPv6("2a00:1450:4001:80f::200e"), .internet)
        }

        // Carrier-grade NAT looks private and is not. Tailscale hands out 100.x
        // addresses and mobile carriers NAT behind them: those bytes really do
        // leave the building, and hiding them would under-report usage.
        Check.test("carrier-grade NAT counts as internet") {
            Check.expectEqual(RemoteEndpoint.scopeOfIPv4("100.64.0.1"), .internet)
            Check.expectEqual(RemoteEndpoint.scopeOfIPv4("100.101.102.103"), .internet)
            // The neighbours either side of 100.64/10 are ordinary internet too.
            Check.expectEqual(RemoteEndpoint.scopeOfIPv4("100.63.255.255"), .internet)
            Check.expectEqual(RemoteEndpoint.scopeOfIPv4("100.128.0.1"), .internet)
        }

        // 172.16/12 is local; 172.15 and 172.32 are ordinary internet. Off-by-one
        // here would silently delete a chunk of someone's usage.
        Check.test("the 172.16/12 boundary is exact") {
            Check.expectEqual(RemoteEndpoint.scopeOfIPv4("172.15.255.255"), .internet)
            Check.expectEqual(RemoteEndpoint.scopeOfIPv4("172.16.0.0"), .localUnicast)
            Check.expectEqual(RemoteEndpoint.scopeOfIPv4("172.31.255.255"), .localUnicast)
            Check.expectEqual(RemoteEndpoint.scopeOfIPv4("172.32.0.0"), .internet)
        }

        // Under-reporting is the one error this app cannot afford: a row it cannot
        // read is not evidence that the bytes stayed on the LAN.
        Check.test("anything unreadable counts as internet") {
            for label in ["", "garbage", "tcp4 no-arrow-here", "udp4 *:9999<->*:*"] {
                Check.expectEqual(RemoteEndpoint.scope(connectionLabel: label), .internet,
                                  "unreadable rows must not vanish: \(label)")
            }
        }
    }
}
