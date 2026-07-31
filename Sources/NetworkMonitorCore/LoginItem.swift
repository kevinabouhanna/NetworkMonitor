import Foundation

/// Starts the app at login using a per-user LaunchAgent.
///
/// Deliberately not `SMAppService`. That does work under an ad-hoc signature —
/// `register()` succeeds and reports `.enabled`, so no Developer ID is required —
/// but its state lives in the opaque Background Task Management database, where
/// the registration showed empty flags and `launchctl print` could not see it.
/// There is no way to verify it will actually launch at login short of logging
/// out.
///
/// A LaunchAgent is plain, inspectable and verifiable: the plist is a file you
/// can read, `launchctl print` confirms launchd loaded it, and `launchctl
/// kickstart` proves it can start the app. It needs no code signature at all.
public enum LoginItem {

    public enum Failure: LocalizedError {
        case notInstalledInApplications(String)
        case writeFailed(String)

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
            case .writeFailed(let detail):
                return "Could not write the launch agent: \(detail)"
            }
        }
    }

    /// launchd label; also the plist filename.
    public static var label: String {
        Bundle.main.bundleIdentifier ?? "com.kevinabouhanna.NetworkMonitor"
    }

    public static var plistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    /// True when the launch agent is installed and points at this build.
    public static var isEnabled: Bool {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String],
              let program = arguments.first
        else { return false }
        // A stale agent pointing at a deleted or moved copy is not "enabled".
        return FileManager.default.isExecutableFile(atPath: program)
    }

    /// The plist contents for a given executable path.
    ///
    /// `KeepAlive` is deliberately absent: with it, quitting from the menu would
    /// have launchd immediately relaunch the app, so Quit would not work.
    public static func agentDefinition(executablePath: String,
                                       label: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            // GUI sessions only — there is no menu bar to attach to otherwise.
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        ]
    }

    /// Writes the launch agent.
    ///
    /// Deliberately does **not** call `launchctl`. When the app has itself been
    /// started by this agent, `launchctl bootout` on that label terminates the
    /// caller — enabling the setting killed the app and unloaded the agent in one
    /// step. `launchctl bootstrap` is equally unnecessary: launchd loads every
    /// plist in `~/Library/LaunchAgents` at session start, and the app is already
    /// running, so the only thing that matters is that the file exists.
    ///
    /// `Scripts/install.sh` does bootstrap, because there the app is not running
    /// and should start immediately.
    public static func enable() throws {
        let executable = Bundle.main.executableURL?.path
            ?? CommandLine.arguments.first ?? ""

        // Running from .build during development would pin the agent to a path
        // that gets wiped by `swift package clean`.
        guard executable.contains(".app/Contents/MacOS/") else {
            throw Failure.notInstalledInApplications(
                Bundle.main.bundlePath.isEmpty ? executable : Bundle.main.bundlePath)
        }

        let directory = plistURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let definition = agentDefinition(executablePath: executable, label: label)
            let data = try PropertyListSerialization.data(fromPropertyList: definition,
                                                          format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }

    }

    /// Removes the launch agent.
    ///
    /// Also does not call `launchctl`, for the same reason: booting out the job
    /// would kill the very app the user is toggling the setting in. Deleting the
    /// plist is sufficient — launchd will not start it at the next login, and
    /// without `KeepAlive` the currently running copy is left alone.
    public static func disable() throws {
        do {
            if FileManager.default.fileExists(atPath: plistURL.path) {
                try FileManager.default.removeItem(at: plistURL)
            }
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
    }
}
