import AppKit
import Combine
import Foundation

/// The policy half of hotspot metering: decides *whether* updates should be
/// suppressed right now, and tells the suppressors to make it so.
///
/// Everything the user sees is one switch. Everything underneath it is here.
///
/// The ordering rule that matters most is **replay, re-evaluate, re-apply**.
/// Replaying the journal at launch restores whatever was suppressed when the app
/// last stopped — but doing only that, while still sitting on the hotspot, would
/// hand the user their updates back at the worst possible moment. So the journal
/// is always replayed first, and the current network is then evaluated from
/// scratch.
public final class MeteringController: ObservableObject {

    /// The one setting. Off by default: a fresh install must not start changing
    /// other applications' preferences before anyone has asked it to.
    @Published public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            evaluate()
        }
    }

    /// True when the setting is on *and* the current connection is metered.
    @Published public private(set) var isSuppressing = false
    /// Why the current connection was judged metered or not.
    @Published public private(set) var verdict: MeteredHeuristic.Verdict = .unmetered
    /// Names of what is suppressed right now, for the popover.
    @Published public private(set) var suppressed: [String] = []
    /// Names queued because their app is running.
    @Published public private(set) var deferred: [String] = []
    /// Names that were attempted and refused.
    ///
    /// Published because `applyAll` used to compute this and throw it away, so a
    /// tier that failed every call — a stale sudoers rule after a rename, an
    /// unwritable domain — still had its apps listed as covered. Coverage claimed
    /// from a file existing rather than from a call succeeding is the kind of
    /// wrong that is worse than saying nothing.
    @Published public private(set) var failed: [String] = []

    /// Ids the user has switched off individually, inside an otherwise-on
    /// feature. Empty by default: turning the parent setting on means "all of
    /// them" until the user says otherwise.
    @Published public private(set) var excluded: Set<String> = []

    public static let enabledKey = "meteringEnabled"
    public static let excludedKey = "meteringExcludedItems"

    private let store: UsageStore
    private let journal: SuppressionJournal
    private let suppressors: [UpdateSuppressor]
    private let defaults: UserDefaults

    private var observers: [NSObjectProtocol] = []

    public init(store: UsageStore,
                journal: SuppressionJournal = SuppressionJournal(),
                suppressors: [UpdateSuppressor] = [PreferenceSuppressor(),
                                                   ConfigFileSuppressor(),
                                                   PrivilegedSuppressor()],
                defaults: UserDefaults = .standard) {
        self.store = store
        self.journal = journal
        self.suppressors = suppressors
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        self.excluded = Set(defaults.stringArray(forKey: Self.excludedKey) ?? [])
    }

    // MARK: Lifecycle

    /// Restores anything left suppressed by a previous run, then decides afresh.
    public func start() {
        revertAll()
        observeApplicationExits()
        evaluate()
    }

    public func stop() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    /// Lifts every suppression and empties the journal.
    ///
    /// Called at launch, when the setting is switched off, when the connection
    /// stops being metered, and by `uninstall.sh` through
    /// `--revert-metering` before the bundle is deleted.
    public func revertAll() {
        for suppressor in suppressors {
            suppressor.revert(journal: journal)
        }
        journal.clearAll()
        isSuppressing = false
        suppressed = []
        deferred = []
        failed = []
    }

    // MARK: Policy

    /// Recomputes the verdict for the current network and applies or lifts
    /// suppression to match. Safe to call as often as anything changes.
    public func evaluate() {
        // Offline is a gap, not a place — the same rule `UsageStore.isSwitch`
        // already follows, and this is the metering half of it.
        //
        // `NetworkFingerprint.offline` carries no gateway and `isExpensive:
        // false`, so it scores `.unmetered` and would take the revert branch
        // below. That is wrong in the one situation this feature exists for: a
        // phone hotspot drops every time the phone sleeps, so each blip would
        // lift every suppression and re-apply it seconds later — rewriting every
        // Sparkle app's preferences and the user's `settings.json` each time,
        // and leaving the reconnect window unsuppressed. That window is the
        // worst possible moment to be uncovered, because a check that was queued
        // while the link was down fires the instant it returns.
        //
        // Holding the previous verdict is also what keeps the settings pane from
        // flickering "This connection isn't metered" during a two-second dropout.
        guard store.currentNetwork.id != NetworkFingerprint.offline.id else { return }

        var signals = store.currentNetwork.signals
        signals.userOverride = store.currentMeteredOverride
        verdict = MeteredHeuristic.verdict(for: signals)

        let shouldSuppress = isEnabled && verdict.isMetered
        if shouldSuppress {
            applyAll()
        } else if isSuppressing || !journal.isEmpty {
            revertAll()
        }
    }

    /// Called by `MonitorViewModel` on every identified network change.
    public func networkDidChange() { evaluate() }

    /// Re-checks everything, for when the world changed outside this app.
    ///
    /// Installing the privileged helper is the case that needs it. `evaluate()`
    /// only runs on a network change or a setting being toggled, so a helper
    /// installed mid-session did nothing at all until the next hotspot — while
    /// the settings pane, which reads coverage from the filesystem, had already
    /// started listing macOS and Claude as paused. Opening Settings now re-asserts,
    /// which is both when the user would look and the only moment this costs
    /// anything: `applyAll` rescans `/Applications`, so it must not be on a timer.
    public func refresh() { evaluate() }

    /// Switches one app in or out of the feature.
    ///
    /// `revertAll()` first, unconditionally, because switching an app *off* has
    /// to put that app back — and the journal is the only record of what its
    /// prior value was. Reverting everything and re-applying what remains is the
    /// same replay-then-re-apply shape `start()` uses, and it means this path has
    /// no separate "undo one item" code to get wrong.
    public func setSuppressionEnabled(_ isOn: Bool, for id: String) {
        let updated = isOn ? excluded.subtracting([id]) : excluded.union([id])
        guard updated != excluded else { return }
        excluded = updated
        defaults.set(Array(updated).sorted(), forKey: Self.excludedKey)
        revertAll()
        evaluate()
    }

    /// Whether this app is included in the feature. Toggles bind to this.
    public func isSuppressionEnabled(for id: String) -> Bool {
        !excluded.contains(id)
    }

    /// Called when the user marks the current network metered or not.
    public func setOverride(_ value: Bool?) {
        store.setMeteredOverride(value, for: store.currentNetwork.id)
        evaluate()
    }

    private func applyAll() {
        var result = SuppressionResult()
        for suppressor in suppressors {
            result = result + suppressor.apply(journal: journal, excluding: excluded)
        }

        isSuppressing = true
        // Accumulated from the journal rather than from this pass: a re-assert
        // reports only what it re-did, and the list should keep naming
        // everything currently held down.
        suppressed = journalNames()
        deferred = result.deferred
        failed = result.failed
    }

    /// Names for what is currently held down.
    ///
    /// Looked up from the suppressors' own `discover()` output rather than
    /// inferred from the journal target. Guessing an app from its preference
    /// domain is what put `com.google.Keystone.Agent` in the settings pane:
    /// Chrome's updater is a separate component with no `.app` of its own, so
    /// `urlForApplication(withBundleIdentifier:)` found nothing and the raw
    /// reverse-DNS string fell through to the UI. The suppressor already knows it
    /// is called "Google Chrome"; asking it is both correct and cheaper.
    private func journalNames() -> [String] {
        let namesByID = Dictionary(
            coverage().flatMap(\.items).map { ($0.id, $0.displayName) },
            uniquingKeysWith: { first, _ in first })

        var names: Set<String> = []
        for record in journal.records {
            switch record.target {
            case .preference(let domain, let key):
                names.insert(namesByID["\(domain)/\(key)"]
                             ?? Self.appName(forBundleIdentifier: domain)
                             ?? domain)
            case .configFile(let path, let key):
                names.insert(namesByID["\(path)/\(key)"]
                             ?? URL(fileURLWithPath: path).lastPathComponent)
            case .systemPreference:
                names.insert("macOS and in-app updaters")
            }
        }
        return names.sorted()
    }

    static func appName(forBundleIdentifier identifier: String) -> String? {
        guard let url = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: identifier) else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }

    // MARK: Deferred writes

    /// A preference write is skipped while its app is running, because the app
    /// may write its in-memory copy back on quit and erase ours. Watching for
    /// termination is what turns "skipped" into "applied a moment later".
    private func observeApplicationExits() {
        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in
                // Gated on there being a queued write. Without this, every app
                // the user quits triggers a full pass — which rescans every
                // bundle in /Applications for no reason at all.
                guard let self, self.isSuppressing, !self.deferred.isEmpty else { return }
                self.applyAll()
            }
        observers.append(token)
    }

    // MARK: Coverage

    /// What each suppressor can reach, for the "what's covered" list.
    public func coverage() -> [(suppressor: String, items: [CoveredItem])] {
        suppressors.map { ($0.name, $0.discover()) }
    }

    /// One row per independently switchable unit, for the settings list.
    public struct ToggleItem: Identifiable, Equatable {
        public var id: String
        /// What the row is called.
        public var label: String
        /// Secondary line — the mechanism, or the apps a whole-tier row covers.
        public var detail: String
        /// The write is queued until the app quits.
        public var isDeferred: Bool
        /// True when this row stands for a whole tier that can only be switched
        /// together, so the UI knows to show `detail` and name what it covers.
        public var isGroup: Bool
    }

    /// Collapses `coverage()` into rows the user can actually toggle.
    ///
    /// The grouping matters: `PrivilegedSuppressor` reports six applications that
    /// all share one id, because the helper's `suppress` verb takes no arguments
    /// and covers everything it knows or nothing. Rendering six switches that all
    /// move together would be a lie about the granularity on offer, so they
    /// collapse into a single row named after the tier.
    ///
    /// **Not cheap** — `discover()` walks `/Applications` reading Info.plists —
    /// so call it when a view appears, never from inside `body`.
    public func toggleItems() -> [ToggleItem] {
        var rows: [ToggleItem] = []
        for (name, items) in coverage() where !items.isEmpty {
            let ids = Set(items.map(\.id))
            if ids.count == 1 && items.count > 1 {
                rows.append(ToggleItem(
                    id: items[0].id,
                    label: name,
                    detail: items.map(\.displayName).joined(separator: ", "),
                    isDeferred: false,
                    isGroup: true))
            } else {
                rows.append(contentsOf: items.map {
                    ToggleItem(id: $0.id,
                               label: $0.displayName,
                               detail: $0.mechanism,
                               isDeferred: $0.isDeferred,
                               isGroup: false)
                })
            }
        }
        return rows.sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    /// Whether the privileged helper is installed.
    ///
    /// Surfaced rather than hidden because without it the single largest thing
    /// a hotspot can be charged for — a macOS update — is not covered, and a
    /// metering feature that quietly misses the biggest item is worse than one
    /// that says so.
    public var helperInstalled: Bool { PrivilegedSuppressor.isInstalled }

    /// Whether the helper's hourly `self-heal` job is installed alongside it.
    ///
    /// Only meaningful when `helperInstalled`. False is a deliberate choice made
    /// at install time, not a fault — see `PrivilegedSuppressor.selfHealInstalled`.
    public var selfHealInstalled: Bool { PrivilegedSuppressor.selfHealInstalled }

    /// Applications covered only via the helper, for the settings pane.
    public var privilegedCoverage: [String] {
        PrivilegedSuppressor.coveredApplications.map(\.app)
    }
}
