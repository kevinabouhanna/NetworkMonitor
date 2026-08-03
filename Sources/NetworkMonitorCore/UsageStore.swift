import Foundation

// MARK: - Persisted model

/// Totals for one app within one network bucket.
public struct AppTotals: Codable, Equatable {
    public var displayName: String
    public var bundlePath: String?
    public var isSystem: Bool
    /// Set when this process was launched by an app it does not live inside, so
    /// the row nests under that app. Optional, so a store written before nesting
    /// still decodes — synthesised decoding uses `decodeIfPresent` for optionals.
    public var parent: ParentApp?
    public var bytesIn: Int64
    public var bytesOut: Int64
    /// Drives the "active now" dot and the ordering of idle rows.
    public var lastActive: Date

    public var total: Int64 { bytesIn + bytesOut }

    public init(displayName: String, bundlePath: String? = nil, isSystem: Bool = false,
                parent: ParentApp? = nil,
                bytesIn: Int64 = 0, bytesOut: Int64 = 0, lastActive: Date = .distantPast) {
        self.displayName = displayName
        self.bundlePath = bundlePath
        self.isSystem = isSystem
        self.parent = parent
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.lastActive = lastActive
    }
}

/// Everything accumulated on one network since its counter last started.
public struct NetworkBucket: Codable, Equatable {
    /// Authoritative usage, from kernel interface counters. This is the number
    /// a data cap should be measured against.
    public var interfaceBytesIn: Int64 = 0
    public var interfaceBytesOut: Int64 = 0
    /// Per-app attribution from nettop. Sums close to, but not exactly, the
    /// interface totals — see `UsageStore` notes.
    public var apps: [String: AppTotals] = [:]
    /// LAN bytes seen by `nettop`, kept out of every figure the app displays.
    ///
    /// Tracked rather than discarded because the headline comes from the kernel's
    /// interface counters, which cannot tell a mirrored screen from a download —
    /// subtracting this is the only way to make that number mean "internet".
    public var localBytesIn: Int64 = 0
    public var localBytesOut: Int64 = 0
    public var kind: NetworkFingerprint.Kind = .other
    public var defaultLabel: String = "Network"
    public var lastSeen: Date = .distantPast
    /// When these totals started accumulating: the day's midnight, a manual
    /// reset, or the moment this network was joined from a different one.
    /// Shown as "Counting since", so the figure is never read over the wrong
    /// window.
    public var countingSince: Date = .distantPast

    public var interfaceTotal: Int64 { interfaceBytesIn + interfaceBytesOut }

    /// Internet bytes the app rows already account for.
    public var attributedBytesIn: Int64 { apps.values.reduce(0) { $0 + $1.bytesIn } }
    public var attributedBytesOut: Int64 { apps.values.reduce(0) { $0 + $1.bytesOut } }

    /// The figure the app shows: everything the kernel counted, minus what
    /// `nettop` could prove stayed on the LAN — bounded at both ends.
    ///
    /// The subtraction alone is not safe. `mDNSResponder`'s multicast socket is
    /// multi-homed, so nettop bills its full byte count to *every* interface type
    /// it matches, and multicast is exactly the traffic being subtracted here.
    /// Measured live: over 90 s the kernel saw 1,702 KB, nettop reported 1,335 KB
    /// of local, and the plain subtraction left 367 KB of "internet" — while the
    /// app rows for that same window totalled 1,174 KB. A headline smaller than the
    /// rows beneath it is not an estimate, it is a contradiction.
    ///
    /// So the result is clamped into the only range that can be true: never below
    /// what the rows already prove went to the internet, never above what the
    /// kernel actually counted.
    public var internetBytesIn: Int64 {
        min(interfaceBytesIn, max(interfaceBytesIn - localBytesIn, attributedBytesIn))
    }
    public var internetBytesOut: Int64 {
        min(interfaceBytesOut, max(interfaceBytesOut - localBytesOut, attributedBytesOut))
    }
    public var internetTotal: Int64 { internetBytesIn + internetBytesOut }

    /// Zeroes the totals and restarts the counting window at `date`.
    mutating func clear(at date: Date) {
        interfaceBytesIn = 0
        interfaceBytesOut = 0
        localBytesIn = 0
        localBytesOut = 0
        apps = [:]
        countingSince = date
    }
}

