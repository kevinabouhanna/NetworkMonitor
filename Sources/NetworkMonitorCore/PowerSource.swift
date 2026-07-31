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
    /// Only while the popover is open. Lowest energy, least complete.
    ///
    /// The tradeoff is real: per-app totals then cover only the seconds the menu
    /// was open, so they are a lower bound on the day rather than a full account.
    case whenOpen
    /// Also while the menu is closed, whenever the Mac is on power. **The default.**
    ///
    /// Complete per-app figures are the point of the feature, so this ships on and
    /// users who care more about battery turn it off. An "always" option was
    /// dropped: it ran `nettop` at ~1.36 cores on battery, which is never a
    /// reasonable default for a menu bar utility.
    case pluggedIn

    /// Label for menus.
    public var title: String {
        switch self {
        case .whenOpen:  return "Only While This Menu Is Open"
        case .pluggedIn: return "Also While Plugged In"
        }
    }

    /// Should `nettop` be running right now?
    public func shouldTrack(popoverOpen: Bool, onACPower: Bool) -> Bool {
        switch self {
        case .whenOpen:  return popoverOpen
        case .pluggedIn: return onACPower || popoverOpen
        }
    }
}
