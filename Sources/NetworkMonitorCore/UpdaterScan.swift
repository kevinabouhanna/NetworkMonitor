import AppKit
import Foundation

/// Finds the apps NetworkMonitor cannot stop updating, without a list of apps.
///
/// Every suppressor reaches a named mechanism, and the names come from one
/// development machine. Somebody else's Mac has other apps. This answers the
/// question the suppressors cannot: of the apps installed *here*, which ones
/// update themselves, and which of those does nothing reach?
///
/// It can answer without a list because updaters come in a handful of shapes,
/// and the shapes are findable where the apps are not:
///
/// - **Squirrel** — Electron's own updater. `Squirrel.framework` in the bundle.
/// - **electron-updater** — the other Electron updater. `app-update.yml` in
///   Resources, naming the cache directory its downloads land in.
/// - **Sparkle** — `Sparkle.framework`. Covered by `PreferenceSuppressor`
///   unless the app is sandboxed, which is exactly when this reports it.
/// - **Its own** — anything else that ships a runnable component named like an
///   updater: Opera's `opera_autoupdate`, Raycast's `Updater` LaunchAgent,
///   Omni's `OmniSoftwareUpdate.framework`.
///
/// What this cannot see is an updater compiled into the app's own binary with
/// no separate component — Tauri's, for one. `UpdateWatch` catches some of
/// those after the fact, by the files they leave.
public enum UpdaterScan {

    public enum Mechanism: String, Codable {
        case squirrel = "Squirrel"
        case electronUpdater = "electron-updater"
        case sparkle = "Sparkle"
        case ownUpdater = "its own updater"

        /// Why an app that updates this way can't be paused, in plain words,
        /// for Settings. The raw value stays the technical name, for the
        /// diagnostic report.
        public var whyNotPaused: String {
            switch self {
            case .squirrel, .electronUpdater:
                return "Updates from inside the app, with no setting NetworkMonitor can turn off"
            case .sparkle:
                return "macOS keeps its update setting where NetworkMonitor can't change it"
            case .ownUpdater:
                return "Has its own updater, with no setting NetworkMonitor can turn off"
            }
        }
    }

    public struct Finding: Equatable, Identifiable {
        public var id: String { bundleIdentifier ?? bundlePath }
        public var displayName: String
        public var bundleIdentifier: String?
        public var bundlePath: String
        public var mechanism: Mechanism
        /// electron-updater's per-app directory in `~/Library/Caches`, from
        /// `app-update.yml`, so a download that lands there can be traced back
        /// to this app.
        public var updaterCacheDirName: String?

        public init(displayName: String, bundleIdentifier: String?, bundlePath: String,
                    mechanism: Mechanism, updaterCacheDirName: String? = nil) {
            self.displayName = displayName
            self.bundleIdentifier = bundleIdentifier
            self.bundlePath = bundlePath
            self.mechanism = mechanism
            self.updaterCacheDirName = updaterCacheDirName
        }
    }

    /// Where an updater can be launched from inside a bundle. Deliberately not
    /// a deep walk: Chrome's framework alone holds thousands of files, and an
    /// updater buried in one is started by something at one of these levels.
    static let componentLocations = [
        "MacOS", "Helpers", "Frameworks", "Resources",
        "Library/LaunchServices", "Library/LaunchAgents", "Library/LaunchDaemons",
    ]

    /// One bundle's updater, if it has one.
    public static func inspect(bundleAt url: URL) -> Finding? {
        let manager = FileManager.default
        let contents = url.appendingPathComponent("Contents")
        let yaml = contents.appendingPathComponent("Resources/app-update.yml")

        let mechanism: Mechanism
        var cacheDirName: String?
        if let text = try? String(contentsOf: yaml, encoding: .utf8) {
            mechanism = .electronUpdater
            cacheDirName = updaterCacheDirName(fromYAML: text)
        } else if manager.fileExists(
            atPath: contents.appendingPathComponent("Frameworks/Squirrel.framework").path) {
            mechanism = .squirrel
        } else if manager.fileExists(
            atPath: contents.appendingPathComponent("Frameworks/Sparkle.framework").path) {
            mechanism = .sparkle
        } else if hasUpdaterComponent(in: contents) {
            mechanism = .ownUpdater
        } else {
            return nil
        }

        return Finding(displayName: ApplicationSearch.displayName(at: url),
                       bundleIdentifier: ApplicationSearch.bundleIdentifier(at: url),
                       bundlePath: url.path,
                       mechanism: mechanism,
                       updaterCacheDirName: cacheDirName)
    }

