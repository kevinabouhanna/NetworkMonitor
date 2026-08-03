import AppKit
import Foundation

/// Turns off automatic updates for applications whose setting lives in a JSON
/// config file rather than a preference domain.
///
/// This tier exists because of what checking the alternatives turned up. VS Code
/// looks like an ideal candidate for endpoint blocking — `update.code.
/// visualstudio.com` is `updateUrl` in its own product.json — right up until you
/// notice the Remote-SSH extension downloads the VS Code server from the same
/// host. Blocking it would stop remote development working, which is precisely
/// the "breaks the app" outcome the whole feature promises to avoid. Its own
/// `update.mode` setting does the job with no privileges and no side effects.
///
/// Edits are **surgical**, not a parse-and-rewrite. These files belong to the
/// user: VS Code's may contain comments and trailing commas (it is JSONC, not
/// JSON), the ordering is theirs, and re-emitting it from a parsed object would
/// silently reformat the lot. One line is inserted, and on revert that same line
/// is removed.
public final class ConfigFileSuppressor: UpdateSuppressor {

    public let name = "Apps configured by file"

    public struct Target: Equatable {
        public var displayName: String
        public var path: String
        public var key: String
        /// The value as a JSON literal, including quotes for strings.
        public var suppressedLiteral: String

        /// Matches `SuppressionRecord.Target.configFile`.
        public var id: String { "\(path)/\(key)" }
    }

    public init() {}

    // MARK: Discovery

    public func targets() -> [Target] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var found: [Target] = []

        // VS Code. `update.mode: "none"` disables both the check and the
        // download; "manual" would still check. Verified on this machine: the
        // key is absent, so the default ("all") applies and it auto-updates.
        let vscode = home.appendingPathComponent(
            "Library/Application Support/Code/User/settings.json")
        if FileManager.default.fileExists(atPath: vscode.path) {
            found.append(Target(displayName: "Visual Studio Code",
                                path: vscode.path,
                                key: "update.mode",
                                suppressedLiteral: "\"none\""))
        }

        // Claude Desktop keeps its applied config under a UUID named by a
        // sibling _meta.json. Absent on this machine — Claude has not written
        // one yet — so the target only appears once it exists, and Claude is
        // covered by endpoint blocking in the meantime.
        let claudeMeta = home.appendingPathComponent(
            "Library/Application Support/Claude/configLibrary/_meta.json")
        if let data = FileManager.default.contents(atPath: claudeMeta.path),
           let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let applied = meta["appliedId"] as? String,
           applied.range(of: "^[a-f0-9-]{36}$", options: .regularExpression) != nil {
            let config = claudeMeta.deletingLastPathComponent()
                .appendingPathComponent("\(applied).json")
            if FileManager.default.fileExists(atPath: config.path) {
                found.append(Target(displayName: "Claude",
                                    path: config.path,
                                    key: "disableAutoUpdates",
                                    suppressedLiteral: "true"))
            }
        }

