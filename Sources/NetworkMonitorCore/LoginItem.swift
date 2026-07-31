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
        case launchctlFailed(String)

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
            case .launchctlFailed(let detail):
                return "launchctl rejected the launch agent: \(detail)"
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

    /// Writes the launch agent and loads it into the current GUI session.
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

        // Replace any previous registration, then load. `bootout` failing is
        // expected and harmless when nothing was loaded.
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        // `bootstrap` honours RunAtLoad, which would start a second copy while
        // this one is running. The single-instance guard in main.swift makes that
        // duplicate exit immediately, so the agent still ends up correctly loaded.
        let result = launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        guard result.status == 0 else {
            throw Failure.launchctlFailed(result.output.isEmpty
                                          ? "exit \(result.status)" : result.output)
        }
    }

    /// Unloads and removes the launch agent.
    public static func disable() throws {
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        do {
            if FileManager.default.fileExists(atPath: plistURL.path) {
                try FileManager.default.removeItem(at: plistURL)
            }
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (task.terminationStatus,
                output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
