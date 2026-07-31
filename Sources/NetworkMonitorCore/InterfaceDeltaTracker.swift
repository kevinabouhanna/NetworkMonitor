import Foundation

/// Converts successive lifetime-counter snapshots into per-tick byte deltas.
///
/// Pure and synchronous so the awkward cases can actually be tested: an
/// interface appearing mid-session (VPN up, cable plugged in), an interface
/// disappearing, and a counter going *backwards* when an interface is cycled
/// down and up. Each of those must contribute zero rather than a spike or a
/// negative rate.
public struct InterfaceDeltaTracker {

    private var baselines: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
    private var primed = false

    public init() {}

    public struct Delta: Equatable {
        public var bytesIn: Int64
        public var bytesOut: Int64

        public init(bytesIn: Int64, bytesOut: Int64) {
            self.bytesIn = bytesIn
            self.bytesOut = bytesOut
        }

        public static let zero = Delta(bytesIn: 0, bytesOut: 0)
    }

    /// Folds a new snapshot set into the tracker and returns the bytes
    /// transferred since the previous call.
    public mutating func accept(_ snapshots: [InterfaceSnapshot]) -> Delta {
        // An empty read means sysctl failed. Holding the baselines and
        // reporting zero is right: treating it as "all interfaces vanished"
        // would re-baseline everything and lose a tick of real traffic.
        guard !snapshots.isEmpty else { return .zero }

        var delta = Delta.zero
        var seen = Set<String>()

        for snapshot in snapshots {
            seen.insert(snapshot.name)

            guard let previous = baselines[snapshot.name] else {
                // First sighting. Adopt its lifetime total as the baseline so
                // we never bill the user for traffic that predates us.
                baselines[snapshot.name] = (snapshot.bytesIn, snapshot.bytesOut)
                continue
            }

            // Counters only move forward while an interface stays up. A
            // decrease means it was reset, so re-baseline and skip this tick.
            if snapshot.bytesIn < previous.bytesIn || snapshot.bytesOut < previous.bytesOut {
                baselines[snapshot.name] = (snapshot.bytesIn, snapshot.bytesOut)
                continue
            }

            delta.bytesIn += Int64(snapshot.bytesIn - previous.bytesIn)
            delta.bytesOut += Int64(snapshot.bytesOut - previous.bytesOut)
            baselines[snapshot.name] = (snapshot.bytesIn, snapshot.bytesOut)
        }

        // Forget interfaces that went away; if one returns it re-baselines
        // rather than emitting the gap as one huge delta.
        for name in baselines.keys where !seen.contains(name) {
            baselines.removeValue(forKey: name)
        }

        // The priming tick establishes baselines only.
        guard primed else {
            primed = true
            return .zero
        }
        return delta
    }

    /// Drops all state, e.g. after a long sleep where counters are untrustworthy.
    public mutating func reset() {
        baselines.removeAll()
        primed = false
    }
}

/// Smooths a byte-per-second rate so the menu bar reads steadily without
/// lagging behind reality.
///
/// Raw 0.5 s samples are visibly jittery; a light exponential moving average
/// removes most of that while still reaching ~95% of a step change in about
/// three ticks (1.5 s). It also snaps straight to zero when traffic stops so an
/// idle machine doesn't display a decaying ghost rate.
public struct RateSmoother {
    private var value: Double = 0
    private let alpha: Double

    public init(alpha: Double = 0.7) {
        self.alpha = alpha
    }

    public mutating func update(bytes: Int64, elapsed: TimeInterval) -> Double {
        guard elapsed > 0 else { return value }
        let instant = Double(bytes) / elapsed
        if instant <= 0 {
            value = 0
        } else {
            value = value * (1 - alpha) + instant * alpha
        }
        return value
    }

    public var current: Double { value }

    public mutating func reset() { value = 0 }
}

/// Monotonic wall-clock source in seconds.
///
/// `CLOCK_MONOTONIC_RAW` is immune to NTP slew and manual clock changes, both of
/// which would corrupt a rate computed from `Date()` — an NTP correction during
/// a tick could produce a negative or absurd elapsed time.
public enum MonotonicClock {
    public static func now() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }
}
