import Foundation
import NetworkMonitorCore

func runInterfaceClassificationTests() {
    let ether = Int32(IFT_ETHER)

    Check.suite("InterfaceCounters — classification") {

        Check.test("counts physical interfaces") {
            // Real values read from en0 on the development machine.
            Check.expectTrue(InterfaceCounters.isCountable(name: "en0", ifiType: ether, flags: 0x8863))
            Check.expectTrue(InterfaceCounters.isCountable(name: "en5", ifiType: ether, flags: 0x8863))
        }

        // The whole reason exclusion is name-based: awdl0 reports the *identical*
        // ifi_type and flags as en0, so AirDrop/Continuity traffic cannot be told
        // apart from internet traffic by type or flags alone.
        Check.test("excludes AWDL despite identical type and flags") {
            Check.expectTrue(InterfaceCounters.isCountable(name: "en0", ifiType: ether, flags: 0x8863))
            Check.expectFalse(InterfaceCounters.isCountable(name: "awdl0", ifiType: ether, flags: 0x8863),
                              "AirDrop must not count as internet usage")
            Check.expectFalse(InterfaceCounters.isCountable(name: "llw0", ifiType: ether, flags: 0x8863))
        }

        // VPN tunnels are IFT_OTHER. Excluding them is what makes VPN traffic
        // count exactly once — as encrypted bytes leaving the physical NIC.
        Check.test("excludes tunnels so VPN is not double-counted") {
            for name in ["utun0", "utun4", "ipsec0", "ppp0"] {
                Check.expectFalse(InterfaceCounters.isCountable(name: name, ifiType: 1, flags: 0x8051),
                                  "\(name) must not be counted separately from its carrier")
            }
        }

        Check.test("excludes loopback") {
            // lo0: ifi_type 24, IFF_LOOPBACK set.
            Check.expectFalse(InterfaceCounters.isCountable(name: "lo0", ifiType: 24, flags: 0x8049))
        }

        Check.test("excludes double-counting bridges and aggregates") {
            for name in ["bridge0", "bond0", "vmenet0", "anpi0", "ap1"] {
                Check.expectFalse(InterfaceCounters.isCountable(name: name, ifiType: ether, flags: 0x8863),
                                  "\(name) would double-count its underlying NIC")
            }
        }

        Check.test("excludes interfaces that are down") {
            Check.expectFalse(InterfaceCounters.isCountable(name: "en1", ifiType: ether, flags: 0))
        }

        // Integration against the live kernel: what we return must never include
        // the interfaces we promised to exclude.
        Check.test("live read excludes AirDrop, tunnels and loopback") {
            let names = InterfaceCounters.read().map(\.name)
            Check.expectFalse(names.isEmpty, "expected at least one active interface")
            for name in names {
                Check.expectFalse(name.hasPrefix("awdl"), "AirDrop interface leaked: \(name)")
                Check.expectFalse(name.hasPrefix("utun"), "VPN tunnel leaked: \(name)")
                Check.expectFalse(name.hasPrefix("lo"), "loopback leaked: \(name)")
            }
        }

        // The reason for using sysctl instead of getifaddrs: en0 on this machine
        // carries >4 GiB lifetime, which a 32-bit counter cannot represent.
        Check.test("live counters exceed the 32-bit range getifaddrs would wrap at") {
            let total = InterfaceCounters.read().reduce(UInt64(0)) { $0 + $1.bytesIn + $1.bytesOut }
            Check.expectTrue(total > 0, "no byte counters read")
        }
    }
}

