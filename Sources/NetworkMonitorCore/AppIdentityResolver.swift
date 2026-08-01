import AppKit
import Foundation
import UniformTypeIdentifiers

/// The app a process was launched by, when the process itself is not bundled.
///
/// Carries enough to draw the parent's row even when the parent moved no bytes
/// of its own — a terminal whose only network activity is the dev server it
/// started has no row otherwise.
public struct ParentApp: Hashable, Codable {
    /// Matches the `AppIdentity.key` the parent would resolve to on its own, so
    /// a child groups under the parent's existing row rather than beside it.
    public let key: String
    public let displayName: String
    public let bundlePath: String

    public init(key: String, displayName: String, bundlePath: String) {
        self.key = key
        self.displayName = displayName
        self.bundlePath = bundlePath
    }
}

/// A network-using app, after helper processes have been folded into their parent.
public struct AppIdentity: Hashable {
    /// Stable key for accumulation and persistence: the bundle path for real
    /// apps, the executable path for daemons.
    public let key: String
    public let displayName: String
    public let bundlePath: String?
    /// True when no `.app` bundle owns the process **and** none launched it — an
    /// OS daemon. These are grouped under a single collapsed "System" row.
    public let isSystem: Bool
    /// Set when an un-bundled process was adopted by an ancestor app. The row is
    /// nested under that app instead of being filed as a system daemon.
    public let parent: ParentApp?

    public init(key: String, displayName: String, bundlePath: String?, isSystem: Bool,
                parent: ParentApp? = nil) {
        self.key = key
        self.displayName = displayName
        self.bundlePath = bundlePath
        self.isSystem = isSystem
        self.parent = parent
    }
}

/// Maps a pid to the app a user would recognise.
///
/// `nettop` truncates process names to the kernel's 15-character `p_comm` limit
/// ("Google Chrome H"), and a single app spans many processes — Chrome alone
/// runs a dozen helpers with the same truncated name and different pids. So the
/// pid is resolved through `proc_pidpath` to a real executable path and then up
/// to the outermost enclosing `.app`.
///
/// `proc_pidpath` was verified to work on root-owned processes from an
/// unprivileged process (`apsd`, `mDNSResponder`, `launchd` all resolved), so no
/// elevated privileges are required.
///
/// A process with no `.app` anywhere in its own path is not necessarily a daemon.
/// The VS Code Claude extension runs as a bare executable under
/// `~/.vscode/extensions/anthropic.claude-code-…/resources/native-binary/claude`,
/// which by path alone is indistinguishable from `mDNSResponder` — so it used to
/// be buried in the collapsed System group. Its parent chain says otherwise:
///
///     3969  …/anthropic.claude-code-…/native-binary/claude
///     1811  /Applications/Visual Studio Code.app/…/Code Helper (Plugin)
///     1418  /Applications/Visual Studio Code.app/Contents/MacOS/Code
///
/// so when the path yields no bundle, the ppid chain is walked for one. See
/// `adoptiveParent(ancestorPaths:)` for why the process's own path is always
/// consulted first.
public final class AppIdentityResolver {

    private var pathByPID: [Int32: String] = [:]
    /// Per-pid results. Required, not just an optimisation: an adopted identity
    /// depends on the parent, and the same `node` binary can be launched by two
    /// different apps, so path alone is not a sufficient cache key for it.
    private var identityByPID: [Int32: AppIdentity] = [:]
    /// Parent-independent results only — bundled apps and true daemons. Shared
    /// across pids, and survives pid eviction.
    private var identityByPath: [String: AppIdentity] = [:]
    private var iconByKey: [String: NSImage] = [:]

    /// How far up the process tree to look for an owning app.
    ///
    /// Deep enough for the observed shapes (a VS Code extension host sits two
    /// levels below the app; a shell inside a terminal tab, three or four), and
    /// bounded so a pathological chain cannot stall a sample.
    static let maxAncestorDepth = 8

