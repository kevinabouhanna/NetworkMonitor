import Foundation
import LowDataMode

/// The helper as a launch daemon the app registers with `SMAppService` (#131),
/// started by launchd as `serve` when the app first asks.
///
/// It answers the same fixed verbs as before, now over XPC and only to
/// NetworkMonitor signed by its team, which `sudo` and its sudoers rule could
/// never check. Each request runs this same binary with that one verb, so a
/// verb behaves exactly as it always has, with its lock and its exit status.
///
/// It quits when idle, and launchd starts it again on the next request, so
/// the binary inside an updated app is the one that answers.
final class Daemon: NSObject, NSXPCListenerDelegate, HelperXPCInterface {

    static let shared = Daemon()
    static let idleTimeout: TimeInterval = 120

    private let queue = DispatchQueue(label: HelperDaemon.label)
    private var idleExit: DispatchWorkItem?

    static func serve() -> Never {
        shared.migrate()
        let listener = NSXPCListener(machServiceName: HelperDaemon.machServiceName)
        listener.delegate = shared
        listener.resume()
        shared.queue.async { shared.scheduleIdleExit() }
        dispatchMain()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(HelperDaemon.clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: HelperXPCInterface.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func run(_ verb: String, reply: @escaping (Int32, String) -> Void) {
        guard HelperDaemon.verbs.contains(verb) else {
            reply(64, "unknown verb")
            return
        }
        queue.async {
            self.idleExit?.cancel()
            let (status, output) = Self.runVerb(verb)
            reply(status, output)
            self.scheduleIdleExit()
        }
    }

    /// On `queue`.
    private func scheduleIdleExit() {
        let work = DispatchWorkItem { exit(0) }
        idleExit = work
        queue.asyncAfter(deadline: .now() + Self.idleTimeout, execute: work)
    }

    /// This binary, with the one verb, as `sudo` used to run it.
    static func runVerb(_ verb: String) -> (Int32, String) {
        guard let executable = Bundle.main.executableURL else { return (70, "no executable") }
        let task = Process()
        task.executableURL = executable
        task.arguments = [verb]
        let output = Pipe(), errors = Pipe()
        task.standardOutput = output
        task.standardError = errors
        do { try task.run() } catch { return (70, error.localizedDescription) }
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        let complaint = errors.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let text = String(data: task.terminationStatus == 0 ? printed : complaint, encoding: .utf8) ?? ""
        return (task.terminationStatus, text)
    }

    // MARK: Moving over from the sudo helper

    /// Once allowed, the daemon is what the app reaches, so the sudoers rule
    /// goes: it granted what XPC now does, checked by team. And the hourly
    /// self-heal job is put in place, or brought up to date, without a
    /// password: the daemon is root already.
    func migrate() {
        try? FileManager.default.removeItem(atPath: sudoersPath)
        installSelfHeal()
    }

    /// Dragging the app to the Trash is the uninstall most people use, and it
    /// takes this daemon with it: its program is inside the app, and macOS
    /// doesn't unregister it. So a copy of this binary stays outside the app,
    /// run hourly by a job of its own, to put everything back once the app is
    /// gone, as it always has (#28). Listed under NetworkMonitor in Login
    /// Items, by `AssociatedBundleIdentifiers`.
    func installSelfHeal() {
        let manager = FileManager.default
        guard let executable = Bundle.main.executablePath else { return }
        if !manager.contentsEqual(atPath: executable, andPath: helperPath) {
            try? manager.createDirectory(atPath: "/Library/PrivilegedHelperTools", withIntermediateDirectories: true)
            let staged = helperPath + ".new"
            try? manager.removeItem(atPath: staged)
            guard (try? manager.copyItem(atPath: executable, toPath: staged)) != nil else { return }
            try? manager.setAttributes([.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0],
                                       ofItemAtPath: staged)
            guard rename(staged, helperPath) == 0 else { return }
        }
        let plist: [String: Any] = [
            "Label": daemonLabel,
            "ProgramArguments": [helperPath, "self-heal"],
            "RunAtLoad": true,
            "StartInterval": 3600,
            "AssociatedBundleIdentifiers": ["com.kevinabouhanna.NetworkMonitor"],
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        else { return }
        if manager.contents(atPath: daemonPlistPath) == data { return }
        manager.createFile(atPath: daemonPlistPath, contents: data,
                           attributes: [.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0])
        NetworkMonitorHelper.run("/bin/launchctl", ["bootout", "system/\(daemonLabel)"])
        NetworkMonitorHelper.run("/bin/launchctl", ["bootstrap", "system", daemonPlistPath])
    }
}
