import Foundation

// MARK: - Persisted model

/// Totals for one app within one network bucket.
public struct AppTotals: Codable, Equatable {
    public var displayName: String
    public var bundlePath: String?
    public var isSystem: Bool
    public var bytesIn: Int64
    public var bytesOut: Int64
    /// Drives the "active now" dot and the ordering of idle rows.
    public var lastActive: Date

    public var total: Int64 { bytesIn + bytesOut }
}

/// Everything accumulated on one network since the current day began.
public struct NetworkBucket: Codable, Equatable {
    /// Authoritative usage, from kernel interface counters. This is the number
    /// a data cap should be measured against.
    public var interfaceBytesIn: Int64 = 0
    public var interfaceBytesOut: Int64 = 0
    /// Per-app attribution from nettop. Sums close to, but not exactly, the
    /// interface totals — see `UsageStore` notes.
    public var apps: [String: AppTotals] = [:]
    public var kind: NetworkFingerprint.Kind = .other
    public var defaultLabel: String = "Network"
    public var lastSeen: Date = .distantPast

    public var interfaceTotal: Int64 { interfaceBytesIn + interfaceBytesOut }
}

struct PersistedState: Codable {
    /// Local midnight that the current totals are measured from.
    var dayStart: Date
    /// Fingerprint id → user-assigned name.
    var labels: [String: String]
    /// Fingerprint id → bucket.
    var buckets: [String: NetworkBucket]

    static func empty(now: Date = Date(), calendar: Calendar = .current) -> PersistedState {
        PersistedState(dayStart: calendar.startOfDay(for: now), labels: [:], buckets: [:])
    }
}

// MARK: - Store

/// Accumulates usage into per-network buckets and rolls over at local midnight.
///
/// Bucketing per network, rather than wiping totals on any network change, is
/// what makes "drop off my Wi-Fi and rejoin it" preserve the day's total while
/// "switch to a different Wi-Fi" shows a different total. Switching back
/// restores the original bucket instead of restarting it from zero.
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
    public func recordApps(_ entries: [(identity: AppIdentity, bytesIn: Int64, bytesOut: Int64)],
                           now: Date = Date()) {
        rolloverIfNeeded(now: now)
        withCurrentBucket(now: now) { bucket in
            for entry in entries where entry.bytesIn > 0 || entry.bytesOut > 0 {
                var totals = bucket.apps[entry.identity.key] ?? AppTotals(
                    displayName: entry.identity.displayName,
                    bundlePath: entry.identity.bundlePath,
                    isSystem: entry.identity.isSystem,
                    bytesIn: 0, bytesOut: 0, lastActive: now)
                totals.bytesIn += entry.bytesIn
                totals.bytesOut += entry.bytesOut
                totals.lastActive = now
                // Refresh naming in case the bundle resolved after first sighting.
                totals.displayName = entry.identity.displayName
                totals.bundlePath = entry.identity.bundlePath
                bucket.apps[entry.identity.key] = totals
            }
        }
    }

    private func withCurrentBucket(now: Date, _ body: (inout NetworkBucket) -> Void) {
        // Offline still gets a bucket: traffic on a link the path monitor hasn't
        // classified yet would otherwise be dropped on the floor.
        var bucket = state.buckets[currentNetwork.id] ?? NetworkBucket(
            kind: currentNetwork.kind,
            defaultLabel: currentNetwork.defaultLabel)
        bucket.kind = currentNetwork.kind
        bucket.defaultLabel = currentNetwork.defaultLabel
        bucket.lastSeen = now
        body(&bucket)
        state.buckets[currentNetwork.id] = bucket
        dirty = true
    }

    // MARK: Network switching

    public func setCurrentNetwork(_ fingerprint: NetworkFingerprint, now: Date = Date()) {
        rolloverIfNeeded(now: now)
        let previous = currentNetwork
        currentNetwork = fingerprint
        // Materialise the bucket so a freshly joined network shows 0 B rather
        // than nothing at all.
        withCurrentBucket(now: now) { _ in }
        if previous.id == NetworkFingerprint.offline.id, fingerprint.id != previous.id {
            absorbOfflineBucket(now: now)
        }
        save()
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
            var bucket = state.buckets[key]!
            bucket.interfaceBytesIn = 0
            bucket.interfaceBytesOut = 0
            bucket.apps = [:]
            state.buckets[key] = bucket
        }
        dirty = true
        save()
        return true
    }

    /// Manual "Reset Now" — clears only the network in front of the user.
    public func resetCurrentNetwork(now: Date = Date()) {
        var bucket = state.buckets[currentNetwork.id] ?? NetworkBucket()
        bucket.interfaceBytesIn = 0
        bucket.interfaceBytesOut = 0
        bucket.apps = [:]
        bucket.lastSeen = now
        state.buckets[currentNetwork.id] = bucket
        dirty = true
        save()
    }

    public func resetAllNetworks(now: Date = Date()) {
        for key in state.buckets.keys {
            var bucket = state.buckets[key]!
            bucket.interfaceBytesIn = 0
            bucket.interfaceBytesOut = 0
            bucket.apps = [:]
            state.buckets[key] = bucket
        }
        dirty = true
        save()
    }

    // MARK: Reads

    public var dayStart: Date { state.dayStart }

    public var currentBucket: NetworkBucket {
        state.buckets[currentNetwork.id] ?? NetworkBucket(
            kind: currentNetwork.kind, defaultLabel: currentNetwork.defaultLabel)
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
                var bucket = decoded.buckets[key]!
                bucket.interfaceBytesIn = 0
                bucket.interfaceBytesOut = 0
                bucket.apps = [:]
                decoded.buckets[key] = bucket
            }
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
