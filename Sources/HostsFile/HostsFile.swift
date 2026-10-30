import Foundation

/// Pure text manipulation of `/etc/hosts`, in its own target so it can be
/// tested.
///
/// It lives here rather than inside the helper because the helper runs as root
/// and must not link a menu bar app's frameworks, and rather than inside
/// `NetworkMonitorCore` because that imports AppKit — pulling GUI frameworks
/// into a root process to reuse fifteen lines of string handling is a bad
/// trade. A bug in these fifteen lines corrupts name resolution for the entire
/// machine, so they are worth a target of their own and a test each.
public enum HostsFile {

    /// Update endpoints blocked at the name-resolution level, by the helper's
    /// `/etc/hosts` block and, on a hotspot, by the content filter (#98).
    ///
    /// The last resort, used only where an app has no policy at all. Every entry
    /// must carry update traffic **and nothing else** — an unchecked entry here is
    /// how a metering feature breaks the apps it promised to leave working.
    ///
    /// **Three candidates were removed after checking what else uses them, and that
    /// check is the only reason this feature does not break things:**
    ///
    /// - `update.code.visualstudio.com` is literally `updateUrl` in VS Code's
    ///   product.json, and is also where the Remote-SSH extension downloads the VS
    ///   Code server (`/commit:<hash>/server-darwin-arm64/stable`). Blocking it
    ///   breaks remote development. VS Code is covered by its own `update.mode`
    ///   setting instead, which needs no privileges.
    /// - `api.anthropic.com` is Claude Desktop's update feed *and* the API it uses
    ///   for everything else — its feed URL is
    ///   `api.anthropic.com/api/desktop/darwin/universal/squirrel/update`. Blocking
    ///   it takes the app off the air. Claude is covered by managed preferences.
    /// - `downloads.claude.ai` carries the update payload but also Claude Code and
    ///   claude-ssh downloads. With the helper's managed policy stopping the
    ///   check, blocking the payload host buys nothing and risks breaking a
    ///   feature.
    public static let updateHosts = [
        // Canva — `app-update.yml` names this as the electron-updater feed. Canva
        // exposes no policy and no user setting of any kind, so this is the only
        // lever it has. Verified update-only: normal use is canva.com.
        "desktop-release.canva.com",
        // Figma — its `DisableUpdater` preference is the primary lever, but that
        // write is deferred while Figma is running, and Figma is running most of
        // the time for the people who have it installed. This closes that window.
        // Verified update-only: interactive traffic is figma.com.
        "desktop.figma.com",
        // Google: the update check for GoogleUpdater, which has replaced Keystone
        // and updates Chrome. It reads neither Keystone's `checkInterval` nor, on a
        // Mac that isn't enrolled in MDM, its own `updatePolicies`
        // (`ManagedPreferencePolicyManager::HasActiveDevicePolicies`), so a host is
        // the only lever left (#92). Verified update-only: it is the update
        // protocol's endpoint, and Chrome's component updater is its only other
        // caller. The payloads come from shared download hosts
        // (`edgedl.me.gvt1.com`, `dl.google.com`), which stay open: with the check
        // blocked, nothing asks for one.
        "update.googleapis.com",
    ]

    /// The marker text says what it is and how to remove it, because the person
    /// most likely to read it is someone who deleted the app and is wondering
    /// why a hostname will not resolve.
    public static let beginMarker =
        "# BEGIN NetworkMonitor hotspot metering — remove this block to undo"
    public static let endMarker = "# END NetworkMonitor hotspot metering"

    /// The managed block for a set of hostnames.
    ///
    /// Both `0.0.0.0` and `::1` are emitted: a name with only an A record
    /// blocked can still resolve over IPv6 and connect anyway.
    public static func block(for hosts: [String]) -> String {
        var lines = [beginMarker]
        for host in hosts {
            lines.append("0.0.0.0\t\(host)")
            lines.append("::1\t\(host)")
        }
        lines.append(endMarker)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Everything except the managed block, leaving the user's own entries and
    /// their formatting untouched.
    public static func withoutBlock(_ contents: String) -> String {
        guard let begin = contents.range(of: beginMarker) else { return contents }

        guard let end = contents.range(of: endMarker,
                                       range: begin.upperBound..<contents.endIndex) else {
            // A begin marker with no end marker. Truncating from the marker is
            // the only safe reading: guessing where the block ended could leave
            // live `0.0.0.0` entries behind, which is the failure that silently
            // breaks a hostname forever.
            return String(contents[contents.startIndex..<begin.lowerBound])
        }

        var remainder = String(contents[contents.startIndex..<begin.lowerBound])
        var tail = String(contents[end.upperBound...])
        // The block was inserted with a trailing newline; take it back out so
        // repeated apply/remove cycles do not accumulate blank lines.
        if tail.hasPrefix("\n") { tail.removeFirst() }
        remainder += tail
        return remainder
    }

    /// Applies the block, replacing any block already present so that repeated
    /// application is idempotent.
    public static func applying(_ hosts: [String], to contents: String) -> String {
        let base = withoutBlock(contents)
        let separator = base.isEmpty || base.hasSuffix("\n") ? "" : "\n"
        return base + separator + block(for: hosts)
    }

    public static func containsBlock(_ contents: String) -> Bool {
        contents.contains(beginMarker)
    }
}