extension NetworkBucket {
    /// Hand-written so a store saved by an earlier version — which has no
    /// `countingSince` — still loads. Synthesised decoding treats a missing key
    /// as an error regardless of the property's default value, and the fallback
    /// for an undecodable store is to start clean, which would throw away the
    /// day's totals on upgrade.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            interfaceBytesIn: try container.decodeIfPresent(Int64.self, forKey: .interfaceBytesIn) ?? 0,
            interfaceBytesOut: try container.decodeIfPresent(Int64.self, forKey: .interfaceBytesOut) ?? 0,
            apps: try container.decodeIfPresent([String: AppTotals].self, forKey: .apps) ?? [:],
            localBytesIn: try container.decodeIfPresent(Int64.self, forKey: .localBytesIn) ?? 0,
            localBytesOut: try container.decodeIfPresent(Int64.self, forKey: .localBytesOut) ?? 0,
            kind: try container.decodeIfPresent(NetworkFingerprint.Kind.self, forKey: .kind) ?? .other,
            defaultLabel: try container.decodeIfPresent(String.self, forKey: .defaultLabel) ?? "Network",
            lastSeen: try container.decodeIfPresent(Date.self, forKey: .lastSeen) ?? .distantPast,
            countingSince: try container.decodeIfPresent(Date.self, forKey: .countingSince) ?? .distantPast)
    }
}

struct PersistedState: Codable {
    /// Local midnight that the current totals are measured from.
    var dayStart: Date
    /// Fingerprint id → user-assigned name.
    var labels: [String: String]
    /// Fingerprint id → bucket.
    var buckets: [String: NetworkBucket]
    /// Last network actually joined, ignoring offline gaps. Persisted so a
    /// relaunch on the same network resumes its counter instead of reading as a
    /// switch and wiping it. Optional, so an older store still decodes.
    var lastNetworkID: String?
    /// Fingerprint id → the user's own metered decision, overriding the
    /// heuristic in whichever direction they chose. Held here rather than on the
    /// bucket so that resetting a network's totals does not also discard what
    /// the user said about it. Optional, so an older store still decodes.
    var meteredOverrides: [String: Bool]?

    static func empty(now: Date = Date(), calendar: Calendar = .current) -> PersistedState {
        PersistedState(dayStart: calendar.startOfDay(for: now), labels: [:], buckets: [:],
                       lastNetworkID: nil, meteredOverrides: [:])
    }
}

// MARK: - Store

/// Accumulates usage into per-network buckets, restarts the counter when the
/// machine joins a different network, and rolls over at local midnight.
///
/// The counter answers "what has *this connection* cost me", because that is the
/// question when you open a hotspot somewhere new. So joining a different
/// network zeroes its bucket, even one with usage history and even mid-day.
///
/// Bucketing per network is still what keeps a connectivity blip from being read
/// as a switch: an offline gap does not change which network was last joined, so
/// "drop off my Wi-Fi and rejoin it" resumes the same counter, and each network's
/// figure stays its own rather than one global total that every change disturbs.
///
/// Two totals are tracked deliberately. `interfaceBytes*` come from kernel
/// interface counters and are authoritative. The per-app numbers come from
/// nettop and will not sum to exactly the same value: some kernel traffic is
/// attributable to no process, and a few multi-homed system sockets (notably
/// mDNSResponder's multicast socket) have their full byte count billed to every
/// interface type they match, so AWDL traffic cannot be cleanly subtracted from
/// them. Those land in the collapsed System group; real apps use per-interface
/// sockets and are unaffected.
public final class UsageStore {

    private var state: PersistedState
    private let calendar: Calendar
    private let storeURL: URL
    private var dirty = false

    /// Fingerprint of the network currently being accumulated into.
    public private(set) var currentNetwork: NetworkFingerprint = .offline

    public init(storeURL: URL? = nil, calendar: Calendar = .current) {
        self.calendar = calendar
        self.storeURL = storeURL ?? Self.defaultStoreURL()
        self.state = Self.load(from: self.storeURL, calendar: calendar)
    }

    // MARK: Accumulation

