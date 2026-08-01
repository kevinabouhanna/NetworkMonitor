import AppKit
import Combine
import Foundation

/// Drives the menu bar title and the popover.
///
/// Runs two independent sampling loops on purpose:
///
/// - **Interface counters, every 0.5 s.** Feeds the live menu bar rate and the
///   authoritative day total. One `sysctl` call, negligible cost, and fast
///   enough to feel real-time.
/// - **nettop, every 1 s.** Feeds per-app attribution. 1 s is nettop's floor.
///   Runs continuously, for the whole life of the app: on a pipe it costs 0.70% of
///   a core, so there is nothing left to switch off. It used to be gated on power
///   and popover visibility because the pseudo-terminal transport cost ~1.36
///   cores — see `NettopStream.spawn()` — and that gating is what made per-app
///   totals disagree with the header.
///
/// Accumulation continues whether or not the popover is open; only the list
/// *rendering* is gated on visibility.
public final class MonitorViewModel: ObservableObject {

    // Published state
    @Published public private(set) var downBytesPerSecond: Double = 0
    @Published public private(set) var upBytesPerSecond: Double = 0
    @Published public private(set) var rows: [UsageRow] = []
    @Published public private(set) var systemRows: [UsageRow] = []
    @Published public private(set) var systemTotal: Int64 = 0
    @Published public private(set) var totalBytesIn: Int64 = 0
    @Published public private(set) var totalBytesOut: Int64 = 0
    @Published public private(set) var isExpensiveNetwork = false

    /// Combined day total. The popover shows one number rather than a
    /// per-direction split; live rates are already in the menu bar.
    public var totalBytes: Int64 { totalBytesIn + totalBytesOut }
    @Published public private(set) var dayStart: Date = Date()
    /// Start of the window `totalBytes` covers. Not the same as `dayStart` since
    /// the counter also restarts when the machine joins a different network.
    @Published public private(set) var countingSince: Date = Date()
    @Published public var systemExpanded = false

    public let store: UsageStore

    private let identityResolver = AppIdentityResolver()
    private let nettop: NettopStream
    private let pathWatcher = NetworkIdentityWatcher()

    private var deltaTracker = InterfaceDeltaTracker()
    private var downSmoother = RateSmoother()
    private var upSmoother = RateSmoother()

    private var sampleTimer: DispatchSourceTimer?
    private var lastSampleTime = MonotonicClock.now()
    private let sampleQueue = DispatchQueue(label: "com.networkmonitor.sampler")

    /// Interval for the interface sampler, from the profile and display state.
    private var sampleInterval: TimeInterval = 0.5
    /// True between `screensDidSleep` and `screensDidWake`.
    private var displayAsleep = false

    /// Popover visibility. Gates list rebuilds so a closed popover costs nothing
    /// beyond accumulation.
    private var popoverIsOpen = false

    /// Row order captured when the popover opens. See `RowOrder`.
    private var rowOrder = RowOrder()

    /// pids seen in the latest nettop sample, for pid-reuse cache eviction.
    private var lastSeenPIDs: Set<Int32> = []

    /// Per-app rate tracking for the "active now" indicator.
    private var lastActivity: [String: Date] = [:]

    private var saveCounter = 0

    /// Sampling rates, chosen from the power source. Published so the popover can
    /// say which one is in force; there is nothing for the user to set.
    @Published public private(set) var profile: PowerProfile = .performance
    private var powerToken: Any?

    public init(store: UsageStore = UsageStore()) {
        self.store = store
        self.dayStart = store.dayStart
        self.countingSince = store.countingSince
        let profile = PowerProfile.forPowerSource(onACPower: PowerSource.isOnACPower)
        self.profile = profile
        self.sampleInterval = profile.interfaceInterval(displayAsleep: false)
        self.nettop = NettopStream(sampleInterval: profile.nettopSampleInterval)
    }

    // MARK: Lifecycle