    public init() {}

    public func identity(pid: Int32, fallbackName: String) -> AppIdentity {
        if let cached = identityByPID[pid] { return cached }

        guard let path = Self.executablePath(pid: pid) else {
            // kernel_task (pid 0) and processes that exit between the nettop
            // sample and this lookup land here.
            return AppIdentity(key: "system:\(fallbackName)",
                               displayName: fallbackName,
                               bundlePath: nil,
                               isSystem: true)
        }

        pathByPID[pid] = path
        if let cached = identityByPath[path] {
            identityByPID[pid] = cached
            return cached
        }

        var identity = Self.identity(forExecutablePath: path, fallbackName: fallbackName)
        // Only an un-bundled process can be adopted; a bundled one already knows
        // which app it belongs to.
        if identity.bundlePath == nil,
           let parent = Self.adoptiveParent(ancestorPaths: ancestorPaths(of: pid)) {
            identity = Self.adopted(identity, by: parent)
        }

        identityByPID[pid] = identity
        // Cacheable by path only for a bundled process, whose answer cannot
        // depend on ancestry. Caching an un-bundled one would be wrong even when
        // it found no parent: `/bin/zsh` under launchd is a system row, the same
        // `/bin/zsh` under VS Code is a child of it, and whichever ran first
        // would answer for the other. Their per-pid entries keep the ancestor
        // walk to once per process either way, and for a real daemon that walk
        // is a single syscall — launchd is the immediate parent.
        if identity.bundlePath != nil { identityByPath[path] = identity }
        return identity
    }

    /// Drops per-pid entries for processes no longer present.
    ///
    /// Necessary because macOS reuses pids: a stale mapping would silently
    /// attribute a new process's traffic to whatever previously held its pid.
    /// The path→identity and icon caches are keyed by path and stay valid.
    public func retainOnly(pids: Set<Int32>) {
        for pid in pathByPID.keys where !pids.contains(pid) {
            pathByPID.removeValue(forKey: pid)
        }
        for pid in identityByPID.keys where !pids.contains(pid) {
            identityByPID.removeValue(forKey: pid)
        }
    }

    // MARK: - Ancestry

    /// Executable paths of `pid`'s ancestors, nearest first.
    ///
    /// Stops at launchd (pid 1), which owns every daemon and would otherwise be
    /// walked into on each one. Entries that cannot be resolved are skipped
    /// rather than ending the walk: an intermediate process may have exited, and
    /// the app above it is still the right answer.
    private func ancestorPaths(of pid: Int32) -> [String] {
        var paths: [String] = []
        var current = pid
        for _ in 0..<Self.maxAncestorDepth {
            guard let parent = Self.parentPID(of: current), parent > 1, parent != current
            else { break }
            current = parent
            if let path = Self.executablePath(pid: current) { paths.append(path) }
        }
        return paths
    }

    /// The nearest ancestor that lives in an `.app` bundle.
    ///
    /// Pure and takes the chain as input, so the adoption rule is testable
    /// without spawning processes.
    public static func adoptiveParent(ancestorPaths: [String]) -> ParentApp? {
        for path in ancestorPaths {
            let identity = identity(forExecutablePath: path, fallbackName: "")
            guard let bundlePath = identity.bundlePath else { continue }
            return ParentApp(key: identity.key,
                             displayName: identity.displayName,
                             bundlePath: bundlePath)
        }
        return nil
    }

    /// Re-files an un-bundled identity as a child of `parent`.
    ///
    /// The key is qualified by the parent because the executable path is not
    /// unique per row: the same `node` binary run from VS Code and from a
    /// terminal are two different rows under two different apps, and sharing one
    /// key would merge their bytes into whichever parent was recorded last.
    public static func adopted(_ identity: AppIdentity, by parent: ParentApp) -> AppIdentity {
        AppIdentity(key: "\(parent.key)\(keySeparator)\(identity.key)",
                    displayName: identity.displayName,
                    bundlePath: nil,
                    isSystem: false,
                    parent: parent)
    }

