import AppKit
import Combine
import FirewallPolicy
import ServerDirectory
import Foundation

/// Drives the menu bar title and the popover.
///
/// Runs two independent sampling loops on purpose:
///
/// - **Interface counters, every 0.5–2 s** depending on `PowerProfile`, and
///   every 5–15 s while nobody can see the menu bar. Feeds the live menu bar rate
///   and the authoritative day total. One `sysctl` call, negligible cost, and fast
///   enough to feel real-time.
/// - **nettop, every 1–10 s** depending on `PowerProfile`. Feeds per-app
///   attribution, and the LAN/internet split that keeps a mirrored screen out of
///   the totals. Runs continuously, for the whole life of the app: a fraction of a
///   core once its stdin stopped spinning (`NettopStream.spawn()`; measured per
///   profile in `PowerProfile`), so there is nothing left worth switching off. The gating that used to exist is what made per-app
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
    /// The on-demand speed test. Owned here for the same reason as `metering`:
    /// it has to hear about network changes, and it borrows the nettop samples to
    /// notice other apps competing with it.
    public let speedTest: SpeedTestController
    /// The content filter (#128): off until turned on in the welcome window or
    /// Settings › Connections (#134).
    public let filter = FilterController()
    private var filterNames: AnyCancellable?
    /// What the filter blocks or always allows (#114), made in Connections.
    public let firewall = FirewallRules()
    /// The monthly refresh of the country and owner data (#121).
    public let geoData = GeoDataUpdater()
    /// Updating NetworkMonitor itself (#132).
    public let updates = UpdateController()
    private var firewallPolicy: AnyCancellable?
    /// The readout's colours, and the speed test's alongside them (#45).
    public let menuBarColors: MenuBarColors
    /// Wi-Fi names, and the Location permission they need (#85).
    public let wifiNames: WiFiNames

    private let identityResolver = AppIdentityResolver()
    private let nettop: NettopStream
    private let pathWatcher = NetworkIdentityWatcher()

    private var deltaTracker = InterfaceDeltaTracker()
    private var downSmoother = RateSmoother()
    private var upSmoother = RateSmoother()

    private var sampleTimer: DispatchSourceTimer?
    private var lastSampleTime = MonotonicClock.now()
    private let sampleQueue = DispatchQueue(label: "com.networkmonitor.sampler")

    /// Interval for the interface sampler, from the profile and whether anyone can
    /// see the menu bar.
    private var sampleInterval: TimeInterval = 0.5

    /// The reasons nobody can see the menu bar, each set and cleared by its own
    /// pair of notifications.
    private var displayAsleep = false
    private var screenLocked = false
    private var sessionInactive = false
    /// Nobody can see the menu bar, so the readout is not drawn and the counters
    /// are read only as often as the totals need. See `setAttention(_:)`.
    private var unattended: Bool { displayAsleep || screenLocked || sessionInactive }

    /// Popover visibility. Gates list rebuilds so a closed popover costs nothing
    /// beyond accumulation.
    private var popoverIsOpen = false

    /// pids seen in the latest nettop sample, for pid-reuse cache eviction.
    private var lastSeenPIDs: Set<Int32> = []

    /// Per-app rate tracking for the "active now" indicator.
    private var lastActivity: [String: Date] = [:]

    private var saveCounter = 0

    /// Set by `uninstall()`, so quitting does not write the usage file back into
    /// the folder that was just deleted.
    private var uninstalled = false

    /// Last menu bar title actually published, used to suppress no-op updates.
    private var renderedTitle = ""

    /// Why per-app figures have stopped, when `nettop` can't be started; nil while
    /// it runs. The total never depends on it, so the popover says the list is
    /// paused rather than letting it go quiet (#27). Cleared by the next sample.
    @Published public private(set) var perAppFailure: String?
    /// The addresses of the servers moving data in each nettop sample, for the
    /// Connections map's Live view. Sent whether or not anyone listens, which
    /// costs nothing when nobody does.
    public let serverActivity = PassthroughSubject<Set<String>, Never>()

    /// Sampling rates, chosen from the power source and Low Power Mode. Published so
    /// Settings can say which one is in force; there is nothing for the user to set.
    @Published public private(set) var profile: PowerProfile = .performance
    private var powerToken: Any?

    public init(store: UsageStore = UsageStore(history: UsageHistory()),
                metering: MeteringController? = nil,
                speedTest: SpeedTestController = SpeedTestController(),
                menuBarColors: MenuBarColors = MenuBarColors(),
                wifiNames: WiFiNames = WiFiNames(),
                nettop: NettopStream? = nil) {
        self.store = store
        self.metering = metering ?? MeteringController(store: store)
        self.speedTest = speedTest
        self.menuBarColors = menuBarColors
        self.wifiNames = wifiNames
        self.dayStart = store.dayStart
        self.countingSince = store.countingSince
        let profile = PowerProfile.current()
        self.profile = profile
        self.sampleInterval = profile.interfaceInterval(unattended: false)
        self.nettop = nettop ?? NettopStream(sampleInterval: profile.nettopSampleInterval)
    }

    // MARK: Lifecycle

    public func start() {
        // Before the first network is adopted, so the first session written
        // already carries a verdict, and the retention is in force before the
        // first write prunes anything.
        store.history?.isMetered = { [weak self] in self?.metering.verdict.isMetered ?? false }
        store.history?.retention = UserDefaults.standard
            .string(forKey: HistoryViewModel.retentionKey)
            .flatMap(HistoryRetention.init(rawValue:)) ?? .forever

        pathWatcher.onChange = { [weak self] fingerprint in
            self?.handleNetworkChange(fingerprint)
        }
        // Read on the watcher's queue, so it takes the component, not `self`.
        pathWatcher.wifiName = { [wifiNames] interface in wifiNames.name(onInterface: interface) }
        wifiNames.onChange = { [weak self] in self?.pathWatcher.refresh() }
        pathWatcher.start()
        wifiNames.start()
        // Adopt whatever the watcher already knows so the first tick has a bucket.
        store.setCurrentNetwork(pathWatcher.fingerprint)
        refreshHeader()

        // After the store has a current network, so the first evaluation judges
        // the connection actually in use rather than `.offline`. `start()`
        // replays any journal left by the previous run before deciding.
        metering.start()

        // What the filter saw names the servers nettop only gives addresses for,
        // and what it blocked is counted beside them (#114).
        filterNames = filter.flows.sink { [weak self] flows in
            guard let history = self?.store.history else { return }
            history.noteServerNames(flows.compactMap { flow in
                flow.hostname.map { (FirewallPolicy.serverAddress(flow.address), $0) }
            })
            history.recordBlocked(flows.compactMap { flow in
                guard flow.blockedBy != nil, let key = flow.appKey else { return nil }
                return (AppIdentityResolver.identity(forKey: key), FirewallPolicy.serverAddress(flow.address))
            })
        }
        filter.resume()
        // The rules, whether this is a hotspot for the ones that say "on
        // hotspots", and whether Hotspot mode pauses updates here (#98). The
        // values come from the publishers: they fire before the properties
        // change.
        firewallPolicy = Publishers.CombineLatest4(firewall.$rules, firewall.$mode, $isExpensiveNetwork,
                                                   metering.$isEnabled)
            .sink { [weak self] rules, mode, onHotspot, pausing in
                self?.filter.apply(FirewallPolicy(mode: mode, rules: rules, onHotspot: onHotspot,
                                                  pausesUpdates: pausing && onHotspot))
            }

        // Never on a hotspot, a metered connection or in Low Data Mode, as the
        // app judges them, and never offline (#121).
        geoData.mayDownload = { [weak self] in
            guard let self else { return false }
            let network = self.store.currentNetwork
            return network.id != NetworkFingerprint.offline.id && !network.isConstrained
                && !self.metering.verdict.isMetered
        }
        geoData.onUpdate = { [weak self] directory, month in self?.filter.applyGeoData(at: directory, month: month) }
        if let month = GeoData.month(in: GeoDataUpdater.downloadedDirectory), month == geoData.month {
            filter.applyGeoData(at: GeoDataUpdater.downloadedDirectory, month: month)
        }
        geoData.start()
        updates.isMetered = { [weak self] in self?.metering.verdict.isMetered ?? false }
        updates.start()

        // Asked at the moment of each run, so a hotspot joined after launch is
        // caught. The menu bar hook routes through the same signal the live rate
        // uses, so `AppDelegate` has one thing to observe.
        speedTest.isMetered = { [weak self] in self?.metering.verdict.isMetered ?? false }
        // Off the main thread: it lists the temporary directory.
        DispatchQueue.global(qos: .utility).async { SpeedTestRunner.removeLeftoverFolders() }
        speedTest.menuBarDidChange = { [weak self] in self?.menuBarRateDidChange.send() }
        menuBarColors.didChange = { [weak self] in self?.menuBarRateDidChange.send() }

        nettop.onSample = { [weak self] sample in
            self?.handleNettopSample(sample)
        }
        nettop.onFailure = { [weak self] message in
            DispatchQueue.main.async {
                guard let self, self.perAppFailure != message else { return }
                self.perAppFailure = message
            }
        }
        nettop.start()
        powerToken = PowerSource.observe { [weak self] in
            self?.applyProfile()
        }

        startSampleTimer()
        observeSystemNotifications()
    }

    /// Re-reads the power source and Low Power Mode and applies the resulting
    /// sampling rates.
    ///
    /// Called on power transitions, when Low Power Mode changes, and when the menu
    /// bar stops or starts being seen. Idempotent: the timer is only rebuilt when
    /// its interval actually changes, and `nettop` is only restarted when its
    /// interval does.
    private func applyProfile() {
        let next = PowerProfile.current()
        if profile != next { profile = next }
        setSampleInterval(next.interfaceInterval(unattended: unattended))
        nettop.setSampleInterval(next.nettopSampleInterval)
    }

    /// Applies a change to whether anyone can see the menu bar.
    ///
    /// Going unattended relaxes the sampler, and `sampleInterfaces()` stops
    /// drawing the readout. Coming back catches the readout up at once: it still
    /// shows whatever it drew last, which may be hours old.
    private func setAttention(_ change: (MonitorViewModel) -> Void) {
        let wasUnattended = unattended
        change(self)
        guard unattended != wasUnattended else { return }
        applyProfile()
        if !unattended {
            renderedTitle = ""
            sampleQueue.async { [weak self] in self?.sampleInterfaces() }
        }
    }

    public func stop() {
        sampleTimer?.cancel()
        sampleTimer = nil
        powerToken = nil
        nettop.stop()
        speedTest.stop()
        pathWatcher.stop()
        // Suppression is deliberately *not* lifted on quit. Quitting the app is
        // not the same as saying "resume updating" — the user may be quitting to
        // save battery mid-hotspot — and the journal is what makes leaving it in
        // place safe: the next launch replays it, and `uninstall.sh` reverts it.
        // Low Data Mode is the exception, released inside `metering.stop()`;
        // see there for why.
        metering.stop()
        // After an uninstall the folder this writes into has just been deleted,
        // and saving would put it back.
        if !uninstalled { store.save() }
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

        // Nobody seeing the menu bar relaxes the interface sampler but never
        // `nettop`: see `PowerProfile.nettopSampleInterval` for why only the free
        // one moves.
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.setAttention { $0.displayAsleep = true }
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.setAttention { $0.displayAsleep = false }
        }
        // A locked screen can stay lit, with no menu bar on it.
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                                object: nil, queue: .main) { [weak self] _ in
            self?.setAttention { $0.screenLocked = true }
        }
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                                object: nil, queue: .main) { [weak self] _ in
            self?.setAttention { $0.screenLocked = false }
        }
        // Fast user switching: another user's session is in front.
        center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.setAttention { $0.sessionInactive = true }
        }
        center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.setAttention { $0.sessionInactive = false }
        }

        // Low Power Mode picks the `saver` profile, plugged in or not. Posted on
        // whichever thread noticed, hence the main queue.
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange,
                                               object: nil, queue: .main) { [weak self] _ in
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
            // The unit is part of the key: switching it in Settings must redraw
            // even when the rates themselves have not moved.
            //
            // Nothing is drawn while nobody can see the menu bar: that drawing is
            // most of what the app costs. `setAttention` redraws on the way back.
            let rendered = MenuBarTitle.string(down: down, up: up, unit: self.speedTest.unit)
            if !self.unattended, rendered != self.renderedTitle {
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
                if !self.uninstalled { self.store.save() }
            }
        }
    }

    // MARK: nettop sampling

    private func handleNettopSample(_ sample: [NettopRow]) {
        // Resolve identities on the main actor: AppIdentityResolver touches
        // NSWorkspace and its caches are not thread-safe.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.perAppFailure != nil { self.perAppFailure = nil }
            let now = Date()
            var entries: [(identity: AppIdentity, bytesIn: Int64, bytesOut: Int64)] = []
            var pids = Set<Int32>()
            var merged: [String: (identity: AppIdentity, bytesIn: Int64, bytesOut: Int64)] = [:]
            // Each app's internet bytes by server address, for Connections (#115).
            var servers: [String: [String: ByteCounts]] = [:]

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
                for (address, bytes) in row.servers {
                    servers[identity.key, default: [:]][address,
                        default: ByteCounts(bytesIn: 0, bytesOut: 0)] += bytes
                }
                self.lastActivity[identity.key] = now

                // By the raw process name, not the app it folds into:
                // `GoogleUpdater` is an updater whether or not its row groups
                // under Chrome, and the name is the only list-free signal there is.
                if self.metering.isSuppressing,
                   UpdaterScan.looksLikeUpdater(row.processName) {
                    self.metering.noteUpdaterTraffic(processName: row.processName,
                                                     appName: identity.displayName,
                                                     bytes: bytesIn + bytesOut)
                }
            }
            entries = Array(merged.values)
            if self.metering.isSuppressing {
                // By the app a process belongs to: Squirrel's ShipIt and
                // Sparkle's downloader run inside the app they update. Outside
                // an app, by its executable too: Claude Code updates itself
                // from the folder it runs from, inside a terminal (#94).
                for entry in entries {
                    let identity = entry.identity, bytes = entry.bytesIn + entry.bytesOut
                    if let bundlePath = identity.bundlePath {
                        self.metering.noteAppTraffic(path: bundlePath, bytes: bytes, now: now)
                        continue
                    }
                    self.metering.noteAppTraffic(path: AppIdentityResolver.keyBeforeAdoption(identity.key)
                                                     ?? identity.key, bytes: bytes, now: now)
                    if let parent = identity.parent?.bundlePath {
                        self.metering.noteAppTraffic(path: parent, bytes: bytes, now: now)
                    }
                }
            }
            self.metering.tick(now: now)

            if self.speedTest.phase.isRunning {
                self.speedTest.recordBackground(entries.map {
                    ($0.identity.displayName, $0.identity.key, $0.bytesIn + $0.bytesOut)
                })
            }

            if !servers.isEmpty {
                self.serverActivity.send(Set(servers.values.flatMap(\.keys)))
            }
            self.lastSeenPIDs = pids
            self.identityResolver.retainOnly(pids: pids)
            self.store.recordApps(entries, servers: servers,
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
        rows = partitioned.apps
        systemRows = partitioned.system
        systemTotal = partitioned.systemTotal
    }

    // MARK: Network changes

    private func handleNetworkChange(_ fingerprint: NetworkFingerprint) {
        // Only the Wi-Fi name is new, read once Location was allowed, or gone
        // once it was taken away. The link is the same, so the store keeps the
        // name and nothing is re-baselined: a reset would drop a sample.
        if fingerprint.isSameLink(as: store.currentNetwork) {
            store.setCurrentNetwork(fingerprint)
            objectWillChange.send()
            return
        }
        // Joining a different network restarts its counter; an offline blip and
        // a rejoin resume the same one. The store decides which happened.
        if store.setCurrentNetwork(fingerprint) {
            // Describes the network just left. Kept, the popover would open
            // showing "active now" dots for apps whose bytes have been wiped.
            lastActivity.removeAll()
            expandedApps.removeAll()
            speedTest.networkDidChange()
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
        expandedApps.removeAll()
        refreshHeader()
        rebuildRows(now: Date())
    }

    /// Removes NetworkMonitor completely, from the app itself.
    ///
    /// What `Scripts/uninstall.sh` does, for people who never open Terminal —
    /// which, for an app installed from a disk image, is everyone. In order:
    ///
    /// 1. **The helper**, first, because it is the one step that asks for a
    ///    password and so the one that can be cancelled. Cancelled, nothing has
    ///    changed yet. Done, the helper has put back the system update settings,
    ///    the managed policies, `/etc/hosts` and Low Data Mode, and removed itself.
    /// 2. **Every other setting metering changed** — Sparkle preferences, VS
    ///    Code's settings file — from the journal, while the journal still exists.
    /// 3. **The login item, the app's data and settings, and the app**, which
    ///    goes to the Trash rather than being deleted outright, so it can be
    ///    dragged back.
    ///
    /// The caller quits afterwards.
    public func uninstall() -> HelperInstaller.Outcome {
        let helper = HelperInstaller.uninstall()
        guard helper == .done else { return helper }

        metering.revertAll()
        LoginItem.withdraw()

        uninstalled = true
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
            .appendingPathComponent("NetworkMonitor", isDirectory: true)
        try? FileManager.default.removeItem(at: support)
        if let identifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: identifier)
        }
        NSWorkspace.shared.recycle([Bundle.main.bundleURL])
        return .done
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

    /// Two stacked lines, download above upload, at a constant rendered width,
    /// in the speed unit chosen in Settings.
    ///
    /// A running speed test takes the title over and keeps it for a few seconds
    /// after with the result. Same width, tints kept clear of the live colours;
    /// see `MenuBarTitle.speedTestImage` and `MenuBarColors`.
    public var menuBarImage: NSImage {
        if let reading = speedTest.menuBarReading {
            return MenuBarTitle.speedTestImage(downBits: reading.down, upBits: reading.up,
                                               unit: speedTest.unit, tints: menuBarColors.test)
        }
        return MenuBarTitle.image(down: downBytesPerSecond, up: upBytesPerSecond,
                                  unit: speedTest.unit, tints: menuBarColors.live)
    }
}
