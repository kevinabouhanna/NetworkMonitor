import Foundation
import IOKit.ps

/// Whether the Mac is on wall power.
///
/// Needed because `nettop` costs a fixed ~1.36 cores *just by running* —
/// measured at 9.02 s wall / 12.26 s CPU, almost all system time, and unchanged
/// by `-s` (1 s, 5 s and 10 s intervals all cost the same) or by scoping to a
/// single process with `-p`. There is no flag that makes it cheap, so the only
/// lever is how long it runs. On battery that matters; plugged in it does not.
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

/// When per-app attribution (the expensive `nettop` stream) should run.
///
/// The live menu bar rate and the authoritative day total come from `sysctl`
/// interface counters, which cost essentially nothing and always run. Only the
/// per-app breakdown depends on this setting.
public enum PerAppTrackingMode: String, CaseIterable {
    /// Full-day per-app totals, at roughly 1.36 cores continuously.
    case always
    /// Full-day per-app totals while plugged in; on battery, only while the
    /// popover is open. The default.
    case pluggedIn
    /// Per-app data only while the popover is open. Lowest energy.
    case whenOpen

    /// Label for the right-click menu.
    public var title: String {
        switch self {
        case .always:    return "Always (highest CPU)"
        case .pluggedIn: return "While Plugged In (recommended)"
        case .whenOpen:  return "Only While Open (lowest CPU)"
        }
    }

    /// Longer label for the Settings window, where there is room to explain.
    public var settingsTitle: String {
        switch self {
        case .always:    return "Always — full daily totals, ~1.4 cores"
        case .pluggedIn: return "While plugged in — full totals on power"
        case .whenOpen:  return "Only while this menu is open — lowest CPU"
        }
    }

    /// Should `nettop` be running right now?
    public func shouldTrack(popoverOpen: Bool, onACPower: Bool) -> Bool {
        switch self {
        case .always:    return true
        case .pluggedIn: return onACPower || popoverOpen
        case .whenOpen:  return popoverOpen
        }
    }
}