    /// Joins a parent key to a child key. A control character, so it cannot occur
    /// in either half — both are filesystem paths.
    static let keySeparator: Character = "\u{1}"

    /// The key an adopted process would have had before nesting existed.
    ///
    /// A store written by an earlier version holds that key, and its bytes are
    /// real. Without this the same process appears twice — once frozen in the
    /// System group and once accumulating under its parent — which is what the
    /// upgrade looked like in practice.
    public static func keyBeforeAdoption(_ key: String) -> String? {
        guard let index = key.lastIndex(of: keySeparator) else { return nil }
        let tail = String(key[key.index(after: index)...])
        return tail.isEmpty ? nil : tail
    }

    /// Parent pid, or nil when the process is gone.
    ///
    /// `PROC_PIDT_SHORTBSDINFO` was verified to work unprivileged and with no
    /// entitlement, including across user boundaries.
    public static func parentPID(of pid: Int32) -> Int32? {
        guard pid > 0 else { return nil }
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else {
            return nil
        }
        return Int32(bitPattern: info.pbsi_ppid)
    }

    public func icon(for identity: AppIdentity) -> NSImage {
        if let cached = iconByKey[identity.key] { return cached }
        let image: NSImage
        if let bundlePath = identity.bundlePath {
            image = NSWorkspace.shared.icon(forFile: bundlePath)
        } else if identity.isSystem {
            image = Self.systemDaemonIcon()
        } else {
            // An adopted child. The gear would read as "OS daemon", which is
            // exactly the classification this row exists to correct.
            image = NSWorkspace.shared.icon(for: .unixExecutable)
        }
        image.size = NSSize(width: 16, height: 16)
        iconByKey[identity.key] = image
        return image
    }

    // MARK: - Path resolution

    public static func executablePath(pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 2)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    /// Folds an executable path up to the app a user recognises.
    ///
    /// Uses the **outermost** `.app` in the path, which is what collapses
    /// helpers into their parent:
    ///
    ///   /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome
    ///     Framework.framework/Versions/151/Helpers/Google Chrome Helper.app/
    ///     Contents/MacOS/Google Chrome Helper
    ///
    /// The innermost `.app` is "Google Chrome Helper"; the outermost is
    /// "Google Chrome". Taking the outermost means all dozen helpers accumulate
    /// into one row.
    public static func identity(forExecutablePath path: String, fallbackName: String) -> AppIdentity {
        let components = (path as NSString).pathComponents

        if let index = components.firstIndex(where: { $0.hasSuffix(".app") }) {
            let bundlePath = NSString.path(withComponents: Array(components[0...index]))
            return AppIdentity(key: bundlePath,
                               displayName: displayName(forBundle: bundlePath, components[index]),
                               bundlePath: bundlePath,
                               isSystem: false)
        }

        // No bundle: an OS daemon such as /usr/sbin/mDNSResponder. Keyed by
        // path so each daemon stays distinct inside the System group.
        return AppIdentity(key: path,
                           displayName: components.last ?? fallbackName,
                           bundlePath: nil,
                           isSystem: true)
    }

    private static func displayName(forBundle bundlePath: String, _ directoryName: String) -> String {
        if let bundle = Bundle(path: bundlePath),
           let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"]
                       ?? bundle.infoDictionary?["CFBundleDisplayName"]
                       ?? bundle.infoDictionary?["CFBundleName"]) as? String,
           !name.isEmpty {
            return name
        }
        // Strip ".app" — Finder-style naming without a filesystem round-trip.
        return (directoryName as NSString).deletingPathExtension
    }

    private static func systemDaemonIcon() -> NSImage {
        if let image = NSImage(systemSymbolName: "gearshape.fill",
                               accessibilityDescription: "System process") {
            return image
        }
        return NSWorkspace.shared.icon(for: .unixExecutable)
    }
}
