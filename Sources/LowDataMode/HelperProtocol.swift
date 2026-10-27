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
public enum HelperProtocol {
    public static let version = 3
}
