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

/// How often to sample, chosen from the power source and Low Power Mode. There is
/// no setting.
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
/// What is left to spend is mostly the menu bar readout: drawing it, and the
/// WindowServer round trip that shows it. So the readout is not drawn at all while
/// nobody can see it (`interfaceInterval(unattended:)`).
///
/// Measured for 1.7.0 with `-powerProfile`, two minutes each on an M1 MacBook
/// Air with its own everyday background traffic, as shares of one core:
///
/// | | `nettop` | interface sampler | app | `nettop` | together |
/// |---|---|---|---|---|---|
/// | `performance` | `-s 1` | 0.5 s | 1.58% | 1.10% | 2.68% |
/// | `balanced` | `-s 3` | 1 s | 0.83% | 0.36% | 1.19% |
/// | `saver` | `-s 10` | 2 s | 0.43% | 0.10% | 0.53% |
/// | `balanced`, nobody watching | `-s 3` | 10 s | 0.17% | 0.30% | 0.47% |
public enum PowerProfile: String, CaseIterable {
    /// On wall power: the freshest possible numbers.
    case performance
    /// On battery: the same numbers, sampled less often.
    case balanced
    /// In Low Power Mode, plugged in or not. Whoever turned it on has asked the
    /// Mac to save energy, so the figures refresh every few seconds instead; the
    /// totals are the same.
    case saver

    /// The launch argument that forces a profile, for measuring one without
    /// unplugging: `open NetworkMonitor.app --args -powerProfile saver`.
    public static let argumentKey = "powerProfile"

    public static func forPowerSource(onACPower: Bool, lowPowerMode: Bool = false) -> PowerProfile {
        if lowPowerMode { return .saver }
        return onACPower ? .performance : .balanced
    }

    /// The profile in force: the one a `-powerProfile` launch argument names, or
    /// else the one the power source and Low Power Mode call for.
    ///
    /// Only the launch arguments are read, never the stored defaults, so no
    /// override can outlive the run that asked for it.
    public static func current(
        arguments: [String: Any] = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    ) -> PowerProfile {
        if let name = arguments[argumentKey] as? String, let forced = PowerProfile(rawValue: name) {
            return forced
        }
        return forPowerSource(onACPower: PowerSource.isOnACPower,
                              lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// How often to read the kernel interface counters, which drive the menu bar
    /// rate and the authoritative total.
    ///
    /// `unattended` means nobody can see the menu bar: the display is asleep, the
    /// screen is locked, or another user's session is in front. The readout is not
    /// drawn then, so the counters are only read to keep the totals and History
    /// moving, and every few seconds does that exactly as well as every second.
    public func interfaceInterval(unattended: Bool) -> TimeInterval {
        switch (self, unattended) {
        case (.performance, false): return 0.5
        case (.balanced, false):    return 1.0
        case (.saver, false):       return 2.0
        case (.performance, true):  return 5.0
        case (.balanced, true):     return 10.0
        case (.saver, true):        return 15.0
        }
    }

    /// `nettop -s`, in whole seconds — its minimum and its only unit.
    ///
    /// Deliberately *not* varied while unattended or with popover visibility,
    /// unlike the interface interval. Changing it means restarting `nettop`, whose
    /// first sample is a cumulative baseline that has to be discarded, so every
    /// change drops a sample's worth of attribution. Power transitions and Low Power
    /// Mode change a few times a day; screens sleep and menus open constantly.
    public var nettopSampleInterval: Int {
        switch self {
        case .performance: return 1
        case .balanced:    return 3
        case .saver:       return 10
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
