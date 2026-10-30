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
        let connection = NSXPCConnection(machServiceName: HelperDaemon.machServiceName, options: .privileged)
        connection.setCodeSigningRequirement(HelperDaemon.helperRequirement)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperXPCInterface.self)
        connection.resume()
        defer { connection.invalidate() }

        let answered = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var output: String?
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in answered.signal() } as? HelperXPCInterface
        proxy?.run(verb) { status, text in
            lock.lock()
            if status == 0 { output = text }
            lock.unlock()
            answered.signal()
        }
        guard proxy != nil, answered.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return output
    }
}