    public func start() {
        pathWatcher.onChange = { [weak self] fingerprint in
            self?.handleNetworkChange(fingerprint)
        }
        pathWatcher.start()
        // Adopt whatever the watcher already knows so the first tick has a bucket.
        store.setCurrentNetwork(pathWatcher.fingerprint)
        refreshHeader()

        nettop.onSample = { [weak self] sample in
            self?.handleNettopSample(sample)
        }
        nettop.start()
        powerToken = PowerSource.observe { [weak self] in
            self?.applyProfile()
        }

        startSampleTimer()
        observeSystemNotifications()
    }

    /// Re-reads the power source and applies the resulting sampling rates.
    ///
    /// Called on power transitions and on display sleep/wake. Idempotent: the
    /// timer is only rebuilt when its interval actually changes, and `nettop` is
    /// only restarted when its interval does.
    private func applyProfile() {
        let next = PowerProfile.forPowerSource(onACPower: PowerSource.isOnACPower)
        profile = next
        setSampleInterval(next.interfaceInterval(displayAsleep: displayAsleep))
        nettop.setSampleInterval(next.nettopSampleInterval)
    }

    public func stop() {
        sampleTimer?.cancel()
        sampleTimer = nil
        powerToken = nil
        nettop.stop()
        pathWatcher.stop()
        store.save()
    }

    private func startSampleTimer() {
        sampleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
        // Generous leeway lets the kernel coalesce our wakeups with others,
        // which matters for a process that ticks all day on battery.
        timer.schedule(deadline: .now() + sampleInterval,
                       repeating: sampleInterval,
                       leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.sampleInterfaces() }
        timer.resume()
        sampleTimer = timer
    }

