import Foundation

/// Stops Electron apps downloading updates while metered, including an app that
/// was already open, by making the folder each one downloads into read-only (#93).
///
/// Every other tier changes a setting, and apps read their settings when they
/// start. An app that has been open since before the hotspot never sees the
/// change: on 27 October Slack, open since the day before, downloaded its update
/// over a hotspot nearly two hours after the helper had written its policy. Where an
/// update lands is decided at download time instead, so that is where this acts.
///
/// - **Squirrel** creates `update.XXXXXXX` with `mkdtemp` in
///   `~/Library/Caches/<bundle id>.ShipIt`, and only then downloads into it.
///   With the folder read-only, `mkdtemp` fails and the payload is never asked
///   for. Checked against a local feed with Slack's and Claude's Squirrel and
///   with the older one VS Code, Figma and Granola ship: the feed was fetched,
///   the payload never was.
/// - **electron-updater** downloads into `~/Library/Caches/<updaterCacheDirName>/pending`,
///   creating `pending` or clearing a stale blockmap in it first, so a read-only
///   folder stops it there. When `pending` already exists with no blockmap, the
///   request starts and fails at its first write. It then hands the archive to
///   Squirrel, so its ShipIt folder is locked as well.
///
/// No list of apps: `UpdaterScan` finds them by how they update, so this reaches
/// Electron apps nobody here has looked at. A folder that isn't there yet is
/// created read-only, so an app that has never updated can't start now.
///
/// The cost is that a manual "Check for Updates" in these apps fails while
/// metered too, as it does for the apps whose update server the helper blocks.
public final class UpdateFolderSuppressor: UpdateSuppressor {

    public let name = "Through their update folders"

    /// One switch for every folder, like the helper's: the apps it covers are
    /// listed under one row rather than beside the rows other tiers give them.
    public static let tierID = "folders/all"

    /// One folder to lock, and the app it belongs to.
    public struct Folder: Equatable {
        public var path: String
        public var displayName: String
        public var bundleIdentifier: String?
    }

    private let caches: URL
    private let findings: () -> [UpdaterScan.Finding]

    public init(cachesDirectory: URL = FileManager.default.urls(for: .cachesDirectory,
                                                                in: .userDomainMask)[0],
                findings: @escaping () -> [UpdaterScan.Finding] = { UpdaterScan.findings() }) {
        self.caches = cachesDirectory
        self.findings = findings
    }

    // MARK: Discovery

    /// The folders `findings` download into, each once.
    ///
    /// An electron-updater app whose cache folder isn't named in its
    /// `app-update.yml` is left out altogether: its download happens before
    /// Squirrel's, so locking only the ShipIt folder would claim a pause that
    /// saves nothing.
    public static func folders(for findings: [UpdaterScan.Finding], in caches: URL) -> [Folder] {
        var folders: [Folder] = []
        func add(_ url: URL, _ finding: UpdaterScan.Finding) {
            guard !folders.contains(where: { $0.path == url.path }) else { return }
            folders.append(Folder(path: url.path, displayName: finding.displayName,
                                  bundleIdentifier: finding.bundleIdentifier))
        }
        for finding in findings {
            switch finding.mechanism {
            case .squirrel:
                break
            case .electronUpdater:
                guard let name = finding.updaterCacheDirName else { continue }
                let cache = caches.appendingPathComponent(name)
                add(cache, finding)
                // Only when it exists: while its parent is locked it can't be made.
                let pending = cache.appendingPathComponent("pending")
                if isDirectory(pending.path) { add(pending, finding) }
            case .sparkle, .ownUpdater:
                continue
            }
            guard let identifier = finding.bundleIdentifier else { continue }
            add(caches.appendingPathComponent("\(identifier).ShipIt"), finding)
        }
        return folders
    }

    public func folders() -> [Folder] {
        Self.folders(for: findings(), in: caches)
    }

    public func discover() -> [CoveredItem] {
        var items: [CoveredItem] = []
        for folder in folders() where !items.contains(where: { $0.displayName == folder.displayName }) {
            items.append(CoveredItem(id: Self.tierID,
                                     displayName: folder.displayName,
                                     mechanism: "Update folder",
                                     effect: "Locks the folder its updates download to",
                                     bundleIdentifiers: folder.bundleIdentifier.map { [$0] } ?? []))
        }
        return items
    }

    // MARK: Apply and revert

    @discardableResult
    public func apply(journal: SuppressionJournal,
                      excluding: Set<String> = []) -> SuppressionResult {
        var result = SuppressionResult()
        guard !excluding.contains(Self.tierID) else { return result }

        for folder in folders() {
            let target = SuppressionRecord.Target.folder(path: folder.path, app: folder.displayName)
            // Already locked by an earlier pass: its record holds the real prior mode.
            if journal.record(for: target) != nil { continue }

            switch lock(folder.path, target: target, journal: journal) {
            case .locked:
                if !result.applied.contains(folder.displayName) {
                    result.applied.append(folder.displayName)
                }
            case .failed:
                if !result.failed.contains(folder.displayName) {
                    result.failed.append(folder.displayName)
                }
            case .leftAlone:
                break
            }
        }
        return result
    }

    private enum Outcome { case locked, failed, leftAlone }

    private func lock(_ path: String, target: SuppressionRecord.Target,
                      journal: SuppressionJournal) -> Outcome {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            // Not there yet: the app would make it at its first download.
            // Recorded as absent, so the revert removes it again.
            do {
                try journal.record(SuppressionRecord(target: target, priorValue: .absent,
                                                     appliedValue: .int(Self.createdMode)))
            } catch { return .failed }
            guard mkdir(path, mode_t(Self.createdMode)) == 0 else {
                journal.clear(target)
                return .failed
            }
            // `mkdir` applies the umask, which can only take bits away.
            chmod(path, mode_t(Self.createdMode))
            return .locked
        }

        // A symlink, a file, or somebody else's folder: not ours to change.
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { return .leftAlone }
        let mode = Int(info.st_mode & 0o7777)
        // Already read-only for its owner, by somebody's choice. It stays as it is,
        // and on revert it must stay that way, so there is nothing to record.
        guard mode & 0o200 != 0 else { return .leftAlone }

        let locked = mode & ~0o222
        do {
            try journal.record(SuppressionRecord(target: target, priorValue: .int(mode),
                                                 appliedValue: .int(locked)))
        } catch { return .failed }
        guard chmod(path, mode_t(locked)) == 0 else {
            journal.clear(target)
            return .failed
        }
        return .locked
    }

    public func revert(journal: SuppressionJournal) {
        for record in journal.records {
            guard case .folder(let path, _) = record.target else { continue }
            defer { journal.clear(record.target) }

            // The journal is a file anybody logged in as this user can edit, so
            // only folders in the caches directory are ever changed from it.
            guard path.hasPrefix(caches.path + "/") else { continue }
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  case .int(let applied) = record.appliedValue,
                  Int(info.st_mode & 0o7777) == applied
            else {
                // Gone, replaced, or its mode changed since: whoever did that
                // decided, and putting ours back would overwrite them.
                continue
            }

            switch record.priorValue {
            case .int(let prior):
                chmod(path, mode_t(prior))
            case .absent:
                // As the app would have made it, then gone again if still empty.
                chmod(path, 0o755)
                rmdir(path)
            case .bool, .string:
                continue
            }
        }
    }

    /// The mode a folder created for the lock gets: readable, not writable.
    static let createdMode = 0o555

    private static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }
}
