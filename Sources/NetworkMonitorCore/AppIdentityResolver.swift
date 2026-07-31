import AppKit
import Foundation
import UniformTypeIdentifiers

/// A network-using app, after helper processes have been folded into their parent.
public struct AppIdentity: Hashable {
    /// Stable key for accumulation and persistence: the bundle path for real
    /// apps, the executable path for daemons.
    public let key: String
    public let displayName: String
    public let bundlePath: String?
    /// True when no `.app` bundle owns the process — an OS daemon. These are
    /// grouped under a single collapsed "System" row.
    public let isSystem: Bool

    public init(key: String, displayName: String, bundlePath: String?, isSystem: Bool) {
        self.key = key
        self.displayName = displayName
        self.bundlePath = bundlePath
        self.isSystem = isSystem
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
public final class AppIdentityResolver {

    private var pathByPID: [Int32: String] = [:]
    private var identityByPath: [String: AppIdentity] = [:]
    private var iconByKey: [String: NSImage] = [:]

    public init() {}

    public func identity(pid: Int32, fallbackName: String) -> AppIdentity {
        if let path = pathByPID[pid], let identity = identityByPath[path] {
            return identity
        }

        guard let path = Self.executablePath(pid: pid) else {
            // kernel_task (pid 0) and processes that exit between the nettop
            // sample and this lookup land here.
            return AppIdentity(key: "system:\(fallbackName)",
                               displayName: fallbackName,
                               bundlePath: nil,
                               isSystem: true)
        }

        pathByPID[pid] = path
        if let cached = identityByPath[path] { return cached }

        let identity = Self.identity(forExecutablePath: path, fallbackName: fallbackName)
        identityByPath[path] = identity
        return identity
    }

    /// Drops pid→path entries for processes no longer present.
    ///
    /// Necessary because macOS reuses pids: a stale mapping would silently
    /// attribute a new process's traffic to whatever previously held its pid.
    /// The path→identity and icon caches are keyed by path and stay valid.
    public func retainOnly(pids: Set<Int32>) {
        for pid in pathByPID.keys where !pids.contains(pid) {
            pathByPID.removeValue(forKey: pid)
        }
    }

    public func icon(for identity: AppIdentity) -> NSImage {
        if let cached = iconByKey[identity.key] { return cached }
        let image: NSImage
        if let bundlePath = identity.bundlePath {
            image = NSWorkspace.shared.icon(forFile: bundlePath)
        } else {
            image = Self.systemDaemonIcon()
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
