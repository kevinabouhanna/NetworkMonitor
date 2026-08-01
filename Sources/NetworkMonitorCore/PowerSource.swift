import Foundation
import IOKit.ps

/// Whether the Mac is on wall power.
///
/// Drives `PowerProfile`, which trades time resolution — never accuracy — for
/// battery. It is not used to switch anything off: per-app tracking always runs.
public enum PowerSource {

    public static var isOnACPower: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeRetainedValue()
        else {
            // A desktop Mac has no battery; assuming AC is the safe default.
            return true
        }
        return (type as String) == kIOPSACPowerValue
    }

    /// Calls `handler` on the main run loop whenever the power source changes.
    /// Returns a token that must be retained; releasing it stops the watch.
    public static func observe(_ handler: @escaping () -> Void) -> Any? {
        let box = Box(handler)
        let context = Unmanaged.passRetained(box).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<Box>.fromOpaque(context).takeUnretainedValue().handler()
        }, context)?.takeRetainedValue() else {
            Unmanaged<Box>.fromOpaque(context).release()
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        return Token(source: source, box: box)
    }

    private final class Box {
        let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
    }

    private final class Token {
        let source: CFRunLoopSource
        let box: Box
        init(source: CFRunLoopSource, box: Box) {
            self.source = source
            self.box = box
        }
        deinit { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
    }
}

/// How often to sample, chosen from the power source. There is no setting.
///
/// This replaced `PerAppTrackingMode`, which asked the user to choose between
/// complete numbers and battery life. That was the wrong question twice over: the
/// cost it was rationing turned out to be a bug (`NettopStream.spawn()`), and
/// switching attribution *off* is not the only way to spend less — sampling less
/// often costs a fraction as much and, critically, **costs no accuracy at all**.
///
/// Nothing here can lose a byte:
///
/// - `nettop -d` reports a *delta per sample*, so a 3 s interval accounts for the
///   same traffic as a 1 s one, in thirds as many messages. Only the age of the
///   figures changes.
/// - The interface counters are lifetime totals read by difference, so their
///   sampling rate has no bearing on the total whatsoever — it only sets how
///   smooth the live rate looks.
///
/// Measured per configuration, with the stdin spin fixed:
///
/// | | `nettop` | interface sampler | flushes/s |
/// |---|---|---|---|
/// | `performance` | `-s 1` — 0.45% of a core | 0.5 s — 0.11% | ~2.5 |
/// | `balanced` | `-s 3` — 0.20% | 1.0 s — 0.05% | ~0.8 |
///
/// At these magnitudes wakeups matter more than the percentages, which is what
/// `balanced` mainly reduces.
public enum PowerProfile: String, CaseIterable {
    /// On wall power: the freshest possible numbers.
    case performance
    /// On battery: the same numbers, sampled less often.
    case balanced

    public static func forPowerSource(onACPower: Bool) -> PowerProfile {
        onACPower ? .performance : .balanced
    }

    /// How often to read the kernel interface counters, which drive the menu bar
    /// rate and the authoritative total.
    ///
    /// Relaxed further while the display sleeps: totals must keep accumulating, but
    /// nobody is reading a menu bar they cannot see.
    public func interfaceInterval(displayAsleep: Bool) -> TimeInterval {
        switch (self, displayAsleep) {
        case (.performance, false): return 0.5
        case (.performance, true):  return 2.0
        case (.balanced, false):    return 1.0
        case (.balanced, true):     return 3.0
        }
    }

    /// `nettop -s`, in whole seconds — its minimum and its only unit.
    ///
    /// Deliberately *not* varied with display sleep or popover visibility, unlike
    /// the interface interval. Changing it means restarting `nettop`, whose first
    /// sample is a cumulative baseline that has to be discarded, so every change
    /// drops a sample's worth of attribution. Power transitions happen a few times
    /// a day; screen sleeps and menu opens happen constantly.
    public var nettopSampleInterval: Int {
        switch self {
        case .performance: return 1
        case .balanced:    return 3
        }
    }

    /// How recently an app must have moved bytes to count as active.
    ///
    /// Twice the sample interval, so the dot cannot blink off between samples on an
    /// app that never stopped transferring.
    public var activityWindow: TimeInterval {
        TimeInterval(nettopSampleInterval) * 2
    }
}