        return found
    }

    public func discover() -> [CoveredItem] {
        targets().map {
            CoveredItem(id: $0.id,
                        displayName: $0.displayName,
                        mechanism: "App setting",
                        // Reported but never acted on: `apply()` writes these
                        // files whether or not the app is running, because an
                        // editor re-reads its settings file rather than caching
                        // it the way `cfprefsd` does.
                        isDeferred: false)
        }
    }

    // MARK: Apply and revert

    @discardableResult
    public func apply(journal: SuppressionJournal,
                      excluding: Set<String> = []) -> SuppressionResult {
        var result = SuppressionResult()

        for target in targets() {
            if excluding.contains(target.id) { continue }

            let recordTarget = SuppressionRecord.Target.configFile(path: target.path,
                                                                    key: target.key)
            if journal.record(for: recordTarget) != nil { continue }

            guard let contents = try? String(contentsOfFile: target.path, encoding: .utf8)
            else { result.failed.append(target.displayName); continue }

            // Already set by the user, to anything. Not ours to touch, and on
            // revert it must stay exactly as they left it.
            if let existing = JSONConfigEdit.value(of: target.key, in: contents) {
                if existing != target.suppressedLiteral {
                    result.failed.append(target.displayName)
                }
                continue
            }

            guard let edited = JSONConfigEdit.inserting(key: target.key,
                                                        literal: target.suppressedLiteral,
                                                        into: contents)
            else { result.failed.append(target.displayName); continue }

            do {
                try journal.record(SuppressionRecord(target: recordTarget,
                                                     priorValue: .absent,
                                                     appliedValue: .string(target.suppressedLiteral)))
            } catch {
                result.failed.append(target.displayName)
                continue
            }

            do {
                try write(edited, to: target.path)
                result.applied.append(target.displayName)
            } catch {
                journal.clear(recordTarget)
                result.failed.append(target.displayName)
            }
        }

        return result
    }

    public func revert(journal: SuppressionJournal) {
        for record in journal.records {
            guard case .configFile(let path, let key) = record.target else { continue }
            defer { journal.clear(record.target) }

            guard let contents = try? String(contentsOfFile: path, encoding: .utf8)
            else { continue }

            // Only remove the key if it still holds the value we wrote. The
            // user may have changed it themselves since, and their setting is
            // not ours to delete.
            guard let current = JSONConfigEdit.value(of: key, in: contents),
                  case .string(let applied) = record.appliedValue,
                  current == applied
            else { continue }

            if let cleaned = JSONConfigEdit.removing(key: key, from: contents) {
                try? write(cleaned, to: path)
            }
        }
    }

    private func write(_ contents: String, to path: String) throws {
        // Atomic: a half-written settings.json makes the app fall back to
        // defaults and can look like the user lost their configuration.
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func isRunning(_ displayName: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.localizedName == displayName
        }
    }
}

// MARK: - Surgical JSON editing

/// Inserts and removes a single top-level key in a JSON or JSONC document,
/// leaving every other byte alone.
///
/// Deliberately text-based. `JSONSerialization` would reject VS Code's file for
/// its comments, and round-tripping through a dictionary would reorder keys,
/// drop comments and reformat the user's file — a destructive change to
/// something we were only asked to add one line to.
public enum JSONConfigEdit {

    /// The literal value of a top-level key, or nil if the key is absent.
    ///
    /// Matches `"key": <value>` up to the next comma or closing brace. Good
    /// enough because every key handled here holds a string or a boolean, never
    /// a nested object.
    public static func value(of key: String, in contents: String) -> String? {
        let pattern = "\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*:\\s*([^,\\n}]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: contents,
                                           range: NSRange(contents.startIndex..., in: contents)),
              let range = Range(match.range(at: 1), in: contents)
        else { return nil }
        return String(contents[range]).trimmingCharacters(in: .whitespaces)
    }

    /// Adds the key immediately after the opening brace.
    ///
    /// First position rather than last so no trailing-comma question arises:
    /// appending before `}` means deciding whether the previous line already
    /// ends in a comma, and getting that wrong corrupts the file.
    public static func inserting(key: String, literal: String,
                                 into contents: String) -> String? {
        guard let brace = contents.firstIndex(of: "{") else { return nil }
        let after = contents.index(after: brace)
        // An empty object has no following entry, so no comma.
        let rest = contents[after...].trimmingCharacters(in: .whitespacesAndNewlines)
        let comma = rest.hasPrefix("}") ? "" : ","
        let line = "\n    \"\(key)\": \(literal)\(comma)"
        return String(contents[..<after]) + line + String(contents[after...])
    }

    /// Removes the whole line holding the key, including its trailing comma.
    public static func removing(key: String, from contents: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        // The line, its leading newline and indentation, and any trailing comma.
        let pattern = "\\n[ \\t]*\"\(escaped)\"\\s*:\\s*[^,\\n}]+,?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(contents.startIndex..., in: contents)
        guard regex.firstMatch(in: contents, range: range) != nil else { return contents }
        return regex.stringByReplacingMatches(in: contents, range: range, withTemplate: "")
    }
}