    /// Every installed app with an updater.
    public static func findings(in bundles: [URL] = ApplicationSearch.bundles()) -> [Finding] {
        bundles.compactMap(inspect(bundleAt:))
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                == .orderedAscending }
    }

    /// The findings that no covered item reaches.
    ///
    /// Matched by bundle identifier first, and by name as a fallback for the
    /// helper's entries that carry none (Canva). An app the user has switched
    /// off individually still counts as covered: that is a choice, not a gap.
    public static func uncovered(_ findings: [Finding], by items: [CoveredItem]) -> [Finding] {
        let identifiers = Set(items.flatMap(\.bundleIdentifiers))
        let names = Set(items.map(\.displayName))
        return findings.filter { finding in
            if let identifier = finding.bundleIdentifier, identifiers.contains(identifier) {
                return false
            }
            return !names.contains(finding.displayName)
        }
    }

    /// Whether a name reads as an updater's: `GoogleUpdater`,
    /// `opera_autoupdate`, `softwareupdated`, `Microsoft AutoUpdate`, `ShipIt`.
    ///
    /// "updat" rather than "update" so `Updater` and `autoupdated` both match.
    public static func looksLikeUpdater(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.contains("updat") || lowered.contains("shipit")
    }

    /// `updaterCacheDirName` from an `app-update.yml`, quotes stripped.
    ///
    /// A line scan, not a YAML parser: the file is a flat list of `key: value`
    /// lines written by electron-builder, and this one key is all that is read.
    static func updaterCacheDirName(fromYAML text: String) -> String? {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "updaterCacheDirName"
            else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            // A directory name, nothing more: this becomes a path component.
            guard !value.isEmpty, !value.contains("/"), value != ".", value != ".."
            else { return nil }
            return value
        }
        return nil
    }

    /// A runnable thing named like an updater, at one of `componentLocations`.
    ///
    /// Named like one *and* runnable — a bundle, a launchd plist, or an
    /// executable with no extension — because the name alone is not enough.
    /// Kindle ships an `update.icns` that is only a picture, and on the
    /// development machine it has its executable bit set, so the bit alone is
    /// not enough either. The updaters actually found — `opera_autoupdate`,
    /// Raycast's `Updater` — are bare Mach-O names, as executables almost
    /// always are.
    static func hasUpdaterComponent(in contents: URL) -> Bool {
        let manager = FileManager.default
        for location in componentLocations {
            let directory = contents.appendingPathComponent(location)
            guard let entries = try? manager.contentsOfDirectory(atPath: directory.path)
            else { continue }
            for entry in entries where looksLikeUpdater(entry) {
                let path = directory.appendingPathComponent(entry).path
                let ext = (entry as NSString).pathExtension
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    if ["app", "framework", "xpc", "bundle"].contains(ext) { return true }
                } else if ext == "plist" {
                    if location.hasPrefix("Library/Launch") { return true }
                } else if ext.isEmpty || location == "Library/LaunchServices",
                          manager.isExecutableFile(atPath: path) {
                    // A privileged helper tool is named by reverse DNS, so what
                    // follows its last dot is a word, not an extension: Chrome's
                    // `com.google.Chrome.UpdaterPrivilegedHelper` (#92).
                    return true
                }
            }
        }
        return false
    }
}

// MARK: - Downloads left behind

/// Where updater frameworks put what they download, in `~/Library/Caches`.
///
/// Each framework stages its payload in a fixed place before installing it,
/// and the place says whose it is:
///
/// - Squirrel: `<bundle id>.ShipIt/update.<random>/` — the unpacked new app.
///   Claude's last update was staged at `…claudefordesktop.ShipIt/update.mQ5fIP5/`.
/// - electron-updater: `<updaterCacheDirName>/pending/<archive>` — Granola's
///   297 MB `Granola-7.668.0-mac-universal.zip` sits in
///   `@granolaelectron-updater/pending/` on the development machine.
/// - Sparkle 2: `<bundle id>/org.sparkle-project.Sparkle/PersistentDownloads/`
///   and `…/Installation/`.
public enum UpdateCaches {

    public enum Owner: Hashable {
        case bundle(String)
        case electronCache(String)
    }

    public struct Payload: Equatable {
        public var path: String
        public var owner: Owner
        /// When the updater made it, which is when its download began: each
        /// framework creates the folder or file first and downloads into it.
        public var created: Date
        public var modified: Date
    }

