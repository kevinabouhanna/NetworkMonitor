import Foundation

/// A value read from, or written to, something outside this app.
///
/// Only the shapes actually needed: Sparkle's flags are booleans, Microsoft
/// AutoUpdate's `HowToCheck` is a string, and Keystone's `checkInterval` is a
/// number carried as a string. `absent` is distinct from `false` on purpose —
/// putting back a key that was never there is not the same as restoring it.
public enum SuppressedValue: Codable, Equatable {
    case bool(Bool)
    case int(Int)
    case string(String)
    case absent

    /// Bridges to what `CFPreferences` hands back.
    ///
    /// **Booleans and numbers both arrive as `NSNumber`, and telling them apart
    /// matters.** Chrome's Keystone `checkInterval` is `18000`; read through
    /// `boolValue` that becomes `true`, and restoring it would write `true` into
    /// a numeric setting — quietly corrupting a preference this app does not
    /// own. `CFBooleanGetTypeID` is the only reliable discriminator, since
    /// `NSNumber` erases the distinction.
    init(plist: Any?) {
        switch plist {
        case .none:
            self = .absent
        case let text as String:
            self = .string(text)
        case let number as NSNumber:
            if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .int(number.intValue)
            }
        default:
            self = .absent
        }
    }

    public var plistValue: Any? {
        switch self {
        case .bool(let value):   return value as CFBoolean
        case .int(let value):    return value as NSNumber
        case .string(let value): return value as NSString
        case .absent:            return nil
        }
    }
}

/// One change this app made to something it does not own.
public struct SuppressionRecord: Codable, Equatable {

    public enum Target: Codable, Equatable {
        /// A key in another application's preference domain.
        case preference(domain: String, key: String)
        /// A key in a root-owned file, applied through the privileged helper.
        case systemPreference(domain: String, key: String)
        /// A single key inserted into an application's own JSON config file.
        case configFile(path: String, key: String)
    }

    public var target: Target
    /// What was there before. `absent` means the key did not exist.
    public var priorValue: SuppressedValue
    /// What this app put there. Revert compares against it, and a mismatch means
    /// somebody else has since changed it.
    public var appliedValue: SuppressedValue
    public var appliedAt: Date

    public init(target: Target,
                priorValue: SuppressedValue,
                appliedValue: SuppressedValue,
                appliedAt: Date = Date()) {
        self.target = target
        self.priorValue = priorValue
        self.appliedValue = appliedValue
        self.appliedAt = appliedAt
    }
}

/// The record of everything currently suppressed, persisted before any of it
/// happens.
///
/// This is the safety mechanism the whole feature rests on. Its failure mode is
/// not an error message — it is a Mac that quietly stopped updating months ago
/// with nothing left to say what changed or how to undo it. So:
///
/// - **Write-ahead.** `record(_:)` persists to disk *before* the caller changes
///   anything. A crash between the two leaves a record whose revert is a no-op,
///   which is the harmless direction; the reverse would strand the change.
/// - **Replay is not revert.** Replaying at launch while still on a metered
///   network would un-suppress everything. `MeteringController` restores, then
///   re-evaluates, then re-applies if still metered.
/// - **A value that is not what we set is not ours to restore.** If the user
///   turns an app's auto-update off by hand while metered, `revertible(_:)`
///   leaves it alone.
public final class SuppressionJournal {

    public private(set) var records: [SuppressionRecord] = []
    private let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
        self.records = Self.load(from: self.url)
    }

    /// Beside `usage.json`, so one directory holds all of this app's state and
    /// `uninstall.sh` has one place to look.
    public static func defaultURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("NetworkMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        return directory.appendingPathComponent("suppression.json")
    }

    // MARK: Recording

    /// Persists a record and returns only once it is on disk.
    ///
    /// Callers must not mutate anything until this returns. Throwing rather than
    /// silently continuing is deliberate: a change made without a durable record
    /// of how to undo it is exactly the outcome this file exists to prevent, so
    /// the suppressor skips that target instead.
    public func record(_ record: SuppressionRecord) throws {
        records.removeAll { $0.target == record.target }
        records.append(record)
        try save()
    }

    /// Drops a record once its change has been undone.
    public func clear(_ target: SuppressionRecord.Target) {
        records.removeAll { $0.target == target }
        try? save()
    }

    public func clearAll() {
        records.removeAll()
        try? save()
    }

    public func record(for target: SuppressionRecord.Target) -> SuppressionRecord? {
        records.first { $0.target == target }
    }

    public var isEmpty: Bool { records.isEmpty }

    /// Whether a record may be reverted, given what the value looks like now.
    ///
    /// Equal to what we wrote → ours, restore it. Anything else → somebody has
    /// changed it since, and putting our value back would overwrite a decision
    /// that was not ours to overwrite.
    public static func revertible(_ record: SuppressionRecord,
                                  currentValue: SuppressedValue) -> Bool {
        currentValue == record.appliedValue
    }

    // MARK: Persistence

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(records)

        // Same atomic replace as UsageStore: a half-written journal is worse
        // than none, because revert would then restore some changes and not
        // others with no way to tell which.
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent("suppression.json.tmp")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            // Keep the outgoing version as the backup before replacing it. See
            // `backupURL` for why one copy behind is the useful thing to keep.
            try? Data(contentsOf: url).write(to: Self.backupURL(for: url),
                                             options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    /// Sibling of the journal, holding the version immediately before the current
    /// one.
    ///
    /// This exists because losing the journal while suppressions are applied is
    /// the one failure with no way back: the prior values are gone, and the
    /// suppressors then skip every target precisely *because* it already holds
    /// the suppressed value, so nothing is re-recorded and nothing is ever
    /// restored. Guessing a prior is not an option either — writing "absent"
    /// would delete a setting the user may have turned off deliberately.
    ///
    /// One copy behind is enough to survive the realistic cases: a truncated
    /// write, a corrupted file, an editor or cleaner removing it. It cannot
    /// survive somebody deleting the whole directory, and it is not meant to.
    static func backupURL(for url: URL) -> URL {
        url.appendingPathExtension("backup")
    }

    private static func load(from url: URL) -> [SuppressionRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        func decode(_ target: URL) -> [SuppressionRecord]? {
            guard let data = try? Data(contentsOf: target), !data.isEmpty,
                  let records = try? decoder.decode([SuppressionRecord].self, from: data)
            else { return nil }
            return records
        }

        if let records = decode(url) { return records }

        // The primary is missing or will not decode. Falling back to the backup
        // is strictly better than treating it as empty: an empty journal means
        // every suppression currently in force becomes permanent, silently.
        if let recovered = decode(backupURL(for: url)) {
            // Promote it, so the next save has something to back up in turn and a
            // second failure does not land on the same missing file.
            try? Data(contentsOf: backupURL(for: url)).write(to: url, options: .atomic)
            return recovered
        }

        // Genuinely nothing to go on. Still not fatal: refusing to launch would
        // leave the user with suppressions in place and no app able to lift them.
        return []
    }
}
