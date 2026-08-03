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
/// - **nettop, every 1–3 s** depending on `PowerProfile`. Feeds per-app
///   attribution, and the LAN/internet split that keeps a mirrored screen out of
///   the totals. Runs continuously, for the whole life of the app: 0.55% of a core
///   once its stdin stopped spinning (`NettopStream.spawn()`), so there is nothing
///   left worth switching off. The gating that used to exist is what made per-app
///   totals disagree with the header.
///
/// Accumulation continues whether or not the popover is open; only the list
/// *rendering* is gated on visibility.
public final class MonitorViewModel: ObservableObject {

    /// Live rates for the menu bar, and the signal that they changed.
    ///
    /// Deliberately **not** `@Published`, and that is the whole point.
    /// `MenuBarPopoverView` observes this object and never draws a rate, but
    /// `@ObservedObject` invalidates on *any* `objectWillChange` — so publishing
    /// these re-measured the popover's view tree twice a second, while it was
    /// closed, for two numbers it does not display. `sizingOptions` keeps the
    /// hosting controller measured from launch, so being closed is no defence.
    ///
    /// The rendered-title guard below already spared an idle machine, because
    /// every tick formats to "0 B/s". It did nothing on an active connection —
    /// which is every connection this app is interesting on.
    ///
    /// Sending the subject *after* both assignments also settles a subtlety the
    /// `@Published` version had: those fire in `willSet`, so a synchronous
    /// subscriber read the previous rate and only saw the right one by way of a
    /// `RunLoop.main` hop it then could not remove.
    public private(set) var downBytesPerSecond: Double = 0
    public private(set) var upBytesPerSecond: Double = 0
    public let menuBarRateDidChange = PassthroughSubject<Void, Never>()

    // Published state
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
    /// Ids of app rows whose child breakdown is open. Empty on every popover
    /// open: the breakdown is an answer to "what is inside this app", which is a
    /// question the user asks, not one the list should pre-empt.
    @Published public var expandedApps: Set<String> = []

    public let store: UsageStore
    /// Hotspot metering. Owned here because it has to react to exactly the same
    /// network changes the totals do, and this is where those arrive.
    public let metering: MeteringController

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

    /// Last menu bar title actually published, used to suppress no-op updates.
    private var renderedTitle = ""

    /// Sampling rates, chosen from the power source. Published so the popover can
    /// say which one is in force; there is nothing for the user to set.
    @Published public private(set) var profile: PowerProfile = .performance
    private var powerToken: Any?

    public init(store: UsageStore = UsageStore(),
                metering: MeteringController? = nil) {
        self.store = store
        self.metering = metering ?? MeteringController(store: store)
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

        // After the store has a current network, so the first evaluation judges
        // the connection actually in use rather than `.offline`. `start()`
        // replays any journal left by the previous run before deciding.
        metering.start()

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
        // Suppression is deliberately *not* lifted on quit. Quitting the app is
        // not the same as saying "resume updating" — the user may be quitting to
        // save battery mid-hotspot — and the journal is what makes leaving it in
        // place safe: the next launch replays it, and `uninstall.sh` reverts it.
        metering.stop()
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

            // Notify only when the title actually changes. What this now saves is
            // the menu bar redraw itself — rendering the `NSImage` and handing the
            // new one to the status item, which costs an IPC round trip to
            // WindowServer per change. The popover no longer enters into it: see
            // `downBytesPerSecond` for why those are not `@Published`.
            //
            // The rendered title is the honest key. Two different rates that format
            // to the same two lines produce a byte-identical image, so comparing
            // strings rather than Doubles is what makes the guard bite at all.
            let rendered = MenuBarTitle.string(down: down, up: up)
            if rendered != self.renderedTitle {
                self.renderedTitle = rendered
                self.downBytesPerSecond = down
                self.upBytesPerSecond = up
                self.menuBarRateDidChange.send()
            }

            self.store.recordInterface(bytesIn: delta.bytesIn, bytesOut: delta.bytesOut)

            // Accumulation never stops; only the *publishing* of it waits for
            // someone to be looking. `setPopoverOpen` calls `refreshHeader()`, so
            // the figures are current the instant the popover appears.
            let bucket = self.store.currentBucket
            if self.popoverIsOpen {
                // Internet, not interface: the kernel counted the mirrored screen
                // too, and `internetBytes*` takes it back out.
                if self.totalBytesIn != bucket.internetBytesIn {
                    self.totalBytesIn = bucket.internetBytesIn
                }
                if self.totalBytesOut != bucket.internetBytesOut {
                    self.totalBytesOut = bucket.internetBytesOut
                }
            }

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

            // LAN bytes are summed across the whole sample and handed to the store
            // separately: they never become an app row, but the headline has to
            // know about them to subtract them from the kernel's total.
            var localIn: Int64 = 0, localOut: Int64 = 0

            for row in sample {
                pids.insert(row.pid)
                // Only the unicast part is subtracted from the kernel's total;
                // multicast is excluded from the rows but left in the headline,
                // because its reported size cannot be trusted.
                localIn += row.subtractableLocalIn
                localOut += row.subtractableLocalOut
                // Only internet bytes reach a row. An app that did nothing but talk
                // to a NAS or mirror a screen should not appear at all.
                let bytesIn = row.internetBytesIn, bytesOut = row.internetBytesOut
                guard bytesIn > 0 || bytesOut > 0 else { continue }
                let identity = self.identityResolver.identity(pid: row.pid,
                                                              fallbackName: row.processName)
                // Several helper pids collapse onto one identity; merge before
                // recording so the store sees one entry per app.
                if var existing = merged[identity.key] {
                    existing.bytesIn += bytesIn
                    existing.bytesOut += bytesOut
                    merged[identity.key] = existing
                } else {
                    merged[identity.key] = (identity, bytesIn, bytesOut)
                }
                self.lastActivity[identity.key] = now
            }
            entries = Array(merged.values)

            self.lastSeenPIDs = pids
            self.identityResolver.retainOnly(pids: pids)
            self.store.recordApps(entries,
                                  localBytesIn: localIn, localBytesOut: localOut,
                                  now: now)

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
        expandedApps.removeAll()
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
            expandedApps.removeAll()
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
        // After the store has adopted the new fingerprint, so the verdict is
        // computed against the network just joined.
        metering.networkDidChange()
        if popoverIsOpen { rebuildRows(now: Date()) }
    }

    public func refreshHeader() {
        let bucket = store.currentBucket
        // The badge follows the metering verdict, not `isExpensive` alone, so a
        // USB tether or an unrecognised phone reads as metered in the popover
        // for the same reason it does to the suppressors.
        isExpensiveNetwork = metering.verdict.isMetered
        totalBytesIn = bucket.internetBytesIn
        totalBytesOut = bucket.internetBytesOut
        dayStart = store.dayStart
        countingSince = store.countingSince
    }

    // MARK: Actions

    public func resetCurrentNetwork() {
        store.resetCurrentNetwork()
        lastActivity.removeAll()
        rowOrder.reset()
        expandedApps.removeAll()
        refreshHeader()
        rebuildRows(now: Date())
    }

    /// Opens or closes one app's child breakdown.
    public func toggleExpanded(_ id: String) {
        if expandedApps.contains(id) {
            expandedApps.remove(id)
        } else {
            expandedApps.insert(id)
        }
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
