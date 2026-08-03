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
