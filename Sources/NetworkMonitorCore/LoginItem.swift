import Foundation
import ServiceManagement

/// Starts the app at login, via `SMAppService` — the API macOS 13+ expects an
/// app to use to register itself.
///
/// This replaced a hand-written LaunchAgent plist in `~/Library/LaunchAgents`.
/// That worked and needed no code signature, but macOS files it as a *legacy
/// agent*, and Login Items identifies such an item by the program launchd runs
/// — the bare Mach-O inside the bundle, which LaunchServices draws with the
/// generic "exec" icon rather than the app's own.
///
/// launchd does have a key for that, `AssociatedBundleIdentifiers`, but macOS
/// only honours it when the agent and the app can be shown to come from the
/// same developer: measured against this machine's Background Task Management
/// database, every item carrying an association had a Team Identifier and none
/// without one did. An ad-hoc signature has no team, so it was dropped
/// silently.
///
/// `SMAppService.mainApp` registers the *bundle*, so the Login Items row points
/// at `NetworkMonitor.app` and shows its name and icon with no signature at
/// all — and it is the same call a Developer ID-signed build would make, so
/// signing later changes nothing here.
///
/// The trade-off, honestly: the registration lives in the opaque Background
/// Task Management database instead of a plist you can read, and `launchctl
/// print` cannot see it. `status` reports it, and `sfltool dumpbtm` shows it
/// enabled and allowed.
public enum LoginItem {

    public enum Failure: LocalizedError {
        case notInstalledInApplications(String)
        case requiresApproval
        case registrationFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notInstalledInApplications(let path):
                return """
                    Launch at Login needs the app to live in a fixed location, but \
                    it is running from:

                    \(path)

                    Move NetworkMonitor.app to /Applications (or run \
                    'make install') and try again.
                    """
            case .requiresApproval:
                return """
                    macOS is holding this login item for approval. Open System \
                    Settings > General > Login Items and switch NetworkMonitor \
                    on there.
                    """
            case .registrationFailed(let detail):
                return "Could not change the login item: \(detail)"
            }
        }
    }

    /// Also the launchd label of the agent used before the move to
    /// `SMAppService`, and so the filename left behind on older installs.
    public static var label: String {
        Bundle.main.bundleIdentifier ?? "com.kevinabouhanna.NetworkMonitor"
    }

    // MARK: State

    /// Whether `status` means the app will be started at the next login.
    ///
    /// Split out from `isEnabled` so the mapping is testable without touching
    /// the real registration. `.requiresApproval` is deliberately *not*
    /// enabled: macOS knows about the item but the user has switched it off in
    /// System Settings, and only they can switch it back.
    public static func isEnabled(for status: SMAppService.Status) -> Bool {
        status == .enabled
    }

    public static var isEnabled: Bool {
        isEnabled(for: SMAppService.mainApp.status)
    }

    // MARK: Enable / disable

    public static func enable() throws {
        try requireBundledBuild()
        // Leaving the old agent in place would start a second copy at login.
        // The running instance is left alone: the plist is deleted rather than
        // booted out, because booting out the job would kill the very app the
        // user is toggling this in.
        try? removeLegacyAgent()

        guard !isEnabled else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            if SMAppService.mainApp.status == .requiresApproval {
                throw Failure.requiresApproval
            }
            throw Failure.registrationFailed(error.localizedDescription)
        }
    }

    public static func disable() throws {
        try? removeLegacyAgent()
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            throw Failure.registrationFailed(error.localizedDescription)
        }
    }

    /// Running from `.build` during development would register a path that
    /// `swift package clean` deletes.
    private static func requireBundledBuild() throws {
        let executable = Bundle.main.executableURL?.path
            ?? CommandLine.arguments.first ?? ""
        guard executable.contains(".app/Contents/MacOS/") else {
            throw Failure.notInstalledInApplications(
                Bundle.main.bundlePath.isEmpty ? executable : Bundle.main.bundlePath)
        }
    }

    // MARK: Migration off the old LaunchAgent

    public static var legacyAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    public static func hasLegacyAgent(at url: URL? = nil) -> Bool {
        FileManager.default.fileExists(atPath: (url ?? legacyAgentURL).path)
    }

    @discardableResult
    public static func removeLegacyAgent(at url: URL? = nil) throws -> Bool {
        let target = url ?? legacyAgentURL
        guard FileManager.default.fileExists(atPath: target.path) else { return false }
        try FileManager.default.removeItem(at: target)
        return true
    }

    /// Best-effort teardown for the uninstaller, which is about to delete the
    /// bundle: nothing here is worth failing an uninstall over.
    public static func withdraw() {
        try? removeLegacyAgent()
        try? SMAppService.mainApp.unregister()
    }

    /// Moves an install that predates `SMAppService` across, preserving what
    /// the user had chosen: the old agent existing *is* the record that they
    /// wanted launch-at-login, so it becomes a registration rather than being
    /// dropped.
    ///
    /// Safe to call on every launch — it does nothing once there is no plist.
    public static func migrateLegacyAgentIfNeeded() {
        guard hasLegacyAgent() else { return }
        try? removeLegacyAgent()
        try? enable()
    }
}