    /// Every staged payload, without sizes — sizing an unpacked app walks
    /// thousands of files, so `UpdateWatch` sizes only the ones that are new.
    public static func payloads(in caches: URL) -> [Payload] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(atPath: caches.path)
        else { return [] }

        var found: [Payload] = []
        func add(_ directory: URL, owner: Owner, where include: (String) -> Bool) {
            guard let children = try? manager.contentsOfDirectory(atPath: directory.path)
            else { return }
            for child in children where include(child) {
                let url = directory.appendingPathComponent(child)
                guard let values = try? url.resourceValues(
                        forKeys: [.creationDateKey, .contentModificationDateKey]),
                      let modified = values.contentModificationDate
                else { continue }
                found.append(Payload(path: url.path, owner: owner,
                                     created: min(values.creationDate ?? modified, modified),
                                     modified: modified))
            }
        }

        for entry in entries {
            let directory = caches.appendingPathComponent(entry)
            if entry.hasSuffix(".ShipIt") {
                add(directory, owner: .bundle(String(entry.dropLast(".ShipIt".count)))) {
                    $0.hasPrefix("update.")
                }
            } else if entry.hasSuffix("-updater") {
                // The archive, not `update-info.json` beside it.
                add(directory.appendingPathComponent("pending"),
                    owner: .electronCache(entry)) { !$0.hasSuffix(".json") }
            } else {
                let sparkle = directory.appendingPathComponent("org.sparkle-project.Sparkle")
                for stage in ["PersistentDownloads", "Installation"] {
                    add(sparkle.appendingPathComponent(stage), owner: .bundle(entry)) { _ in true }
                }
            }
        }
        return found
    }

    /// Bytes on disk under `path`, file or directory.
    public static func size(of path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        if let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true {
            return Int64(values.fileSize ?? 0)
        }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

// MARK: - Watching a metered connection

/// Notices updates that arrive on a metered connection anyway, and says whose.
///
/// The spec's answer to an update NetworkMonitor could not prevent was always
/// "report what it cost". This is that report, from two signals that need no
/// list of apps:
///
/// - **Files.** A payload staged in one of `UpdateCaches`' places after the
///   connection became metered is an update that downloaded over it. This is
///   the only way to see an Electron app's update at all: the download runs in
///   the app's own process, and to nettop it is just the app using the network.
///   So its cost is that app's traffic while the payload was being written
///   (#95). The payload's size is the unpacked update on disk, which said 272
///   MB for a Slack update that used about 120 MB.
/// - **Traffic.** An updater that runs as its own process — `GoogleUpdater`,
///   `opera_autoupdate`, `softwareupdated` — shows up in nettop under its own
///   name, so its bytes are counted as they happen.
///
/// Both include covered apps on purpose. A Sparkle app that was open when the
/// hotspot was joined could not have its setting changed, and if it updated
/// anyway, the user should hear about it rather than trust the switch.
///
/// The sightings outlive the connection — the moment someone looks is usually
/// after they are home — and are replaced when the next metered one begins.
public final class UpdateWatch {

    public struct Sighting: Codable, Equatable, Identifiable {
        public enum Source: String, Codable {
            /// A payload appeared in an updater cache.
            case download
            /// An updater-named process moved this many bytes.
            case traffic
        }

        public var id: String { "\(source.rawValue):\(name)" }
        /// The app, or for traffic the process.
        public var name: String
        /// For traffic, the app the process belongs to when that differs.
        public var app: String?
        public var source: Source
        public var bytes: Int64
        public var lastSeen: Date
        /// For a download, `bytes` is the update's size on disk, not data
        /// used: the app's traffic wasn't seen while it downloaded. An
        /// unpacked update is bigger than the download, so it's at most that.
        public var isSizeOnDisk: Bool?

        public var isUpperBound: Bool { isSizeOnDisk == true }
    }

    /// What a payload's owner is called, and where its app is, to find its
    /// traffic.
    public struct Owner: Equatable {
        public var name: String
        public var bundlePath: String?

        public init(name: String, bundlePath: String? = nil) {
            self.name = name
            self.bundlePath = bundlePath
        }
    }

    /// Below this, a sighting is an update *check*, not an update, and is not
    /// worth anyone's attention.
    public static let reportableBytes: Int64 = 1_000_000
    /// How often the caches are looked at while metered. A payload is tens to
    /// hundreds of megabytes; half a minute is far finer than anyone needs, and
    /// there is no timer — `tick` rides on the nettop sample.
    public static let scanInterval: TimeInterval = 30

    public private(set) var sightings: [Sighting] = []
    public private(set) var isActive = false

    private let cachesDirectory: URL
    private let defaults: UserDefaults
    private let resolveOwner: (UpdateCaches.Owner) -> Owner
    private static let storageKey = "meteringUpdateSightings"

    private var networkID: String?
    /// The last connection was left, rather than the app merely quitting on it.
    private var ended = false
    private var activeSince = Date.distantPast
    private var baseline: [String: Date] = [:]
    private var sizes: [String: (modified: Date, bytes: Int64)] = [:]
    private var owners: [UpdateCaches.Owner: Owner] = [:]
    private var lastScan = Date.distantPast
    /// Each app's internet bytes by the minute, by bundle path, while
    /// watching: what a download's cost is read from. Memory only, and
    /// a minute is fine enough for downloads that take several.
    private var minutes: [String: [Int64: Int64]] = [:]

    public convenience init(defaults: UserDefaults = .standard) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.init(cachesDirectory: caches, defaults: defaults,
                  resolveOwner: UpdateWatch.resolveInstalledOwner)
    }

    public init(cachesDirectory: URL,
                defaults: UserDefaults,
                resolveOwner: @escaping (UpdateCaches.Owner) -> Owner) {
        self.cachesDirectory = cachesDirectory
        self.defaults = defaults
        self.resolveOwner = resolveOwner
        load()
    }

    /// Sightings big enough to be updates, largest first.
    public var reportable: [Sighting] {
        sightings.filter { $0.bytes >= Self.reportableBytes }
            .sorted { $0.bytes > $1.bytes }
    }

    // MARK: Lifecycle

    /// Starts watching a metered connection. Idempotent for the same network,
    /// so it can be called on every evaluation.
    ///
    /// A fresh report starts on a different network, or on the same one joined
    /// again after an `end()` — the same rule the usage totals follow. What does
    /// *not* start one is relaunching mid-hotspot: the app quitting is not the
    /// connection ending, so the report it was building carries on.
    public func begin(networkID id: String, now: Date = Date()) {
        if isActive, networkID == id { return }
        if networkID != id || ended {
            sightings.removeAll()
            minutes.removeAll()
            networkID = id
        }
        ended = false
        save()
        isActive = true
        activeSince = now
        // What is already sitting in the caches arrived before this connection
        // did, and is not its cost.
        baseline = Dictionary(UpdateCaches.payloads(in: cachesDirectory)
                                .map { ($0.path, $0.modified) },
                              uniquingKeysWith: { first, _ in first })
        lastScan = now
    }

    /// Stops watching. The sightings stay, for whoever looks next.
    public func end() {
        guard isActive else { return }
        isActive = false
        ended = true
        save()
    }

    // MARK: Signals

    /// Counts one sample's bytes for an updater-named process. Returns true when
    /// this crossed the reporting threshold, so the caller can publish then
    /// rather than wait for the next scan.
    @discardableResult
    public func recordTraffic(processName: String, appName: String?,
                              bytes: Int64, now: Date = Date()) -> Bool {
        guard isActive, bytes > 0 else { return false }
        let app = appName == processName ? nil : appName
        if let index = sightings.firstIndex(where: {
            $0.source == .traffic && $0.name == processName
        }) {
            let before = sightings[index].bytes
            sightings[index].bytes += bytes
            sightings[index].lastSeen = now
            return before < Self.reportableBytes
                && sightings[index].bytes >= Self.reportableBytes
        }
        sightings.append(Sighting(name: processName, app: app, source: .traffic,
                                  bytes: bytes, lastSeen: now))
        return bytes >= Self.reportableBytes
    }

    /// One sample's internet bytes for an app, by its bundle path.
    public func recordApp(bundlePath: String, bytes: Int64, now: Date = Date()) {
        guard isActive, bytes > 0 else { return }
        minutes[bundlePath, default: [:]][Self.minute(now), default: 0] += bytes
    }

    /// An app's bytes in the minutes from `start` to `end`, both included.
    func traffic(of bundlePath: String, from start: Date, to end: Date) -> Int64 {
        let first = Self.minute(start), last = Self.minute(end)
        return minutes[bundlePath]?.reduce(0) { total, entry in
            (first...last).contains(entry.key) ? total + entry.value : total
        } ?? 0
    }

    private static func minute(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 / 60).rounded(.down))
    }

    /// Looks at the caches if `scanInterval` has passed. Returns true when the
    /// caller should republish — after any scan, since traffic totals have been
    /// growing in between.
    @discardableResult
    public func tick(now: Date = Date()) -> Bool {
        guard isActive, now.timeIntervalSince(lastScan) >= Self.scanInterval else { return false }
        lastScan = now
        scan(now: now)
        save()
        return true
    }

    /// One pass over the caches. Public so a test can run it without waiting.
    public func scan(now: Date = Date()) {
        // An app's payloads together: Sparkle stages a download and then an
        // installation, and they're one update.
        var downloads: [String: (owner: Owner, start: Date, end: Date, size: Int64)] = [:]
        for payload in UpdateCaches.payloads(in: cachesDirectory) {
            // Unchanged since the connection began, or older than it.
            if baseline[payload.path] == payload.modified { continue }
            if payload.modified < activeSince { continue }

            let bytes: Int64
            if let cached = sizes[payload.path], cached.modified == payload.modified {
                bytes = cached.bytes
            } else {
                bytes = UpdateCaches.size(of: payload.path)
                sizes[payload.path] = (payload.modified, bytes)
            }

            // Cached: resolving an electron-updater directory walks every app's
            // bundle, and a download in progress changes on every scan.
            let owner = owners[payload.owner] ?? resolveOwner(payload.owner)
            owners[payload.owner] = owner
            // Begun before the connection was, only its part on it counts.
            let start = max(payload.created, activeSince)
            if let seen = downloads[owner.name] {
                downloads[owner.name] = (owner, min(seen.start, start), max(seen.end, payload.modified),
                                         max(seen.size, bytes))
            } else {
                downloads[owner.name] = (owner, start, payload.modified, bytes)
            }
        }

        for (name, download) in downloads {
            let used = download.owner.bundlePath.map {
                traffic(of: $0, from: download.start, to: download.end)
            } ?? 0
            // What the app used, once there's enough of it to be an update:
            // less means its traffic wasn't seen, after a relaunch or under
            // another name, and the size on disk is all there is to go on.
            let measured = used >= Self.reportableBytes
            let bytes = measured ? used : download.size
            if let index = sightings.firstIndex(where: { $0.source == .download && $0.name == name }) {
                let previous = sightings[index]
                if measured {
                    // Replaces a size on disk, and otherwise only grows: a
                    // relaunch mid-download forgets the minutes before it.
                    sightings[index].bytes = previous.isUpperBound ? bytes : max(previous.bytes, bytes)
                    sightings[index].isSizeOnDisk = nil
                } else if previous.isUpperBound {
                    sightings[index].bytes = max(previous.bytes, bytes)
                }
                sightings[index].lastSeen = now
            } else {
                sightings.append(Sighting(name: name, app: nil, source: .download, bytes: bytes,
                                          lastSeen: now, isSizeOnDisk: measured ? nil : true))
            }
        }
    }

    // MARK: Names

    /// An owner's name as the user knows it: the installed app's, from
    /// LaunchServices for a bundle identifier and from each app's
    /// `app-update.yml` for an electron-updater directory. Falls back to the raw
    /// identifier, which is still more use than nothing.
    static func resolveInstalledOwner(_ owner: UpdateCaches.Owner) -> Owner {
        switch owner {
        case .bundle(let identifier):
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                return Owner(name: ApplicationSearch.displayName(at: url), bundlePath: url.path)
            }
            return Owner(name: identifier)
        case .electronCache(let directory):
            if let finding = UpdaterScan.findings()
                .first(where: { $0.updaterCacheDirName == directory }) {
                return Owner(name: finding.displayName, bundlePath: finding.bundlePath)
            }
            return Owner(name: String(directory.dropLast("-updater".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "@")))
        }
    }

    // MARK: Persistence

    private struct Stored: Codable {
        var networkID: String?
        var ended: Bool
        var sightings: [Sighting]
        /// 2 from 1.16.1: a download's bytes are what its app used (#95).
        /// Missing before, when they were its size on disk.
        var version: Int?
    }

    private static let storageVersion = 2

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }
        networkID = stored.networkID
        ended = stored.ended
        sightings = stored.sightings
        // Saved by 1.15 or earlier: its downloads were sizes on disk, so they
        // say "up to" rather than pass for data used (#160).
        if stored.version == nil {
            for index in sightings.indices where sightings[index].source == .download {
                sightings[index].isSizeOnDisk = true
            }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Stored(networkID: networkID,
                                                          ended: ended,
                                                          sightings: sightings,
                                                          version: Self.storageVersion))
        else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
