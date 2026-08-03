import Foundation

/// One updater this app can reach, as shown in the coverage list.
public struct CoveredItem: Equatable, Identifiable {
    /// Stable key for the per-app opt-out.
    ///
    /// Derived from the same domain/key or path/key the journal records, so a
    /// toggle in Settings and the suppression it governs can never drift apart.
    /// Deliberately not the display name: two apps may share one, and a rename
    /// between releases would silently reset the user's choice.
    public var id: String
    /// What the user calls it — `"VLC"`, `"Google Chrome"`.
    public var displayName: String
    /// How it is reached — `"Sparkle"`, `"LaunchAgent"`. Shown so the list reads
    /// as an explanation rather than a claim.
    public var mechanism: String
    /// True when the change is queued rather than made, because writing another
    /// app's preferences while it is running is unreliable in both directions.
    public var isDeferred: Bool

    public init(id: String,
                displayName: String,
                mechanism: String,
                isDeferred: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.mechanism = mechanism
        self.isDeferred = isDeferred
    }
}

/// What one `apply()` pass actually managed to do.
public struct SuppressionResult: Equatable {
    public var applied: [String] = []
    /// Queued because the owning app is running. Retried when it quits.
    public var deferred: [String] = []
    /// Attempted and refused — a failed `launchctl`, an unwritable domain, or a
    /// journal that could not be persisted.
    public var failed: [String] = []

    public init() {}

    public var isEmpty: Bool {
        applied.isEmpty && deferred.isEmpty && failed.isEmpty
    }

    static func + (lhs: SuppressionResult, rhs: SuppressionResult) -> SuppressionResult {
        var merged = SuppressionResult()
        merged.applied = lhs.applied + rhs.applied
        merged.deferred = lhs.deferred + rhs.deferred
        merged.failed = lhs.failed + rhs.failed
        return merged
    }
}

/// A way of stopping something updating.
///
/// The point of the protocol is that the tiers this app cannot reach today —
/// Electron apps that download inside their own process, which need a content
/// filter and therefore a Developer ID — arrive later as another conformer,
/// leaving the policy, the journal, the settings and the UI untouched.
public protocol UpdateSuppressor: AnyObject {
    /// Shown in the coverage list as a group heading.
    var name: String { get }

    /// What this suppressor can reach right now. Called for display, and cheap
    /// enough to call on demand: nothing is cached across calls because apps get
    /// installed and removed while this one is running.
    func discover() -> [CoveredItem]

    /// Suppress everything discoverable, recording each change first.
    ///
    /// `excluding` holds the ids of items the user has switched off individually.
    /// Filtering here rather than in the controller keeps the decision next to
    /// the code that knows how an item maps onto a journal target.
    @discardableResult
    func apply(journal: SuppressionJournal,
               excluding: Set<String>) -> SuppressionResult

    /// Undo every change of this suppressor's kind in the journal.
    func revert(journal: SuppressionJournal)
}

/// Where to look for installed applications.
///
/// `~/Applications` is included because it is a real install location — this
/// machine has entries in it — and an updater there is no less expensive than
/// one in `/Applications`.
public enum ApplicationSearch {
    public static var directories: [URL] {
        var paths = [URL(fileURLWithPath: "/Applications")]
        let home = FileManager.default.homeDirectoryForCurrentUser
        paths.append(home.appendingPathComponent("Applications"))
        return paths
    }

    /// Top-level `.app` bundles, plus one level down so `/Applications/Utilities`
    /// and vendor folders are not missed.
    public static func bundles() -> [URL] {
        let manager = FileManager.default
        var found: [URL] = []
        for directory in directories {
            guard let entries = try? manager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil) else { continue }
            for entry in entries {
                if entry.pathExtension == "app" {
                    found.append(entry)
                } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?
                            .isDirectory == true {
                    let nested = (try? manager.contentsOfDirectory(
                        at: entry, includingPropertiesForKeys: nil)) ?? []
                    found.append(contentsOf: nested.filter { $0.pathExtension == "app" })
                }
            }
        }
        return found
    }

    public static func bundleIdentifier(at bundleURL: URL) -> String? {
        Bundle(url: bundleURL)?.bundleIdentifier
    }

    public static func displayName(at bundleURL: URL) -> String {
        bundleURL.deletingPathExtension().lastPathComponent
    }

    /// True when the app is sandboxed, which redirects its preferences into
    /// `~/Library/Containers/<id>/Data/Library/Preferences`.
    ///
    /// `CFPreferencesSetAppValue` from outside would write
    /// `~/Library/Preferences/<id>.plist`, a file the app never reads — the
    /// change would look like it worked and do nothing. None of the Sparkle apps
    /// on this machine are sandboxed, but any App Store app is.
    public static func isSandboxed(bundleIdentifier: String) -> Bool {
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers")
            .appendingPathComponent(bundleIdentifier)
        return FileManager.default.fileExists(atPath: container.path)
    }
}
