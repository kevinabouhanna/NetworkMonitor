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

    /// Low Data Mode as it stands right now. See `LowDataModeSuppressor.State`.
    @Published public private(set) var lowDataMode: LowDataModeSuppressor.State = .off
    /// Whether the helper can do Low Data Mode at all, so Settings can say
    /// "reinstall the helper" instead of showing a switch that does nothing.
    @Published public private(set) var lowDataModeAvailability:
        LowDataModeSuppressor.Availability = .helperMissing
    /// True when macOS itself reports the connection as constrained while we
    /// hold it — `NWPath`, not just `ifconfig`, agrees. The difference matters:
    /// the flag being up is our claim; this is the system acting on it.
    @Published public private(set) var lowDataModeConfirmed = false
    /// Updates that arrived anyway on the current, or last, metered connection,
    /// big enough to be updates rather than checks. See `UpdateWatch`.
    @Published public private(set) var updatesGotThrough: [UpdateWatch.Sighting] = []

    public static let enabledKey = "meteringEnabled"
    public static let excludedKey = "meteringExcludedItems"

    private let store: UsageStore
    private let journal: SuppressionJournal
    private let suppressors: [UpdateSuppressor]
    private let defaults: UserDefaults
    private let ownership: InterfaceFlagOwnership
    private let updateWatch: UpdateWatch

    private var observers: [NSObjectProtocol] = []

    public init(store: UsageStore,
                journal: SuppressionJournal = SuppressionJournal(),
                suppressors: [UpdateSuppressor] = [PreferenceSuppressor(),
                                                   ConfigFileSuppressor(),
                                                   UpdateFolderSuppressor(),
                                                   PrivilegedSuppressor(),
                                                   LowDataModeSuppressor()],
                defaults: UserDefaults = .standard,
                ownership: InterfaceFlagOwnership = .shared,
                updateWatch: UpdateWatch? = nil) {
        self.store = store
        self.journal = journal
        self.suppressors = suppressors
        self.defaults = defaults
        self.ownership = ownership
        self.updateWatch = updateWatch ?? UpdateWatch(defaults: defaults)
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        self.excluded = Set(defaults.stringArray(forKey: Self.excludedKey) ?? [])
        self.updatesGotThrough = self.updateWatch.reportable
    }

    private var lowData: LowDataModeSuppressor? {
        suppressors.lazy.compactMap { $0 as? LowDataModeSuppressor }.first
    }

    // MARK: Lifecycle

    /// Restores anything left suppressed by a previous run, then decides afresh.
    public func start() {
        revertAll()
        observeApplicationExits()
        evaluate()
    }

    /// Called on quit.
    ///
    /// Everything else stays suppressed — see `MonitorViewModel.stop` — but Low
    /// Data Mode is let go of. It is the one change whose effect is machine-wide
    /// rather than per-app, it is re-applied in a single call at the next launch,
    /// and once nothing is watching the network nothing would lift it when the
    /// Mac moves on to home Wi-Fi with the same interface: iCloud would stay
    /// paused there until a restart.
    public func stop() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        lowData?.revert(journal: journal)
        publishLowDataMode()
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

        // Our own Low Data Mode flags are not evidence. See
        // `InterfaceFlagOwnership` for the loop this prevents.
        var signals = ownership.masking(store.currentNetwork.signals,
                                        on: store.currentNetwork.interfaceName)
        signals.userOverride = store.currentMeteredOverride
        verdict = MeteredHeuristic.verdict(for: signals)

        let shouldSuppress = isEnabled && verdict.isMetered
        if shouldSuppress {
            applyAll()
        } else {
            // A release the helper has not confirmed leaves nothing in the
            // journal, so an empty journal is not enough to stop trying.
            if isSuppressing || !journal.isEmpty
                || suppressors.contains(where: { $0.holdsUnreleasedState }) {
                revertAll()
            }
            // Here rather than in `revertAll`, which also runs when one app is
            // switched off mid-hotspot — and that must not end the report.
            updateWatch.end()
        }
        publishLowDataMode()
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
    ///
    /// It is also when Low Data Mode's availability is asked again, which is how
    /// a helper reinstalled to gain the new verbs is noticed without a relaunch.
    public func refresh() {
        refreshHelperState()
        lowData?.refreshAvailability()
        evaluate()
    }

    /// What Settings › Hotspot lists.
    public struct Listing {
        public var items: [ToggleItem]
        public var uncovered: [UpdaterScan.Finding]
    }

    /// `refresh()`, and the two lists Settings › Hotspot shows, with the slow
    /// parts off the main thread (#65). `done` gets the lists on the main thread,
    /// after the re-check.
    ///
    /// On the main thread they held the pane back from appearing for 250–520
    /// ms: asking the helper launched it twice, about 100 ms and 160 ms, for the
    /// same `status` answer, and the scans walk the apps on this Mac, about 50
    /// ms (220 ms the first time). Here the helper is asked once.
    ///
    /// Low Data Mode is left out of the scan: it isn't an app, so it has no row,
    /// and its `discover()` can update its own cached state, which belongs to the
    /// main thread. Everything else only reads files and preferences.
    public func refreshInBackground(_ done: @escaping (Listing) -> Void) {
        let appSuppressors = suppressors.filter { !($0 is LowDataModeSuppressor) }
        DispatchQueue.global(qos: .userInitiated).async {
            let status = PrivilegedSuppressor.isInstalled ? PrivilegedSuppressor.invoke("status") : nil
            let coverage = appSuppressors.map { ($0.name, $0.discover()) }
            let listing = Listing(items: Self.toggleRows(coverage),
                                  uncovered: UpdaterScan.uncovered(UpdaterScan.findings(),
                                                                   by: coverage.flatMap(\.1)))
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let state = HelperInstaller.state(status: status)
                if state != self.helperState { self.helperState = state }
                self.lowData?.refreshAvailability(status: status)
                self.evaluate()
                done(listing)
            }
        }
    }

    // MARK: The helper

    /// Whether the helper is installed and new enough. Refreshed by `refresh()`
    /// and after every install attempt.
    @Published public private(set) var helperState: HelperInstaller.State = .missing

    /// The app build that last offered to install or update the helper on its
    /// own, without being asked.
    public static let helperOfferedKey = "helperOfferedForBuild"

    /// Installs or updates the helper when the feature needs it, behind one
    /// administrator prompt.
    ///
    /// `userAsked` is true when the user has just switched the feature on or
    /// pressed Allow: ask now. False is the check at launch, for the first run
    /// of a new version whose helper is newer than the installed one: ask once
    /// per build and never again if the answer was no — Settings keeps offering
    /// it, and the parts that need no helper carry on regardless.
    @discardableResult
    public func ensureHelper(userAsked: Bool) -> HelperInstaller.Outcome? {
        refreshHelperState()
        guard isEnabled, helperState != .current, HelperInstaller.canInstall else { return nil }
        if !userAsked {
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            guard defaults.string(forKey: Self.helperOfferedKey) != build else { return nil }
            defaults.set(build, forKey: Self.helperOfferedKey)
        }
        let outcome = HelperInstaller.install()
        // Re-asserted with the new helper in place: the privileged tier and Low
        // Data Mode both start working on the spot rather than at the next
        // network change.
        refresh()
        if outcome == .waitingForApproval { watchForApproval() }
        return outcome
    }

    private func refreshHelperState() {
        let state = HelperInstaller.state()
        if state != helperState { helperState = state }
    }

    private var approvalWatch: Timer?

    /// While the daemon waits to be switched on in System Settings (#131),
    /// look every few seconds, and once it's on, put it to work at once.
    public func watchForApproval() {
        guard approvalWatch == nil else { return }
        approvalWatch = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.refreshHelperState()
            guard self.helperState != .waitingForApproval else { return }
            timer.invalidate()
            self.approvalWatch = nil
            self.refresh()
        }
    }

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

        // Idempotent per network: only the first pass on a connection starts a
        // report and snapshots what the caches already hold.
        updateWatch.begin(networkID: store.currentNetwork.id)
        publishSightings()
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
            case .lowDataMode:
                names.insert("Low Data Mode")
            case .folder(_, let app):
                names.insert(app)
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
        /// One app a whole-tier row stands for.
        public struct Member: Equatable, Identifiable {
            public var id: String { name }
            public var name: String
            public var effect: String
        }

        public var id: String
        /// What the row is called.
        public var label: String
        /// What pausing it does, in plain words, shown under the label. Empty
        /// for a whole-tier row, whose members each say their own.
        public var effect: String
        /// How it is reached, for the diagnostic report.
        public var mechanism: String
        /// The apps a row that stands for a whole tier covers. Empty for a row
        /// that is one app.
        public var members: [Member] = []

        /// True when this row stands for a whole tier that can only be switched
        /// together, so the UI lists what it covers.
        public var isGroup: Bool { !members.isEmpty }
    }

    /// Collapses `coverage()` into rows the user can actually toggle.
    ///
    /// The grouping matters: `PrivilegedSuppressor` reports every application it
    /// covers under one id, because the helper's `suppress` verb takes no arguments
    /// and covers everything it knows or nothing. Rendering a switch for each, all
    /// moving together, would be a lie about the granularity on offer, so they
    /// collapse into a single row named after the tier.
    ///
    /// **Not cheap** — `discover()` walks `/Applications` reading Info.plists —
    /// so call it when a view appears, never from inside `body`.
    public func toggleItems() -> [ToggleItem] {
        Self.toggleRows(coverage())
    }

    private static func toggleRows(_ coverage: [(suppressor: String, items: [CoveredItem])]) -> [ToggleItem] {
        var rows: [ToggleItem] = []
        for (name, all) in coverage {
            // Low Data Mode is not an app; the feature's own switch covers it.
            let items = all.filter { $0.id != LowDataModeSuppressor.itemID }
            guard !items.isEmpty else { continue }
            let ids = Set(items.map(\.id))
            if ids.count == 1 && items.count > 1 {
                rows.append(ToggleItem(
                    id: items[0].id,
                    label: name,
                    effect: "",
                    mechanism: "",
                    members: items.map {
                        ToggleItem.Member(name: $0.displayName, effect: $0.effect)
                    }))
            } else {
                rows.append(contentsOf: items.map {
                    ToggleItem(id: $0.id,
                               label: $0.displayName,
                               effect: $0.effect,
                               mechanism: $0.mechanism)
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

    // MARK: What is not covered

    /// Installed apps that update themselves by a route nothing here reaches.
    ///
    /// Without the helper this includes the apps only the helper covers —
    /// Claude and Slack — which is the honest answer: on this Mac, right now,
    /// they are not covered.
    ///
    /// **Not cheap**, for the same reason as `toggleItems()`: call it when a
    /// view appears.
    public func uncoveredUpdaters() -> [UpdaterScan.Finding] {
        UpdaterScan.uncovered(UpdaterScan.findings(), by: coverage().flatMap(\.items))
    }

    /// One nettop row's bytes, for a process named like an updater. Called by
    /// `MonitorViewModel` per sample; ignored unless a metered connection is
    /// being watched.
    public func noteUpdaterTraffic(processName: String, appName: String?, bytes: Int64) {
        guard isSuppressing else { return }
        if updateWatch.recordTraffic(processName: processName, appName: appName,
                                     bytes: bytes) {
            publishSightings()
        }
    }

    /// One sample's internet bytes for an app, by its bundle path, so an
    /// update that downloads in the app's own process is measured by what it
    /// used (#95). Ignored unless a metered connection is being watched.
    public func noteAppTraffic(bundlePath: String, bytes: Int64, now: Date = Date()) {
        guard isSuppressing else { return }
        updateWatch.recordApp(bundlePath: bundlePath, bytes: bytes, now: now)
    }

    /// Once per nettop sample. Looks at the updater caches when due; see
    /// `UpdateWatch.scanInterval`.
    public func tick(now: Date = Date()) {
        guard isSuppressing else { return }
        if updateWatch.tick(now: now) { publishSightings() }
    }

    /// Everything above, as plain text for `--metering-report`. Reads only: no
    /// evaluation, no suppressor applied or reverted, and the one helper call it
    /// can make is `status`.
    public func diagnosticReport() -> String {
        var lines: [String] = []
        func section(_ title: String) { lines.append(""); lines.append(title) }

        lines.append("Hotspot metering: \(isEnabled ? "on" : "off")")

        section("Low Data Mode")
        if let lowData {
            switch lowData.refreshAvailability() {
            case .available:      lines.append("  helper: ready")
            case .helperMissing:  lines.append("  helper: not installed (Settings › Allow…)")
            case .helperOutdated: lines.append("  helper: too old for Low Data Mode (Settings › Allow…)")
            }
            if let hold = ownership.hold {
                lines.append("  held on \(hold.interface): " + [
                    hold.setConstrained ? "constrained" : nil,
                    hold.setExpensive ? "expensive" : nil,
                ].compactMap { $0 }.joined(separator: ", "))
            } else {
                lines.append("  holding nothing")
            }
        }
        if let primary = InterfaceProbe.primaryInterface() {
            let flags = InterfaceProbe.flags(on: primary)
            lines.append("  \(primary) now: constrained \(flags?.constrained == true ? "yes" : "no"), "
                         + "expensive \(flags?.expensive == true ? "yes" : "no")")
        }

        section("Covered")
        for row in toggleItems() {
            let detail = row.isGroup
                ? row.members.map(\.name).joined(separator: ", ") : row.mechanism
            lines.append("  \(row.label) — \(detail)")
        }

        section("Not covered")
        let uncovered = uncoveredUpdaters()
        if uncovered.isEmpty { lines.append("  nothing found") }
        for finding in uncovered {
            lines.append("  \(finding.displayName) — \(finding.mechanism.rawValue)")
        }

        // What `UpdateWatch` would see: every payload staged right now, on any
        // network. Evidence that the staging places are the right ones, and a
        // list of updates already downloaded and waiting to install.
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let staged = UpdateCaches.payloads(in: caches)
        if !staged.isEmpty {
            section("Downloaded updates waiting to install")
            let dates = DateFormatter()
            dates.dateStyle = .medium
            dates.timeStyle = .short
            for payload in staged.sorted(by: { $0.modified > $1.modified }) {
                let name = UpdateWatch.resolveInstalledOwner(payload.owner)
                let bytes = ByteFormat.bytes(UpdateCaches.size(of: payload.path))
                lines.append("  \(name) — \(bytes), \(dates.string(from: payload.modified))")
            }
        }

        if !updatesGotThrough.isEmpty {
            section("Got through on the last metered connection")
            for sighting in updatesGotThrough {
                lines.append("  \(sighting.name) — \(ByteFormat.bytes(sighting.bytes))")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Publishing

    /// Assigned only on change: Settings and the popover both observe this
    /// object, and `evaluate()` runs on every path update.
    private func publishSightings() {
        let next = updateWatch.reportable
        if next != updatesGotThrough { updatesGotThrough = next }
    }

    private func publishLowDataMode() {
        guard let lowData else { return }
        let availability = lowData.availability
        if availability != lowDataModeAvailability { lowDataModeAvailability = availability }
        if lowData.state != lowDataMode { lowDataMode = lowData.state }

        var confirmed = false
        if case .on(let interface) = lowData.state {
            confirmed = store.currentNetwork.interfaceName == interface
                && store.currentNetwork.isConstrained
        }
        if confirmed != lowDataModeConfirmed { lowDataModeConfirmed = confirmed }
    }
}