    private func observeSystemNotifications() {
        let center = NSWorkspace.shared.notificationCenter

        // Timers do not fire during sleep and counters may have been reset by a
        // link cycle, so re-baseline and check for a missed midnight on wake.
        center.addObserver(forName: NSWorkspace.didWakeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.sampleQueue.async {
                self.deltaTracker.reset()
                self.downSmoother.reset()
                self.upSmoother.reset()
                self.lastSampleTime = MonotonicClock.now()
            }
            self.store.rolloverIfNeeded()
            self.refreshHeader()
        }

        center.addObserver(forName: NSWorkspace.willSleepNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.store.save()
        }

        // The display sleeping relaxes the interface sampler but never `nettop`:
        // see `PowerProfile.nettopSampleInterval` for why only the free one moves.
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.displayAsleep = true
            self?.applyProfile()
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.displayAsleep = false
            self?.applyProfile()
        }
    }

    private func setSampleInterval(_ interval: TimeInterval) {
        guard sampleInterval != interval else { return }
        sampleInterval = interval
        startSampleTimer()
    }

    // MARK: Interface sampling

    private func sampleInterfaces() {
        let snapshots = InterfaceCounters.read()
        let now = MonotonicClock.now()
        let elapsed = now - lastSampleTime
        lastSampleTime = now

        let delta = deltaTracker.accept(snapshots)
        let down = downSmoother.update(bytes: delta.bytesIn, elapsed: elapsed)
        let up = upSmoother.update(bytes: delta.bytesOut, elapsed: elapsed)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.downBytesPerSecond = down
            self.upBytesPerSecond = up
            self.store.recordInterface(bytesIn: delta.bytesIn, bytesOut: delta.bytesOut)

            let bucket = self.store.currentBucket
            self.totalBytesIn = bucket.interfaceBytesIn
            self.totalBytesOut = bucket.interfaceBytesOut

            // Persist roughly every 15 s of ticks rather than on every sample.
            self.saveCounter += 1
            if self.saveCounter >= Int(15 / max(self.sampleInterval, 0.1)) {
                self.saveCounter = 0
                self.store.save()
            }
        }
    }

    // MARK: nettop sampling

    private func handleNettopSample(_ sample: [NettopRow]) {
        // Resolve identities on the main actor: AppIdentityResolver touches
        // NSWorkspace and its caches are not thread-safe.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let now = Date()
            var entries: [(identity: AppIdentity, bytesIn: Int64, bytesOut: Int64)] = []
            var pids = Set<Int32>()
            var merged: [String: (identity: AppIdentity, bytesIn: Int64, bytesOut: Int64)] = [:]

            for row in sample {
                pids.insert(row.pid)
                guard row.bytesIn > 0 || row.bytesOut > 0 else { continue }
                let identity = self.identityResolver.identity(pid: row.pid,
                                                              fallbackName: row.processName)
                // Several helper pids collapse onto one identity; merge before
                // recording so the store sees one entry per app.
                if var existing = merged[identity.key] {
                    existing.bytesIn += row.bytesIn
                    existing.bytesOut += row.bytesOut
                    merged[identity.key] = existing
                } else {
                    merged[identity.key] = (identity, row.bytesIn, row.bytesOut)
                }
                self.lastActivity[identity.key] = now
            }
            entries = Array(merged.values)

            self.lastSeenPIDs = pids
            self.identityResolver.retainOnly(pids: pids)
            self.store.recordApps(entries, now: now)

            if self.popoverIsOpen { self.rebuildRows(now: now) }
        }
    }

    // MARK: Row building

    /// Called when the popover opens, and once per nettop sample while open.
    ///
    /// Visibility no longer starts or stops anything — tracking is continuous, so
    /// the rows are already complete when the popover appears rather than filling
    /// in a second later.
    public func setPopoverOpen(_ open: Bool) {
        popoverIsOpen = open
        // Re-sort fresh on each open, and drop the captured order on close so a
        // reopen reflects whatever accumulated in between.
        rowOrder.reset()
        if open {
            refreshHeader()
            rebuildRows(now: Date())
        } else {
            store.save()
        }
    }

    private func rebuildRows(now: Date) {
        let partitioned = UsageRow.partition(apps: store.currentBucket.apps,
                                             lastActivity: lastActivity,
                                             now: now,
                                             activityWindow: profile.activityWindow)
        rows = rowOrder.apply(to: partitioned.apps)
        systemRows = partitioned.system
        systemTotal = partitioned.systemTotal
    }

    // MARK: Network changes

    private func handleNetworkChange(_ fingerprint: NetworkFingerprint) {
        // Joining a different network restarts its counter; an offline blip and
        // a rejoin resume the same one. The store decides which happened.
        if store.setCurrentNetwork(fingerprint) {
            // These describe the network just left. Kept, the popover would open
            // showing "active now" dots for apps whose bytes have been wiped, and
            // hold a row order captured for rows that no longer exist.
            lastActivity.removeAll()
            rowOrder.reset()
        }
        // Interface counters are per-interface lifetime values; a link change
        // must re-baseline or the gap would land as one huge delta.
        sampleQueue.async { [weak self] in
            self?.deltaTracker.reset()
            self?.downSmoother.reset()
            self?.upSmoother.reset()
            self?.lastSampleTime = MonotonicClock.now()
        }
        refreshHeader()
        if popoverIsOpen { rebuildRows(now: Date()) }
    }

    public func refreshHeader() {
        let bucket = store.currentBucket
        isExpensiveNetwork = store.currentNetwork.isExpensive
        totalBytesIn = bucket.interfaceBytesIn
        totalBytesOut = bucket.interfaceBytesOut
        dayStart = store.dayStart
        countingSince = store.countingSince
    }

    // MARK: Actions

    public func resetCurrentNetwork() {
        store.resetCurrentNetwork()
        lastActivity.removeAll()
        rowOrder.reset()
        refreshHeader()
        rebuildRows(now: Date())
    }

    public func icon(for row: UsageRow) -> NSImage {
        identityResolver.icon(for: AppIdentity(key: row.id,
                                               displayName: row.displayName,
                                               bundlePath: row.bundlePath,
                                               isSystem: row.isSystem))
    }

    /// Two stacked lines, download above upload, at a constant rendered width.
    public var menuBarImage: NSImage {
        MenuBarTitle.image(down: downBytesPerSecond, up: upBytesPerSecond)
    }
}
