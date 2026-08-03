import Foundation

/// Tiers D and E: macOS system updates, App Store updates, and the applications
/// that download updates inside their own process.
///
/// Everything here goes through the root helper, and this class does almost
/// nothing itself — it runs one of three fixed verbs and reads the result. That
/// asymmetry is deliberate. The helper owns the list of preference keys and the
/// list of blocked hostnames precisely so that this side, which is the side an
/// attacker could reach, has no way to express "block something else".
///
/// If the helper is not installed, every method here is a no-op that reports
/// itself as unavailable. Hotspot metering still works without it — tiers A, A′
/// and C need no privileges at all — it simply does not cover the largest item.
public final class PrivilegedSuppressor: UpdateSuppressor {

    public let name = "macOS and in-app updaters"

    public static let helperPath =
        "/Library/PrivilegedHelperTools/com.kevinabouhanna.NetworkMonitor.helper"
    /// No dot in the filename: `sudo` skips any file in `sudoers.d` containing
    /// one, so a reverse-DNS name would be silently ignored.
    static let sudoersPath = "/etc/sudoers.d/networkmonitor"

    /// The LaunchDaemon that runs `self-heal` at boot and hourly.
    static let daemonPath =
        "/Library/LaunchDaemons/com.kevinabouhanna.NetworkMonitor.helper.plist"

    /// Whether the hourly `self-heal` job is installed.
    ///
    /// Separate from `isInstalled` because `install-helper.sh --no-daemon` is a
    /// supported arrangement, not a broken one: the daemon is the only piece of
    /// this helper that shows up as a background item, so leaving it out keeps
    /// NetworkMonitor the sole Login Items row. What it costs is the safety net
    /// for the one uninstall route no script can intercept — dragging the bundle
    /// to the Trash — so the settings pane says so rather than leaving the user
    /// to discover it by finding their updates still off months later.
    ///
    /// Read from the filesystem rather than remembered from install time: the
    /// plist is world-readable, so this needs no privileges and cannot drift out
    /// of step with what is actually installed.
    public static var selfHealInstalled: Bool {
        FileManager.default.fileExists(atPath: daemonPath)
    }

    /// Mirrors the helper's compiled-in list, for display only. The helper does
    /// not take this as input — it cannot be told to block anything else.
    public static let coveredApplications = [
        (app: "macOS software updates", mechanism: "System setting"),
        (app: "App Store updates", mechanism: "System setting"),
        (app: "Claude", mechanism: "Managed policy"),
        (app: "Slack", mechanism: "Managed policy"),
        (app: "Canva", mechanism: "Update endpoint"),
        // Figma is covered twice over: its own `DisableUpdater` preference is the
        // primary lever, but that write is deferred while Figma is running — which
        // it usually is — so the helper also blocks its update endpoint. Listed
        // here because that second mechanism edits /etc/hosts, and this list is
        // what the settings pane reports.
        (app: "Figma", mechanism: "Update endpoint"),
    ]

    public init() {}

    /// True when the helper binary and its sudoers rule are both present.
    ///
    /// Both, not either: the binary without the rule cannot be invoked, and the
    /// rule without the binary grants nothing. Reporting "installed" on half of
    /// it would make the settings pane claim coverage that does not exist.
    public static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: helperPath)
            && FileManager.default.fileExists(atPath: sudoersPath)
    }

    public var isInstalled: Bool { Self.isInstalled }

    /// One id for the whole tier.
    ///
    /// The helper takes no arguments — `suppress` covers everything it knows or
    /// nothing at all — so there is no per-app granularity to offer here, and
    /// pretending otherwise in the UI would give the user switches that silently
    /// did nothing. Splitting this would mean new verbs in a root binary.
    public static let tierID = "privileged/all"

    public func discover() -> [CoveredItem] {
        guard Self.isInstalled else { return [] }
        return Self.coveredApplications.map {
            CoveredItem(id: Self.tierID,
                        displayName: $0.app,
                        mechanism: $0.mechanism)
        }
    }

    @discardableResult
    public func apply(journal: SuppressionJournal,
                      excluding: Set<String> = []) -> SuppressionResult {
        var result = SuppressionResult()
        guard Self.isInstalled, !excluding.contains(Self.tierID) else { return result }

        let target = SuppressionRecord.Target.systemPreference(
            domain: "com.apple.SoftwareUpdate", key: "helper")

        // The prior values live root-side, in the helper's own state file, so
        // that they survive this app being deleted. This record only says "the
        // helper is currently holding something down", which is what the app
        // needs in order to know it must be released.
        if journal.record(for: target) == nil {
            do {
                try journal.record(SuppressionRecord(target: target,
                                                     priorValue: .absent,
                                                     appliedValue: .string("suppressed")))
            } catch {
                result.failed.append("macOS updates")
                return result
            }
        }

        if runHelper("suppress") {
            result.applied.append("macOS updates")
        } else {
            journal.clear(target)
            result.failed.append("macOS updates")
        }
        return result
    }

    public func revert(journal: SuppressionJournal) {
        for record in journal.records {
            guard case .systemPreference = record.target else { continue }
            // Attempted even if the helper looks absent: a half-removed install
            // is exactly when something could be left switched off.
            _ = runHelper("restore")
            journal.clear(record.target)
        }
    }

    /// Current state as the helper reports it, for the settings pane.
    public func status() -> [String: Any]? {
        guard Self.isInstalled,
              let output = runHelperCapturing("status"),
              let data = output.data(using: .utf8)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: Invocation

    /// `sudo -n` — never interactive.
    ///
    /// If the sudoers rule is missing or malformed, `-n` fails immediately
    /// rather than blocking a menu bar app on a password prompt that has no
    /// terminal to appear in. A failure here is reported as uncovered, not
    /// retried.
    @discardableResult
    private func runHelper(_ verb: String) -> Bool {
        runHelperCapturing(verb) != nil
    }

    private func runHelperCapturing(_ verb: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n", Self.helperPath, verb]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
