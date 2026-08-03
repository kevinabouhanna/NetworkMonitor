import AppKit
import Foundation

/// Turns off automatic update *checks* by writing the updater's own documented
/// preference.
///
/// This is the cleanest tier there is: no privileges, no processes killed, no
/// traffic touched, and the app behaves exactly as if the user had unticked
/// "automatically check for updates" in its own preferences — because that is
/// literally the same key. A manual "Check for Updates…" still works, which is
/// correct: the feature is about unattended downloads, not about getting in the
/// way of someone who has decided they want one.
///
/// Two mechanisms, verified present on the development machine:
///
/// - **Sparkle** — `SUEnableAutomaticChecks`. Six apps here ship it, and three
///   were found with the flag on and one with `SUAutomaticallyUpdate` on as well,
///   meaning it would have installed over a hotspot without asking.
/// - **Microsoft AutoUpdate** — `HowToCheck`, set to `Manual`. Its domain exists
///   here with the key unset, which is MAU's automatic-download default.
///
/// Only the *check* flag is written, not `SUAutomaticallyUpdate`. Stopping the
/// check stops the download, which is the thing that costs money; touching both
/// would double the journal for no additional saving.
public final class PreferenceSuppressor: UpdateSuppressor {

    public let name = "Apps with an update setting"

    /// A domain and key this suppressor knows how to turn off.
    public struct Target: Equatable {
        public var displayName: String
        public var domain: String
        public var key: String
        public var suppressedValue: SuppressedValue
        public var mechanism: String

        /// Matches `SuppressionRecord.Target.preference`, so the opt-out and the
        /// journal entry are keyed identically.
        public var id: String { "\(domain)/\(key)" }
    }

    private let sparkleKey = "SUEnableAutomaticChecks"
    private let mauDomain = "com.microsoft.autoupdate2"
    private let mauPath = "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app"

    public init() {}

    // MARK: Discovery

    public func targets() -> [Target] {
        var found: [Target] = []

        for bundleURL in ApplicationSearch.bundles() {
            let sparkle = bundleURL
                .appendingPathComponent("Contents/Frameworks/Sparkle.framework")
            guard FileManager.default.fileExists(atPath: sparkle.path),
                  let identifier = ApplicationSearch.bundleIdentifier(at: bundleURL),
                  !ApplicationSearch.isSandboxed(bundleIdentifier: identifier)
            else { continue }

            found.append(Target(displayName: ApplicationSearch.displayName(at: bundleURL),
                                domain: identifier,
                                key: sparkleKey,
                                suppressedValue: .bool(false),
                                mechanism: "Sparkle"))
        }

        // Figma reads its own plist before consulting anything else, and the
        // user-level file overrides the system one. Verified by reading the
        // asar: a plain `defaults write` is all it takes, so Figma needs no
        // endpoint blocking and no privileges.
        if ApplicationSearch.isInstalled(bundleIdentifier: "com.figma.Desktop") {
            found.append(Target(displayName: "Figma",
                                domain: "com.figma.Desktop",
                                key: "DisableUpdater",
                                suppressedValue: .bool(true),
                                mechanism: "Figma"))
        }

        // Google Chrome. `checkInterval` is Keystone's own documented
        // administrative control, in seconds; 0 means "do not check". It is
        // used here in preference to unloading Google's updater LaunchAgent,
        // which was the original approach and is recorded as rejected in §9:
        // touching launchd churns the Login Items list, and this feature has no
        // business putting anything there.
        // Detected by the browser's own identifier; suppressed through Keystone's,
        // which is a separate component with no bundle of its own.
        if ApplicationSearch.isInstalled(bundleIdentifier: "com.google.Chrome") {
            found.append(Target(displayName: "Google Chrome",
                                domain: "com.google.Keystone.Agent",
                                key: "checkInterval",
                                suppressedValue: .int(0),
                                mechanism: "Keystone"))
        }

        if FileManager.default.fileExists(atPath: mauPath) {
            found.append(Target(displayName: "Microsoft AutoUpdate",
                                domain: mauDomain,
                                key: "HowToCheck",
                                suppressedValue: .string("Manual"),
                                mechanism: "Microsoft AutoUpdate"))
        }

        return found.sorted { $0.displayName < $1.displayName }
    }

    public func discover() -> [CoveredItem] {
        targets().map {
            CoveredItem(id: $0.id,
                        displayName: $0.displayName,
                        mechanism: $0.mechanism,
                        isDeferred: isRunning(domain: $0.domain))
        }
    }

    // MARK: Apply and revert

    @discardableResult
    public func apply(journal: SuppressionJournal,
                      excluding: Set<String> = []) -> SuppressionResult {
        var result = SuppressionResult()

        for target in targets() {
            // Switched off by the user for this app specifically. `revertAll()`
            // runs before every apply pass, so anything excluded since the last
            // pass has already been put back by the time we skip it here.
            if excluding.contains(target.id) { continue }

            let recordTarget = SuppressionRecord.Target.preference(domain: target.domain,
                                                                   key: target.key)
            // Already handled in a previous pass: leave it, and leave the
            // original prior value in the journal. Re-recording here would
            // overwrite it with our own suppressed value and make the revert
            // restore the suppression instead of undoing it.
            if journal.record(for: recordTarget) != nil { continue }

            let current = read(domain: target.domain, key: target.key)

            // Already off, by the user's own choice. Not ours to record, and on
            // revert it must stay off — so touch nothing at all.
            if current == target.suppressedValue { continue }

            // Writing another app's preferences while it runs is unreliable in
            // both directions: cfprefsd may serve the old value, and the app may
            // write its in-memory copy back on quit and erase ours. Queue it —
            // MeteringController retries on termination.
            if isRunning(domain: target.domain) {
                result.deferred.append(target.displayName)
                continue
            }

            do {
                try journal.record(SuppressionRecord(target: recordTarget,
                                                     priorValue: current,
                                                     appliedValue: target.suppressedValue))
            } catch {
                // No durable record means no guaranteed undo, so the change is
                // not made at all.
                result.failed.append(target.displayName)
                continue
            }

            write(target.suppressedValue, domain: target.domain, key: target.key)
            result.applied.append(target.displayName)
        }

        return result
    }

    public func revert(journal: SuppressionJournal) {
        for record in journal.records {
            guard case .preference(let domain, let key) = record.target else { continue }
            let current = read(domain: domain, key: key)

            // Somebody changed it after we did. Their decision wins; ours is
            // simply forgotten.
            if SuppressionJournal.revertible(record, currentValue: current) {
                write(record.priorValue, domain: domain, key: key)
            }
            journal.clear(record.target)
        }
    }

    // MARK: Preference access

    public func read(domain: String, key: String) -> SuppressedValue {
        let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString)
        return SuppressedValue(plist: value)
    }

    public func write(_ value: SuppressedValue, domain: String, key: String) {
        // `nil` removes the key, which is what restoring `absent` has to mean:
        // an app that has never been given the flag should not end up holding an
        // explicit `true` it never had.
        CFPreferencesSetAppValue(key as CFString,
                                 value.plistValue as CFPropertyList?,
                                 domain as CFString)
        CFPreferencesAppSynchronize(domain as CFString)
    }

    private func isRunning(domain: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: domain).isEmpty
    }
}