    /// Adds interface-level bytes to the active bucket. This is the authoritative total.
    public func recordInterface(bytesIn: Int64, bytesOut: Int64, now: Date = Date()) {
        guard bytesIn > 0 || bytesOut > 0 else { return }
        rolloverIfNeeded(now: now)
        withCurrentBucket(now: now) { bucket in
            bucket.interfaceBytesIn += bytesIn
            bucket.interfaceBytesOut += bytesOut
        }
    }

    /// Adds one nettop sample's per-process deltas to the active bucket.
    ///
    /// `bytesIn`/`bytesOut` are the app's *internet* bytes — LAN traffic is passed
    /// separately in `localBytesIn`/`localBytesOut` and never reaches an app row,
    /// because "how much internet did this app use" is the question being answered.
    public func recordApps(_ entries: [(identity: AppIdentity, bytesIn: Int64, bytesOut: Int64)],
                           localBytesIn: Int64 = 0, localBytesOut: Int64 = 0,
                           now: Date = Date()) {
        rolloverIfNeeded(now: now)
        withCurrentBucket(now: now) { bucket in
            bucket.localBytesIn += localBytesIn
            bucket.localBytesOut += localBytesOut
            for entry in entries where entry.bytesIn > 0 || entry.bytesOut > 0 {
                Self.absorbPreAdoptionRow(for: entry.identity, in: &bucket)
                var totals = bucket.apps[entry.identity.key] ?? AppTotals(
                    displayName: entry.identity.displayName,
                    bundlePath: entry.identity.bundlePath,
                    isSystem: entry.identity.isSystem,
                    parent: entry.identity.parent,
                    bytesIn: 0, bytesOut: 0, lastActive: now)
                totals.bytesIn += entry.bytesIn
                totals.bytesOut += entry.bytesOut
                totals.lastActive = now
                // Refresh naming in case the bundle resolved after first sighting.
                totals.displayName = entry.identity.displayName
                totals.bundlePath = entry.identity.bundlePath
                totals.parent = entry.identity.parent
                bucket.apps[entry.identity.key] = totals
            }
        }
    }

    /// Folds a row left behind by a version that could not adopt this process
    /// into the row that now owns it.
    ///
    /// Before nesting, an un-bundled process was keyed by its executable path and
    /// filed as a system daemon. That row is still in the store after an upgrade,
    /// and it never grows again because new bytes go to the adopted key — so the
    /// same process shows up twice, once frozen under System and once live under
    /// its parent. Its bytes were really used, so they are moved rather than
    /// discarded, and the migration happens the first time the process transmits.
    ///
    /// Only a system row is absorbed: a real app that happens to share the tail
    /// of a composite key is not the same thing.
    private static func absorbPreAdoptionRow(for identity: AppIdentity,
                                            in bucket: inout NetworkBucket) {
        guard identity.parent != nil,
              let legacyKey = AppIdentityResolver.keyBeforeAdoption(identity.key),
              let legacy = bucket.apps[legacyKey],
              legacy.isSystem
        else { return }

        bucket.apps.removeValue(forKey: legacyKey)
        var totals = bucket.apps[identity.key] ?? AppTotals(
            displayName: identity.displayName,
            bundlePath: identity.bundlePath,
            isSystem: false,
            parent: identity.parent)
        totals.bytesIn += legacy.bytesIn
        totals.bytesOut += legacy.bytesOut
        totals.lastActive = max(totals.lastActive, legacy.lastActive)
        bucket.apps[identity.key] = totals
    }

    private func withCurrentBucket(now: Date, _ body: (inout NetworkBucket) -> Void) {
        // Offline still gets a bucket: traffic on a link the path monitor hasn't
        // classified yet would otherwise be dropped on the floor.
        var bucket = state.buckets[currentNetwork.id] ?? NetworkBucket(
            kind: currentNetwork.kind,
            defaultLabel: currentNetwork.defaultLabel,
            countingSince: now)
        bucket.kind = currentNetwork.kind
        bucket.defaultLabel = currentNetwork.defaultLabel
        bucket.lastSeen = now
        body(&bucket)
        state.buckets[currentNetwork.id] = bucket
        dirty = true
    }

    // MARK: Network switching

