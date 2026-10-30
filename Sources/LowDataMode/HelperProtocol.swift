import Foundation

/// The version of the conversation between the app and its root helper.
///
/// The helper reports it from `status`; the app compares it with its own and,
/// when the installed helper is older, replaces it with the one bundled inside
/// the app — one administrator prompt, on the first launch of a new version
/// that needs it. Bump it whenever the helper gains a verb, changes what one
/// does, or its sudoers rule changes. Builds that change nothing the helper does
/// leave it alone, and so never ask for a password.
///
/// Here, in the target both sides link, so the two cannot disagree.
///
/// - 1: `status`, `suppress`, `restore`, `self-heal`, `uninstall`. Reported no
///   version at all, which the app reads as 1.
/// - 2: adds `constrain` and `unconstrain` for Low Data Mode.
/// - 3: `suppress` also blocks Google's update check, `update.googleapis.com`,
///   which GoogleUpdater uses for Chrome (#92).
/// - 4: `suppress` also turns off Claude Code's auto-updater through a managed
///   settings file of its own (#97).
/// - 5: `serve`, as a launch daemon answering over XPC (#131).
public enum HelperProtocol {
    public static let version = 5
}

/// The helper as a launch daemon the app registers itself (#131): what both
/// sides call it, and how each checks the other. With a Developer ID there is
/// a team to check callers by, so XPC replaces `sudo` and its sudoers rule,
/// and allowing it is a switch in System Settings rather than a password.
public enum HelperDaemon {
    /// The daemon's launchd label and Mach service, and its plist inside the
    /// app, in `Contents/Library/LaunchDaemons`.
    public static let label = "com.kevinabouhanna.NetworkMonitor.daemon"
    public static let machServiceName = label
    public static let plistName = "\(label).plist"

    /// Only NetworkMonitor, signed by its team, may ask anything of it.
    public static let clientRequirement = """
        anchor apple generic and identifier "com.kevinabouhanna.NetworkMonitor" \
        and certificate leaf[subject.OU] = "GRQKG7M8CL"
        """
    /// And the app only talks to the helper it shipped.
    public static let helperRequirement = """
        anchor apple generic and identifier "com.kevinabouhanna.NetworkMonitor.helper" \
        and certificate leaf[subject.OU] = "GRQKG7M8CL"
        """

    /// What may be asked over XPC: the verbs the sudoers rule granted, and
    /// `uninstall`, which the app's own Uninstall used to run with a password.
    /// `self-heal` stays the hourly job's.
    public static let verbs: Set<String> = ["status", "suppress", "restore", "constrain", "unconstrain",
                                            "uninstall"]
}

/// What the daemon offers: one verb at a time, with no arguments, answered
/// with its exit status and what it printed.
@objc public protocol HelperXPCInterface {
    func run(_ verb: String, reply: @escaping (Int32, String) -> Void)
}
