import Foundation
import LowDataMode
import ServiceManagement

/// The app's side of the helper as a launch daemon (#131): registering it with
/// `SMAppService`, which puts it under NetworkMonitor in System Settings ›
/// General › Login Items & Extensions to be allowed, and asking it one verb at
/// a time over XPC.
///
/// Only in Developer ID builds, in Applications: the daemon checks its callers
/// by team, and the build carries its plist. Others keep `helper-setup.sh` and
/// `sudo`, which `PrivilegedSuppressor` falls back to.
public enum HelperService {

    public enum Status: Equatable {
        /// Not this build: no Developer ID, or not in Applications.
        case unavailable
        case notRegistered
        /// Registered, and waiting to be allowed in System Settings.
        case waitingForApproval
        case enabled
    }

    private static var service: SMAppService { .daemon(plistName: HelperDaemon.plistName) }

    public static var isAvailable: Bool {
        HelperInstaller.isInRequiredLocation
            && FileManager.default.fileExists(atPath: Bundle.main.bundlePath
                + "/Contents/Library/LaunchDaemons/\(HelperDaemon.plistName)")
    }

    private static let lock = NSLock()
    private static var cached: (status: Status, at: Date)?

    /// Asked of macOS at most every few seconds: it's checked before every
    /// verb, and asking is a round trip.
    public static var status: Status {
        guard isAvailable else { return .unavailable }
        lock.lock()
        if let cached, Date().timeIntervalSince(cached.at) < 3 {
            lock.unlock()
            return cached.status
        }
        lock.unlock()
        let status: Status
        switch service.status {
        case .enabled:          status = .enabled
        case .requiresApproval: status = .waitingForApproval
        default:                status = .notRegistered
        }
        lock.lock()
        cached = (status, Date())
        lock.unlock()
        return status
    }

    private static func forget() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    /// Registers the daemon. macOS lists it under NetworkMonitor in Login
    /// Items, switched off until the person switches it on. No password.
    public static func register() -> HelperInstaller.Outcome {
        forget()
        do {
            try service.register()
        } catch {
            // Registered but not yet allowed reports an error too.
            forget()
            switch status {
            case .enabled:            return .done
            case .waitingForApproval: return .waitingForApproval
            default:                  return .failed(error.localizedDescription)
            }
        }
        forget()
        return status == .enabled ? .done : .waitingForApproval
    }

    public static func unregister() {
        forget()
        try? service.unregister()
    }

    /// Login Items & Extensions, where it's switched on.
    public static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// One verb, answered over XPC, or nil: not allowed yet, refused, or no
    /// answer in time. Synchronous, as `sudo` was, with a limit, so a wedged
    /// daemon can't freeze the menu bar.
    public static func invoke(_ verb: String, timeout: TimeInterval = 20) -> String? {
        guard let reply = call(verb, timeout: timeout), reply.status == 0 else { return nil }
        return reply.text
    }

    /// One verb's exit status and what it printed, or nil when nothing
    /// answered: not allowed yet, refused, or not started in time.
    static func call(_ verb: String, timeout: TimeInterval) -> (status: Int32, text: String)? {
        let connection = NSXPCConnection(machServiceName: HelperDaemon.machServiceName, options: .privileged)
        connection.setCodeSigningRequirement(HelperDaemon.helperRequirement)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperXPCInterface.self)
        connection.resume()
        defer { connection.invalidate() }

        let answered = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var reply: (status: Int32, text: String)?
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in answered.signal() } as? HelperXPCInterface
        proxy?.run(verb) { status, text in
            lock.lock()
            reply = (status, text)
            lock.unlock()
            answered.signal()
        }
        guard proxy != nil, answered.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return reply
    }

    // MARK: Switched on, but not starting

    /// Whether launchd starts the daemon when asked: any answer counts, even a
    /// verb that failed. Started on demand, it answers in well under a second;
    /// launchd retries a failed start every 10 seconds, so 5 is a clear no.
    public static func answers(timeout: TimeInterval = 5) -> Bool {
        call("status", timeout: timeout) != nil
    }

    public enum Repair: Equatable {
        /// Not switched on, or it answers: nothing to do.
        case notNeeded
        case repaired
        /// Registered again, and macOS wants it allowed again.
        case waitingForApproval
        case failed
    }

    /// Registers the daemon again when macOS says it's on but launchd can't
    /// start it (#238).
    ///
    /// The registration names the app that made it, and launchd finds the
    /// program through it. Replace the app with a copy that has no daemon, and
    /// then with one that has, and macOS keeps reporting it enabled while
    /// launchd fails every start with "Invalid or missing Program". The app
    /// trusted "enabled", so it never registered again, and the daemon's first
    /// start, which removes the `sudo` helper and lists its self-heal job under
    /// NetworkMonitor, never came.
    ///
    /// Registering from this copy hands launchd a program it can find: first as
    /// it is, which keeps the approval, and only then unregistered and
    /// registered, which may ask for it again. Blocks for seconds while it
    /// waits for answers, so call it off the main thread.
    public static func repairIfNotStarting() -> Repair {
        repair(status: { status },
               answers: { answers() },
               registerAgain: { forget(); try? service.register(); forget() },
               unregister: unregister,
               register: register)
    }

    /// The steps, in order, with each one handed in, so the order is tested.
    public static func repair(status: () -> Status,
                              answers: () -> Bool,
                              registerAgain: () -> Void,
                              unregister: () -> Void,
                              register: () -> HelperInstaller.Outcome) -> Repair {
        guard status() == .enabled, !answers() else { return .notNeeded }
        registerAgain()
        if status() == .enabled, answers() { return .repaired }
        unregister()
        switch register() {
        case .done:               return answers() ? .repaired : .failed
        case .waitingForApproval: return .waitingForApproval
        case .cancelled, .failed: return .failed
        }
    }
}