    /// Points accumulation at `fingerprint`, restarting its counter if this is a
    /// different network from the last one joined.
    ///
    /// Returns true when the counter was restarted, so the caller can drop the
    /// per-app state that belongs to the network just left.
    @discardableResult
    public func setCurrentNetwork(_ fingerprint: NetworkFingerprint, now: Date = Date()) -> Bool {
        rolloverIfNeeded(now: now)
        let previous = currentNetwork
        let switched = isSwitch(to: fingerprint)
        currentNetwork = fingerprint

        if switched {
            // Wipes interface totals and every app row: a new connection starts
            // from zero whether or not this network has been seen before.
            clearCurrentBucket(now: now)
        } else {
            // Materialise the bucket so a freshly joined network shows 0 B rather
            // than nothing at all.
            withCurrentBucket(now: now) { _ in }
        }
        if fingerprint.id != NetworkFingerprint.offline.id {
            state.lastNetworkID = fingerprint.id
        }
        // After the clear, never before: those bytes travelled over the network
        // just joined, so a switch must not discard them.
        if previous.id == NetworkFingerprint.offline.id, fingerprint.id != previous.id {
            absorbOfflineBucket(now: now)
        }
        save()
        return switched
    }

    /// Whether joining `fingerprint` is a move to a different network.
    ///
    /// Offline is never a switch in either direction. It is a gap, not a place:
    /// the path monitor reports it for a Wi-Fi drop, a sleep, a VPN reconnect,
    /// and treating those as a new connection would zero the counter several
    /// times an hour on a flaky link — the failure mode that made wiping on any
    /// `NWPathMonitor` change unusable in the first place.
    private func isSwitch(to fingerprint: NetworkFingerprint) -> Bool {
        guard fingerprint.id != NetworkFingerprint.offline.id,
              let last = state.lastNetworkID
        else { return false }
        return last != fingerprint.id
    }

    private func clearCurrentBucket(now: Date) {
        withCurrentBucket(now: now) { bucket in
            bucket.clear(at: now)
        }
    }

    /// Folds the placeholder "offline" bucket into the network just identified.
    ///
    /// The path monitor is debounced by 2 s, so the first couple of seconds of
    /// traffic after launch or after reconnecting is recorded before the network
    /// is known. Those bytes really did travel over this network, so they belong
    /// in its bucket — and leaving them behind would litter the network list with
    /// a permanent "No Connection" entry holding a few KB.
    private func absorbOfflineBucket(now: Date) {
        let offlineID = NetworkFingerprint.offline.id
        guard let orphan = state.buckets[offlineID], orphan.interfaceTotal > 0 || !orphan.apps.isEmpty
        else {
            state.buckets.removeValue(forKey: offlineID)
            return
        }

        withCurrentBucket(now: now) { bucket in
            bucket.interfaceBytesIn += orphan.interfaceBytesIn
            bucket.interfaceBytesOut += orphan.interfaceBytesOut
            bucket.localBytesIn += orphan.localBytesIn
            bucket.localBytesOut += orphan.localBytesOut
            for (key, totals) in orphan.apps {
                if var existing = bucket.apps[key] {
                    existing.bytesIn += totals.bytesIn
                    existing.bytesOut += totals.bytesOut
                    existing.lastActive = max(existing.lastActive, totals.lastActive)
                    bucket.apps[key] = existing
                } else {
                    bucket.apps[key] = totals
                }
            }
        }
        state.buckets.removeValue(forKey: offlineID)
        dirty = true
    }

    // MARK: Rollover

    /// Zeroes every bucket when the local day advances.
    ///
    /// Anchored to local midnight rather than "86400 s since the last reset".
    /// A rolling window drifts a little each day and eventually resets at an
    /// arbitrary hour; a calendar day is predictable and matches how carriers
    /// and ISPs actually meter.
    ///
    /// Must also be called on wake, because timers do not fire while the machine
    /// is asleep — a Mac closed at 23:00 and opened at 09:00 would otherwise
    /// carry yesterday's totals until its next tick.
    @discardableResult
    public func rolloverIfNeeded(now: Date = Date()) -> Bool {
        let today = calendar.startOfDay(for: now)
        // `>` alone would miss a backwards clock change; compare inequality.
        guard today != state.dayStart else { return false }
        state.dayStart = today
        for key in state.buckets.keys {
            state.buckets[key]!.clear(at: today)
        }
        dirty = true
        save()
        return true
    }

