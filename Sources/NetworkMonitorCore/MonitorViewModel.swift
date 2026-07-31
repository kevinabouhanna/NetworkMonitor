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
    @Published public var systemExpanded = false

    public let store: UsageStore

    private let identityResolver = AppIdentityResolver()
    private let nettop = NettopStream()
    private let pathWatcher = NetworkIdentityWatcher()

    private var deltaTracker = InterfaceDeltaTracker()
    private var downSmoother = RateSmoother()
    private var upSmoother = RateSmoother()

    private var sampleTimer: DispatchSourceTimer?
    private var lastSampleTime = MonotonicClock.now()
    private let sampleQueue = DispatchQueue(label: "com.networkmonitor.sampler")

    /// Interval for the interface sampler. Relaxed while the display sleeps —
    /// nobody is reading the menu bar, but totals must keep accumulating.
    private var sampleInterval: TimeInterval = 0.5

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

    /// Controls when the expensive `nettop` stream runs. See `PerAppTrackingMode`.
    @Published public private(set) var trackingMode: PerAppTrackingMode = .pluggedIn
    /// True while per-app attribution is actually being collected.
    @Published public private(set) var isTrackingPerApp = false
    private var powerToken: Any?
    private static let trackingModeKey = "perAppTrackingMode"

    public init(store: UsageStore = UsageStore()) {
        self.store = store
        self.dayStart = store.dayStart
        if let raw = UserDefaults.standard.string(forKey: Self.trackingModeKey),
           let mode = PerAppTrackingMode(rawValue: raw) {
            trackingMode = mode
        }
    }

    public func setTrackingMode(_ mode: PerAppTrackingMode) {
        trackingMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.trackingModeKey)
        updateNettopState()
    }

    /// Starts or stops `nettop` to match the current mode, popover visibility and
    /// power source. Cheap to call repeatedly — `NettopStream.start()` is
    /// idempotent and `stop()` on a stopped stream is a no-op.
    private func updateNettopState() {
        let shouldTrack = trackingMode.shouldTrack(popoverOpen: popoverIsOpen,
                                                  onACPower: PowerSource.isOnACPower)
        guard shouldTrack != isTrackingPerApp else { return }
        isTrackingPerApp = shouldTrack
        if shouldTrack {
            nettop.start()
        } else {
            nettop.stop()
        }
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
        // Started only if the tracking mode calls for it right now.
        updateNettopState()
        powerToken = PowerSource.observe { [weak self] in
            self?.updateNettopState()
        }

        startSampleTimer()
        observeSystemNotifications()
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

        center.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.setSampleInterval(2.0)
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.setSampleInterval(0.5)
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
    public func setPopoverOpen(_ open: Bool) {
        popoverIsOpen = open
        // In the two low-energy modes the popover opening is what starts nettop,
        // so per-app rows fill in about a second after it appears.
        updateNettopState()
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
                                             now: now)
        rows = rowOrder.apply(to: partitioned.apps)
        systemRows = partitioned.system
        systemTotal = partitioned.systemTotal
    }

    // MARK: Network changes

    private func handleNetworkChange(_ fingerprint: NetworkFingerprint) {
        // Switching buckets, not wiping: rejoining a network restores its total.
        store.setCurrentNetwork(fingerprint)
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
    }

    // MARK: Actions

    public func resetCurrentNetwork() {
        store.resetCurrentNetwork()
        lastActivity.removeAll()
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
