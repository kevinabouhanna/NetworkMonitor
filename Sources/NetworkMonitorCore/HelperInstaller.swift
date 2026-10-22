import AppKit
import Foundation
import LowDataMode

/// Installs, updates and removes the privileged helper from inside the app.
///
/// The helper used to be installed from Terminal with `make helper`. An app is
/// not a source checkout, and nobody should need Terminal to use one, so the
/// app now carries the helper and its installer in its own bundle and runs the
/// installer through macOS's administrator dialog: the standard "NetworkMonitor
/// wants to make changes" sheet, password or Touch ID, once.
///
/// It goes through `do shell script … with administrator privileges` because
/// that needs no Developer ID. The textbook route, `SMAppService.daemon`, needs a
/// team identifier to say which apps may talk to the daemon, and an ad-hoc
/// signature has none — the same reason the helper is reached through a sudoers
/// rule rather than XPC (see the helper's own header). What runs as root is
/// `helper-setup.sh`, the same installer `Scripts/install-helper.sh` uses, from
/// the bundle the user just authorised.
public enum HelperInstaller {

    public enum State: Equatable {
        /// Installed, and new enough for everything this app asks of it.
        case current
        case missing
        /// Installed by an older app. Works for what it knew, but not for what
        /// was added since — Low Data Mode, for a helper from before it.
        case outdated
    }

    public enum Outcome: Equatable {
        case done
        /// The user closed the password dialog. Not an error, and not repeated
        /// without them asking: Settings offers it again.
        case cancelled
        case failed(String)
    }

    /// Where the app has to live for the helper to work: the self-heal job uses
    /// this path to tell "the app is gone" from "the app is here", and would
    /// uninstall the helper within the hour for a copy run from anywhere else —
    /// from the disk image, or from Downloads.
    public static let requiredLocation = "/Applications/NetworkMonitor.app"

    static let helperName = "com.kevinabouhanna.NetworkMonitor.helper"

    static var bundledHelper: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchServices/\(helperName)")
    }

    static var setupScript: URL? {
        Bundle.main.url(forResource: "helper-setup", withExtension: "sh")
    }

    public static var isInRequiredLocation: Bool {
        Bundle.main.bundleURL.standardizedFileURL.path == requiredLocation
    }

    /// Whether this copy can install the helper: it carries one, and it is
    /// installed where the helper expects to find it.
    public static var canInstall: Bool {
        isInRequiredLocation
            && FileManager.default.isExecutableFile(atPath: bundledHelper.path)
            && setupScript != nil
    }

    /// Asks the installed helper its version. One `sudo -n status`; call it when
    /// something is about to be decided, not from a view's body.
    public static func state() -> State {
        guard PrivilegedSuppressor.isInstalled else { return .missing }
        guard let output = PrivilegedSuppressor.invoke("status"),
              let data = output.data(using: .utf8),
              let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Installed but not answering — a sudoers rule from another user, or
            // a half-removed install. Reinstalling is the fix either way.
            return .outdated
        }
        // A helper from before versions were reported is version 1.
        let version = (status["version"] as? Int) ?? 1
        return version >= HelperProtocol.version ? .current : .outdated
    }

    // MARK: Install and remove

    /// Installs or updates the helper. Shows the administrator dialog; blocks
    /// until it is answered, so call it on the main thread from a user action or
    /// a moment chosen for it, never from layout.
    public static func install() -> Outcome {
        guard canInstall, let script = setupScript else {
            return .failed(isInRequiredLocation
                ? "This copy of NetworkMonitor is missing its helper. Download it again."
                : "Move NetworkMonitor to your Applications folder first.")
        }
        return runAsAdministrator(
            ["/bin/bash", script.path, "install", bundledHelper.path, NSUserName()],
            prompt: "NetworkMonitor needs your permission once to pause macOS updates "
                + "and turn on Low Data Mode while you're on a hotspot.")
    }

    /// Restores everything the helper changed and removes it. Used by the app's
    /// own Uninstall, which is the clean way out for anyone who never opens
    /// Terminal.
    public static func uninstall() -> Outcome {
        guard PrivilegedSuppressor.isInstalled
                || FileManager.default.fileExists(atPath: PrivilegedSuppressor.helperPath)
        else { return .done }
        guard let script = setupScript else {
            return .failed("This copy of NetworkMonitor is missing its uninstaller.")
        }
        return runAsAdministrator(
            ["/bin/bash", script.path, "uninstall"],
            prompt: "NetworkMonitor needs your permission to put back the system "
                + "settings it changed and remove its helper.")
    }

    // MARK: Running as root

    static func runAsAdministrator(_ arguments: [String], prompt: String) -> Outcome {
        guard let script = NSAppleScript(source: appleScript(running: arguments,
                                                             prompt: prompt))
        else { return .failed("Couldn't prepare the administrator request.") }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return .done }
        // -128 is AppleScript's "User canceled."
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }
        return .failed((error[NSAppleScript.errorMessage] as? String)
                       ?? "The helper could not be installed.")
    }

    /// The AppleScript for one root command. Public so the quoting — the only
    /// part of this that can be got subtly wrong — is tested.
    ///
    /// Two layers: each argument single-quoted for `/bin/sh`, then the whole
    /// command made an AppleScript string literal. Paths come from the bundle
    /// and could contain either kind of quote if someone renamed a folder.
    public static func appleScript(running arguments: [String], prompt: String) -> String {
        let command = arguments.map(shellQuoted).joined(separator: " ")
        return "do shell script \(appleScriptLiteral(command)) "
            + "with prompt \(appleScriptLiteral(prompt)) with administrator privileges"
    }

    static func shellQuoted(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptLiteral(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