    /// Manual "Reset Now" — clears only the network in front of the user.
    public func resetCurrentNetwork(now: Date = Date()) {
        clearCurrentBucket(now: now)
        save()
    }

    public func resetAllNetworks(now: Date = Date()) {
        for key in state.buckets.keys {
            state.buckets[key]!.clear(at: now)
        }
        dirty = true
        save()
    }

    // MARK: Reads

    public var dayStart: Date { state.dayStart }

    /// Start of the window the current figures cover — a network switch, a manual
    /// reset or midnight, whichever came last.
    public var countingSince: Date { currentBucket.countingSince }

    public var currentBucket: NetworkBucket {
        state.buckets[currentNetwork.id] ?? NetworkBucket(
            kind: currentNetwork.kind, defaultLabel: currentNetwork.defaultLabel,
            countingSince: state.dayStart)
    }

    public func label(for id: String) -> String {
        if let custom = state.labels[id], !custom.isEmpty { return custom }
        return state.buckets[id]?.defaultLabel ?? "Network"
    }

    public var currentLabel: String { label(for: currentNetwork.id) }

    public func setLabel(_ label: String, for id: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            state.labels.removeValue(forKey: id)
        } else {
            state.labels[id] = trimmed
        }
        dirty = true
        save()
    }

    // MARK: Metered override

    /// The user's own decision about a network, if they have made one.
    ///
    /// `nil` is not "unmetered" — it means the heuristic decides. The three-state
    /// answer is what lets someone mark a capped home line as metered *and* mark
    /// a misdetected office network as not.
    public func meteredOverride(for id: String) -> Bool? {
        state.meteredOverrides?[id]
    }

    public var currentMeteredOverride: Bool? { meteredOverride(for: currentNetwork.id) }

    public func setMeteredOverride(_ value: Bool?, for id: String) {
        var overrides = state.meteredOverrides ?? [:]
        if let value {
            overrides[id] = value
        } else {
            overrides.removeValue(forKey: id)
        }
        state.meteredOverrides = overrides
        dirty = true
        save()
    }

    /// All known networks, most recently used first.
    public func allNetworks() -> [(id: String, label: String, bucket: NetworkBucket)] {
        state.buckets
            .map { (id: $0.key, label: label(for: $0.key), bucket: $0.value) }
            .sorted { $0.bucket.lastSeen > $1.bucket.lastSeen }
    }

    // MARK: Persistence

    /// Totals survive relaunch, logout and reboot. Without this a crash at
    /// 23:00 would silently discard the whole day.
    private static func defaultStoreURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = support.appendingPathComponent("NetworkMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("usage.json")
    }

    private static func load(from url: URL, calendar: Calendar) -> PersistedState {
        guard let data = try? Data(contentsOf: url) else { return .empty(calendar: calendar) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var decoded = try? decoder.decode(PersistedState.self, from: data) else {
            // Corrupt or older-format state: start clean rather than refusing to launch.
            return .empty(calendar: calendar)
        }
        // Launching on a later day must not present stale totals as today's.
        let today = calendar.startOfDay(for: Date())
        if decoded.dayStart != today {
            decoded.dayStart = today
            for key in decoded.buckets.keys {
                decoded.buckets[key]!.clear(at: today)
            }
        }
        // A store written before per-connection counters has no window start.
        // Its totals are the day's, so that is what they are counting from.
        for key in decoded.buckets.keys where decoded.buckets[key]!.countingSince == .distantPast {
            decoded.buckets[key]!.countingSince = decoded.dayStart
        }
        return decoded
    }

    /// Writes via a temporary file so a crash mid-write can't corrupt the store.
    public func save() {
        guard dirty else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        let temporary = storeURL.appendingPathExtension("tmp")
        do {
            try data.write(to: temporary, options: .atomic)
            _ = try? FileManager.default.replaceItemAt(storeURL, withItemAt: temporary)
            dirty = false
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    public func saveIfDirty() { save() }
}