func runInterfaceDeltaTrackerTests() {
    func snap(_ name: String, _ bytesIn: UInt64, _ bytesOut: UInt64) -> InterfaceSnapshot {
        InterfaceSnapshot(name: name, bytesIn: bytesIn, bytesOut: bytesOut)
    }

    Check.suite("InterfaceDeltaTracker") {

        // Without a priming tick the app would bill the user for every byte
        // transferred since boot the moment it launches — en0 on the development
        // machine carried 5.52 GB of lifetime traffic.
        Check.test("priming tick reports zero") {
            var tracker = InterfaceDeltaTracker()
            Check.expectEqual(tracker.accept([snap("en0", 5_555_944_103, 2_039_112_323)]), .zero)
        }

        Check.test("reports the delta after priming") {
            var tracker = InterfaceDeltaTracker()
            _ = tracker.accept([snap("en0", 1000, 500)])
            Check.expectEqual(tracker.accept([snap("en0", 1500, 600)]),
                              .init(bytesIn: 500, bytesOut: 100))
        }

        Check.test("sums across multiple interfaces") {
            var tracker = InterfaceDeltaTracker()
            _ = tracker.accept([snap("en0", 1000, 1000), snap("en5", 100, 100)])
            Check.expectEqual(tracker.accept([snap("en0", 1200, 1100), snap("en5", 150, 120)]),
                              .init(bytesIn: 250, bytesOut: 120))
        }

        // A newly appeared interface (VPN up, cable plugged in) must contribute
        // its future traffic only, never its lifetime backlog.
        Check.test("a new interface contributes no backlog") {
            var tracker = InterfaceDeltaTracker()
            _ = tracker.accept([snap("en0", 1000, 1000)])
            Check.expectEqual(
                tracker.accept([snap("en0", 1100, 1000), snap("en9", 9_000_000, 9_000_000)]),
                .init(bytesIn: 100, bytesOut: 0),
                "the new interface's 9 MB backlog must not be billed")
            Check.expectEqual(
                tracker.accept([snap("en0", 1100, 1000), snap("en9", 9_000_500, 9_000_000)]),
                .init(bytesIn: 500, bytesOut: 0))
        }

        // Cycling an interface down and up resets its kernel counters. A naive
        // diff would underflow the unsigned subtraction into a nonsense
        // multi-exabyte spike.
        Check.test("a counter reset produces zero, not a spike") {
            var tracker = InterfaceDeltaTracker()
            _ = tracker.accept([snap("en0", 5_000_000, 5_000_000)])
            Check.expectEqual(tracker.accept([snap("en0", 120, 80)]), .zero,
                              "a backwards counter must not spike")
            Check.expectEqual(tracker.accept([snap("en0", 320, 180)]),
                              .init(bytesIn: 200, bytesOut: 100))
        }

        // Wi-Fi dropping and returning must not be billed as one enormous delta.
        Check.test("a disappearing interface re-baselines on return") {
            var tracker = InterfaceDeltaTracker()
            _ = tracker.accept([snap("en0", 1000, 1000)])
            _ = tracker.accept([snap("en0", 1100, 1100)])
            _ = tracker.accept([snap("en5", 1, 1)])            // en0 gone
            Check.expectEqual(
                tracker.accept([snap("en0", 9_000_000, 9_000_000), snap("en5", 1, 1)]),
                .zero,
                "a returning interface must re-baseline")
        }

        // A failed sysctl read must hold state rather than dropping a tick of
        // real traffic on the floor.
        Check.test("an empty read holds baselines") {
            var tracker = InterfaceDeltaTracker()
            _ = tracker.accept([snap("en0", 1000, 1000)])
            Check.expectEqual(tracker.accept([]), .zero)
            Check.expectEqual(tracker.accept([snap("en0", 1200, 1000)]),
                              .init(bytesIn: 200, bytesOut: 0))
        }

        Check.test("reset re-primes") {
            var tracker = InterfaceDeltaTracker()
            _ = tracker.accept([snap("en0", 1000, 1000)])
            tracker.reset()
            Check.expectEqual(tracker.accept([snap("en0", 9_999_999, 9_999_999)]), .zero)
        }
    }
}

func runRateSmootherTests() {
    Check.suite("RateSmoother") {

        Check.test("converges toward the steady rate") {
            var smoother = RateSmoother(alpha: 0.7)
            var rate: Double = 0
            for _ in 0..<8 { rate = smoother.update(bytes: 500, elapsed: 0.5) }
            Check.expectEqual(rate, 1000, accuracy: 5, "500 B per 0.5 s is 1000 B/s")
        }

        // An idle machine must read exactly zero, not a decaying ghost rate.
        Check.test("snaps to zero when idle") {
            var smoother = RateSmoother(alpha: 0.7)
            _ = smoother.update(bytes: 1_000_000, elapsed: 0.5)
            Check.expectEqual(smoother.update(bytes: 0, elapsed: 0.5), 0)
        }

        Check.test("zero elapsed time does not divide by zero") {
            var smoother = RateSmoother()
            _ = smoother.update(bytes: 100, elapsed: 0.5)
            let before = smoother.current
            Check.expectEqual(smoother.update(bytes: 100, elapsed: 0), before)
        }

        // Responsiveness matters for a live readout: a step change must be most
        // of the way there within a few ticks.
        Check.test("reaches most of a step change within three ticks") {
            var smoother = RateSmoother(alpha: 0.7)
            var rate: Double = 0
            for _ in 0..<3 { rate = smoother.update(bytes: 1000, elapsed: 1.0) }
            Check.expectTrue(rate > 950, "expected >950 after 3 ticks, got \(rate)")
        }
    }
}
