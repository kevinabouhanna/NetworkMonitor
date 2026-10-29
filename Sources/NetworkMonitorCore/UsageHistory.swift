import Foundation

// MARK: - Model

/// One visit to a network: from joining it until leaving it for another, or
/// until a silence long enough that coming back is a new visit.
public struct HistorySession: Identifiable, Equatable {
    public let id: Int64
    public let networkID: String
    public let kind: NetworkFingerprint.Kind
    /// The network's name at the time, before any name the user gave it.
    public let defaultLabel: String
    public let start: Date
    /// The last traffic seen, not the moment the next network was joined: a
    /// lid closed at the office ends the office session when it closed.
    public let end: Date
    public let isMetered: Bool
}

/// What a history view is narrowed to. Each field is optional and they combine.
public struct HistoryFilter: Equatable {
    public var networkID: String?
    /// An app, together with every process it launched.
    public var appKey: String?
    public var sessionID: Int64?
    /// One kind of network, as charted: Wi-Fi or Hotspot from the switch above
    /// the chart (#70). nil is all of them.
    public var kind: NetworkFingerprint.Kind?

    public init(networkID: String? = nil, appKey: String? = nil,
                sessionID: Int64? = nil, kind: NetworkFingerprint.Kind? = nil) {
        self.networkID = networkID
        self.appKey = appKey
        self.sessionID = sessionID
        self.kind = kind
    }

    public var isEmpty: Bool { self == HistoryFilter() }

    /// Where History opens: on Hotspot while the Mac is on one, so the first
    /// thing shown is what's being spent on it now (#70), and on everything
    /// otherwise.
    public static func opening(on current: NetworkFingerprint.Kind) -> HistoryFilter {
        HistoryFilter(kind: current == .hotspot ? .hotspot : nil)
    }
}

/// How long history is kept.
public enum HistoryRetention: String, CaseIterable, Identifiable {
    case oneMonth, threeMonths, oneYear, forever

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .oneMonth:    return "1 Month"
        case .threeMonths: return "3 Months"
        case .oneYear:     return "1 Year"
        case .forever:     return "Forever"
        }
    }

    /// The oldest moment still kept, or nil to keep everything. Whole days, so
    /// the oldest day in the window is never shown half-empty.
    public func cutoff(now: Date, calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .oneMonth:    return calendar.date(byAdding: .month, value: -1, to: today)
        case .threeMonths: return calendar.date(byAdding: .month, value: -3, to: today)
        case .oneYear:     return calendar.date(byAdding: .year, value: -1, to: today)
        case .forever:     return nil
        }
    }
}

extension NetworkFingerprint.Kind {
    /// The four kinds the history charts, in stacking and legend order. A
    /// session that never learned its network counts as Other.
    public static let charted: [NetworkFingerprint.Kind] = [.wifi, .hotspot, .ethernet, .other]

    public var charted: NetworkFingerprint.Kind { self == .offline ? .other : self }

    public var historyLabel: String {
        switch self {
        case .wifi:     return "Wi-Fi"
        case .hotspot:  return "Hotspot"
        case .ethernet: return "Ethernet"
        case .other:    return "Other"
        case .offline:  return "No Connection"
        }
    }
}

/// Everything one history view shows, computed in a single pass so the chart,
/// the totals and the lists always describe the same bytes.
public struct HistoryReport {

    public struct Bin: Identifiable, Equatable {
        public let interval: DateInterval
        public let byKind: [NetworkFingerprint.Kind: Int64]
        public var id: Date { interval.start }
        public var total: Int64 { byKind.values.reduce(0, +) }
    }

    public struct NetworkTotal: Identifiable, Equatable {
        public let id: String
        public let kind: NetworkFingerprint.Kind
        public let defaultLabel: String
        public let bytes: Int64
        /// True if any of this period's visits to it were metered.
        public let isMetered: Bool
    }

    public struct SessionTotal: Identifiable, Equatable {
        public let session: HistorySession
        /// What the session used *within this period*, so the list adds up to
        /// the total above it even for a session that started yesterday.
        public let bytes: Int64
        public var id: Int64 { session.id }
    }

    public let period: HistoryPeriod
    public let filter: HistoryFilter
    public let bins: [Bin]
    public let byKind: [NetworkFingerprint.Kind: Int64]
    public let bytesIn: Int64
    public let bytesOut: Int64
    public let meteredBytes: Int64
    public let apps: [UsageRow]
    public let systemRows: [UsageRow]
    public let systemTotal: Int64
    /// Biggest first.
    public let networks: [NetworkTotal]
    /// Newest first.
    public let sessions: [SessionTotal]
    /// The first hour on record, whatever the filter: where stepping back stops.
    public let recordingSince: Date?

    public var total: Int64 { bytesIn + bytesOut }
    public var peakBin: Int64 { bins.map(\.total).max() ?? 0 }

    static func empty(_ period: HistoryPeriod, _ filter: HistoryFilter,
                      calendar: Calendar) -> HistoryReport {
        HistoryReport(period: period, filter: filter,
                      bins: period.bins(calendar: calendar).map { Bin(interval: $0, byKind: [:]) },
                      byKind: [:], bytesIn: 0, bytesOut: 0, meteredBytes: 0,
                      apps: [], systemRows: [], systemTotal: 0,
                      networks: [], sessions: [], recordingSince: nil)
    }
}

// MARK: - Store

/// A durable, hourly record of internet usage per app, per visit to a network.
///
/// The popover's totals answer "what has this connection cost me" and start
/// over on every network change and at midnight, by design (spec §4.2). This
/// is the other half: nothing here is ever reset by the counter, so yesterday,
/// last week and last month stay answerable.
///
/// **Resolution.** One row per hour, per session, per app. An hour is the
/// finest grain any view needs, and it keeps a year to roughly a hundred
/// thousand rows.
///
/// **What is stored is what the popover shows.** The kernel's interface bytes,
/// the LAN bytes nettop proved, and the per-app internet bytes are all kept raw
/// and summed, and the headline is derived at read time with the same clamp as
/// `NetworkBucket.internetBytesIn` — so an hour of mirroring a screen is not
/// an hour of internet here either.
///
/// **Writes.** Samples accumulate in memory and are written when the usage file
/// is — every 15 s, on a network change, on sleep and on quit — in one
/// transaction, so a crash loses at most what the popover would.
///
/// **Threading.** Recording happens on the main thread, like the rest of the
/// store. Reads run on a private queue, so stepping through a year of data
/// never stalls the menu bar.
/// What the Connections window asks Usage History for in one go.
public struct ServerReport {
    public let servers: [ServerUsage]
    public let hours: [(hour: Date, bytes: Int64)]
    /// The first hour any server was recorded: how far back there is to go.
    public let recordingSince: Date?
}

/// One app's traffic with one server over a period.
public struct ServerUsage: Equatable {
    public let appKey: String
    /// As `nettop` reported it, such as `142.250.180.14` or `2a00:1450:4001:82b::200e`,
    /// or `UsageHistory.otherServers` for an app's servers past its hourly limit.
    public let address: String
    public let bytesIn: Int64
    public let bytesOut: Int64
    /// The hour this app first talked to this server, as far back as history goes.
    public let firstSeen: Date
    /// The app as Usage History names it.
    public let appName: String
    public let bundlePath: String?
    public let isSystem: Bool
    /// The app that launched it, for a process with no bundle of its own.
    public let parentName: String?
    /// The name the content filter saw it connected by, such as `api.slack.com`.
    public let name: String?

    public var total: Int64 { bytesIn + bytesOut }

    public init(appKey: String, address: String, bytesIn: Int64, bytesOut: Int64,
                firstSeen: Date, appName: String, bundlePath: String? = nil,
                isSystem: Bool = false, parentName: String? = nil, name: String? = nil) {
        self.appKey = appKey
        self.address = address
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.firstSeen = firstSeen
        self.appName = appName
        self.bundlePath = bundlePath
        self.isSystem = isSystem
        self.parentName = parentName
        self.name = name
    }
}

public final class UsageHistory {

    /// A silence this long, typically a sleep, makes the next traffic a new
    /// visit even on the same network.
    public static let sessionGap: TimeInterval = 30 * 60

    /// How long a visit opened by traffic alone may still learn which network it
    /// is on.
    ///
    /// After a wake the first packets arrive before the path monitor's 2 s
    /// debounce has said where the Mac woke up. Those bytes travelled over the
    /// network about to be named, so the visit adopts it, rather than leaving a
    /// few-KB session behind on the network the lid was closed on. The same
    /// reasoning as `UsageStore.absorbOfflineBucket`.
    static let provisionalWindow: TimeInterval = 30

    private let database: SQLiteDatabase?
    private let queue = DispatchQueue(label: "com.networkmonitor.history", qos: .utility)
    private let calendar: Calendar

    /// Consulted for the open session each time it is written, so a verdict that
    /// arrives a moment after the network does still lands on the right visit.
    public var isMetered: () -> Bool = { false }

    /// Applied at most once a day, from `flush()`, and immediately when changed.
    /// The most servers an app keeps by address in one hour; the rest are added
    /// up under `otherServers`. A BitTorrent client or a video call can reach
    /// thousands of peers in an hour, and each would otherwise be a row of its
    /// own, every hour, for as long as history is kept. Counted from launch, so
    /// a relaunch partway through an hour can let an app keep up to twice as many.
    public static let serversPerAppPerHour = 500
    /// Where an app's servers beyond `serversPerAppPerHour` are added up.
    public static let otherServers = "*"
    private var serversThisHour: (hour: Int64, byApp: [String: Set<String>]) = (0, [:])

    public var retention: HistoryRetention = .forever {
        didSet { if retention != oldValue { prune(now: Date()) } }
    }
    private var lastPruned: Date?

    // Main-thread state.
    private struct NetworkRef: Equatable {
        var id: String
        var kind: NetworkFingerprint.Kind
        var label: String
    }
    private struct OpenSession {
        var id: Int64
        var network: NetworkRef
        var start: Date
        var lastSeen: Date
        var isMetered: Bool
        var provisionalUntil: Date?
    }
    private var open: OpenSession?
    private var lastWrittenOpen: SessionRow?
    private var lastJoined: NetworkRef?
    private var nextSessionID: Int64 = 1
    private var pending = Pending()

    public init(databaseURL: URL? = nil, calendar: Calendar = .current) {
        self.calendar = calendar
        let url = databaseURL ?? Self.defaultURL()
        self.database = Self.open(at: url)
        if let database {
            loadLatestSession(from: database)
        }
    }

    /// False only if the database could not be opened or created at all, in
    /// which case history is off and the rest of the app carries on.
    public var isAvailable: Bool { database != nil }

    // MARK: Recording

    /// Kernel interface bytes, from the 0.5 s sampler.
    public func recordInterface(bytesIn: Int64, bytesOut: Int64, now: Date = Date()) {
        guard bytesIn > 0 || bytesOut > 0, let slot = slot(at: now) else { return }
        pending.traffic[slot, default: Traffic()].add(interfaceIn: bytesIn, interfaceOut: bytesOut)
    }

    /// Server names the content filter saw, by address. Written with the next
    /// flush; the latest name for an address wins.
    public func noteServerNames(_ names: [(address: String, name: String)]) {
        guard database != nil else { return }
        for (address, name) in names { pending.names[address] = name }
    }

    /// One nettop sample: per-app internet bytes, the same bytes by server
    /// address (keyed by app key), and the LAN bytes that are kept out of every
    /// figure.
    public func recordApps(_ entries: [(identity: AppIdentity, bytesIn: Int64, bytesOut: Int64)],
                           servers: [String: [String: ByteCounts]] = [:],
                           localBytesIn: Int64 = 0, localBytesOut: Int64 = 0,
                           now: Date = Date()) {
        let moving = entries.filter { $0.bytesIn > 0 || $0.bytesOut > 0 }
        guard !moving.isEmpty || localBytesIn > 0 || localBytesOut > 0,
              let slot = slot(at: now)
        else { return }

        var traffic = pending.traffic[slot, default: Traffic()]
        traffic.localIn += localBytesIn
        traffic.localOut += localBytesOut
        var apps = pending.apps[slot, default: [:]]
        for entry in moving {
            traffic.appIn += entry.bytesIn
            traffic.appOut += entry.bytesOut
            apps[entry.identity.key, default: (0, 0)].bytesIn += entry.bytesIn
            apps[entry.identity.key, default: (0, 0)].bytesOut += entry.bytesOut
            // Latest naming wins, as in the store: a bundle can resolve after
            // the first sighting.
            pending.identities[entry.identity.key] = entry.identity
        }
        pending.traffic[slot] = traffic
        pending.apps[slot] = apps

        guard !servers.isEmpty else { return }
        if serversThisHour.hour != slot.hour { serversThisHour = (slot.hour, [:]) }
        var byServer = pending.servers[slot, default: [:]]
        for (appKey, addresses) in servers {
            var seen = serversThisHour.byApp[appKey, default: []]
            for (address, bytes) in addresses {
                var kept = address
                if !seen.contains(address) {
                    if seen.count < Self.serversPerAppPerHour { seen.insert(address) }
                    else { kept = Self.otherServers }
                }
                byServer[ServerKey(appKey: appKey, address: kept),
                         default: ByteCounts(bytesIn: 0, bytesOut: 0)] += bytes
            }
            serversThisHour.byApp[appKey] = seen
        }
        pending.servers[slot] = byServer
    }

    /// The store has pointed accumulation at `fingerprint`.
    ///
    /// `switched` is the store's own verdict that this is a different network
    /// from the last one joined. Offline is never a place, here as there, so it
    /// neither ends a visit nor starts one.
    public func join(_ fingerprint: NetworkFingerprint, label: String,
                     switched: Bool, now: Date = Date()) {
        guard database != nil, fingerprint.id != NetworkFingerprint.offline.id else { return }
        let network = NetworkRef(id: fingerprint.id, kind: fingerprint.kind, label: label)
        lastJoined = network

        if var current = open {
            let quiet = now.timeIntervalSince(current.lastSeen) >= Self.sessionGap
            // A change of kind is a new visit, so hours already counted keep the
            // kind they were counted as. Relabelled in place, one visit that
            // spanned home Wi-Fi and a hotspot read as all Hotspot (#70).
            if current.network.id == network.id && current.network.kind == network.kind
                && !switched && !quiet {
                // The same visit, perhaps renamed.
                current.network = network
                current.provisionalUntil = nil
                open = current
                return
            }
            if let until = current.provisionalUntil, now <= until {
                // The visit traffic opened was on this network all along.
                current.network = network
                current.provisionalUntil = nil
                open = current
                return
            }
        }
        closeOpenSession(reevaluatingMetered: true)
        startSession(on: network, at: now, provisional: false)
    }

    /// The session traffic at `now` belongs to, and the hour it falls in.
    private func slot(at now: Date) -> Slot? {
        guard database != nil else { return nil }
        if var current = open, now.timeIntervalSince(current.lastSeen) < Self.sessionGap {
            // `max`, so a clock set backwards cannot rewind a session's end.
            current.lastSeen = max(current.lastSeen, now)
            open = current
        } else {
            // The first traffic ever, or the first after a long silence.
            let network = lastJoined ?? NetworkRef(
                id: NetworkFingerprint.offline.id, kind: .offline,
                label: NetworkFingerprint.offline.defaultLabel)
            startSession(on: network, at: now, provisional: true)
        }
        return Slot(hour: hourStart(now), session: open!.id)
    }

    private func startSession(on network: NetworkRef, at now: Date, provisional: Bool) {
        closeOpenSession(reevaluatingMetered: false)
        open = OpenSession(id: nextSessionID, network: network, start: now, lastSeen: now,
                           isMetered: false,
                           provisionalUntil: provisional ? now + Self.provisionalWindow : nil)
        nextSessionID += 1
    }

    /// Settles the open session's row.
    ///
    /// On a network change the verdict is read once more, because it still
    /// describes the session being closed: the store reports a new network
    /// before metering re-evaluates. After a long silence it is not read, since
    /// by then it may describe wherever the Mac woke up; the session keeps the
    /// verdict from its last write.
    private func closeOpenSession(reevaluatingMetered: Bool) {
        guard var current = open else { return }
        if reevaluatingMetered { current.isMetered = isMetered() }
        pending.sessions[current.id] = SessionRow(current)
        open = nil
        lastWrittenOpen = nil
    }

    private func hourStart(_ date: Date) -> Int64 {
        let start = calendar.dateInterval(of: .hour, for: date)?.start ?? date
        return Int64(start.timeIntervalSince1970)
    }

    // MARK: Writing

    /// Writes everything recorded since the last flush, synchronously.
    ///
    /// Synchronous on purpose: it is called on quit, when an asynchronous
    /// write would race the process exiting. A flush is a handful of upserts in
    /// one transaction, well under a millisecond.
    public func flush(now: Date = Date()) {
        guard let database else { return }
        if var current = open {
            current.isMetered = isMetered()
            open = current
            let row = SessionRow(current)
            if row != lastWrittenOpen {
                pending.sessions[current.id] = row
                lastWrittenOpen = row
            }
        }
        if !pending.isEmpty {
            let batch = pending
            pending = Pending()
            queue.sync { Self.write(batch, to: database) }
        }
        if let lastPruned, calendar.isDate(lastPruned, inSameDayAs: now) { return }
        prune(now: now)
    }

    private static func write(_ batch: Pending, to database: SQLiteDatabase) {
        do {
            try database.transaction {
                let sessions = try database.prepare("""
                    INSERT INTO sessions (id, network_id, kind, label, started_at, ended_at, metered)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                    ON CONFLICT(id) DO UPDATE SET
                        network_id = excluded.network_id, kind = excluded.kind,
                        label = excluded.label, ended_at = excluded.ended_at,
                        metered = excluded.metered
                    """)
                for row in batch.sessions.values {
                    try sessions.run([.int(row.id), .text(row.networkID), .text(row.kind.rawValue),
                                      .text(row.label), .real(row.start.timeIntervalSince1970),
                                      .real(row.end.timeIntervalSince1970),
                                      .int(row.isMetered ? 1 : 0)])
                }

                let apps = try database.prepare("""
                    INSERT INTO apps (key, name, bundle_path, is_system, parent_key, parent_name, parent_bundle_path)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                    ON CONFLICT(key) DO UPDATE SET
                        name = excluded.name, bundle_path = excluded.bundle_path,
                        is_system = excluded.is_system, parent_key = excluded.parent_key,
                        parent_name = excluded.parent_name,
                        parent_bundle_path = excluded.parent_bundle_path
                    """)
                for identity in batch.identities.values {
                    try apps.run([.text(identity.key), .text(identity.displayName),
                                  identity.bundlePath.map { .text($0) } ?? .null,
                                  .int(identity.isSystem ? 1 : 0),
                                  identity.parent.map { .text($0.key) } ?? .null,
                                  identity.parent.map { .text($0.displayName) } ?? .null,
                                  identity.parent.map { .text($0.bundlePath) } ?? .null])
                }

                let traffic = try database.prepare("""
                    INSERT INTO traffic (hour, session_id, iface_in, iface_out, local_in, local_out, app_in, app_out)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                    ON CONFLICT(hour, session_id) DO UPDATE SET
                        iface_in = iface_in + excluded.iface_in,
                        iface_out = iface_out + excluded.iface_out,
                        local_in = local_in + excluded.local_in,
                        local_out = local_out + excluded.local_out,
                        app_in = app_in + excluded.app_in,
                        app_out = app_out + excluded.app_out
                    """)
                for (slot, sums) in batch.traffic {
                    try traffic.run([.int(slot.hour), .int(slot.session),
                                     .int(sums.interfaceIn), .int(sums.interfaceOut),
                                     .int(sums.localIn), .int(sums.localOut),
                                     .int(sums.appIn), .int(sums.appOut)])
                }

                let appTraffic = try database.prepare("""
                    INSERT INTO app_traffic (hour, session_id, app_key, bytes_in, bytes_out)
                    VALUES (?1, ?2, ?3, ?4, ?5)
                    ON CONFLICT(hour, session_id, app_key) DO UPDATE SET
                        bytes_in = bytes_in + excluded.bytes_in,
                        bytes_out = bytes_out + excluded.bytes_out
                    """)
                for (slot, apps) in batch.apps {
                    for (key, sums) in apps {
                        try appTraffic.run([.int(slot.hour), .int(slot.session), .text(key),
                                            .int(sums.bytesIn), .int(sums.bytesOut)])
                    }
                }
            }
        } catch {
            // Dropped rather than retried: a database that refuses one write
            // will refuse the next, and holding the batch would grow without
            // bound. The popover's own totals are unaffected.
            NSLog("NetworkMonitor: history write failed: \(error)")
        }

        // Servers in a transaction of their own: whatever goes wrong with them
        // must never cost Usage History the figures above.
        guard !batch.servers.isEmpty || !batch.names.isEmpty else { return }
        do {
            try database.transaction {
                // Names first, so the servers written below keep theirs.
                let named = try database.prepare("""
                    INSERT INTO servers (address, name) VALUES (?1, ?2)
                    ON CONFLICT(address) DO UPDATE SET name = excluded.name
                    """)
                for (address, name) in batch.names {
                    try named.run([.text(address), .text(name)])
                }

                // Three small upserts per app and server, each on an index. A
                // flush carries at most a few hundred, so resolving ids in SQL
                // costs less than keeping a cache of them in sync. `MIN`, because
                // a flush that spans an hour boundary holds two hours in no
                // particular order.
                let server = try database.prepare("""
                    INSERT INTO servers (address) VALUES (?1) ON CONFLICT(address) DO NOTHING
                    """)
                let appServer = try database.prepare("""
                    INSERT INTO app_servers (app_key, server_id, first_seen)
                    VALUES (?1, (SELECT id FROM servers WHERE address = ?2), ?3)
                    ON CONFLICT(app_key, server_id) DO UPDATE SET
                        first_seen = MIN(first_seen, excluded.first_seen)
                    """)
                let serverTraffic = try database.prepare("""
                    INSERT INTO server_traffic (hour, session_id, app_server_id, bytes_in, bytes_out)
                    VALUES (?1, ?2,
                            (SELECT a.id FROM app_servers a JOIN servers v ON v.id = a.server_id
                             WHERE a.app_key = ?3 AND v.address = ?4),
                            ?5, ?6)
                    ON CONFLICT(hour, session_id, app_server_id) DO UPDATE SET
                        bytes_in = bytes_in + excluded.bytes_in,
                        bytes_out = bytes_out + excluded.bytes_out
                    """)
                for (slot, servers) in batch.servers {
                    for (key, sums) in servers {
                        try server.run([.text(key.address)])
                        try appServer.run([.text(key.appKey), .text(key.address),
                                           .real(TimeInterval(slot.hour))])
                        try serverTraffic.run([.int(slot.hour), .int(slot.session),
                                               .text(key.appKey), .text(key.address),
                                               .int(sums.bytesIn), .int(sums.bytesOut)])
                    }
                }
            }
        } catch {
            NSLog("NetworkMonitor: writing servers failed: \(error)")
        }
    }

    // MARK: Retention

    /// Deletes everything older than the retention window allows.
    public func prune(now: Date = Date()) {
        lastPruned = now
        guard let database, let cutoff = retention.cutoff(now: now, calendar: calendar) else { return }
        let keep = open?.id ?? -1
        queue.sync {
            do {
                try database.transaction {
                    let hour = Int64(cutoff.timeIntervalSince1970)
                    try database.prepare("DELETE FROM traffic WHERE hour < ?1").run([.int(hour)])
                    try database.prepare("DELETE FROM app_traffic WHERE hour < ?1").run([.int(hour)])
                    try database.prepare("DELETE FROM server_traffic WHERE hour < ?1").run([.int(hour)])
                    try database.prepare("DELETE FROM sessions WHERE ended_at < ?1 AND id != ?2")
                        .run([.real(cutoff.timeIntervalSince1970), .int(keep)])
                    try database.execute("""
                        DELETE FROM apps WHERE key NOT IN (SELECT DISTINCT app_key FROM app_traffic)
                        """)
                    try database.execute("""
                        DELETE FROM app_servers
                        WHERE id NOT IN (SELECT DISTINCT app_server_id FROM server_traffic)
                        """)
                    try database.execute("""
                        DELETE FROM servers WHERE id NOT IN (SELECT DISTINCT server_id FROM app_servers)
                        """)
                }
                try database.execute("PRAGMA incremental_vacuum")
            } catch {
                NSLog("NetworkMonitor: history prune failed: \(error)")
            }
        }
    }

    /// Deletes all history. The visit in progress carries on as a new session
    /// from `now`, so nothing from before the clear can reappear.
    public func clear(now: Date = Date()) {
        guard let database else { return }
        pending = Pending()
        serversThisHour = (0, [:])
        lastWrittenOpen = nil
        if let current = open {
            open = OpenSession(id: nextSessionID, network: current.network, start: now,
                               lastSeen: now, isMetered: current.isMetered,
                               provisionalUntil: current.provisionalUntil)
            nextSessionID += 1
        }
        queue.sync {
            do {
                try database.transaction {
                    for table in ["server_traffic", "app_servers", "servers",
                                  "app_traffic", "traffic", "sessions", "apps"] {
                        try database.execute("DELETE FROM \(table)")
                    }
                }
                try database.execute("PRAGMA incremental_vacuum")
            } catch {
                NSLog("NetworkMonitor: clearing history failed: \(error)")
            }
        }
    }

    // MARK: Reading

    /// The report for one period, computed off the main thread and delivered on
    /// it. Writes what is pending first, so the current hour is never missing.
    public func loadReport(for period: HistoryPeriod, filter: HistoryFilter = HistoryFilter(),
                           completion: @escaping (HistoryReport) -> Void) {
        guard let database else {
            completion(.empty(period, filter, calendar: calendar))
            return
        }
        flush()
        let calendar = calendar
        queue.async {
            let report = Self.query(database, period: period, filter: filter, calendar: calendar)
            DispatchQueue.main.async { completion(report) }
        }
    }

    /// The same report, synchronously. For tests and for export.
    public func report(for period: HistoryPeriod,
                       filter: HistoryFilter = HistoryFilter()) -> HistoryReport {
        guard let database else { return .empty(period, filter, calendar: calendar) }
        flush()
        let calendar = calendar
        return queue.sync { Self.query(database, period: period, filter: filter, calendar: calendar) }
    }

    /// Which servers each app talked to in `period`, biggest first,
    /// synchronously. The Connections window names them and groups them by
    /// company, country and app.
    public func servers(in period: HistoryPeriod,
                        filter: HistoryFilter = HistoryFilter()) -> [ServerUsage] {
        servers(from: period.start, to: period.end, filter: filter)
    }

    /// The same for any span of whole hours, such as the part of a day picked
    /// on the Connections window's timeline.
    public func servers(from start: Date, to end: Date,
                        filter: HistoryFilter = HistoryFilter()) -> [ServerUsage] {
        guard let database else { return [] }
        flush()
        return queue.sync { Self.queryServers(database, from: start, to: end, filter: filter) }
    }

    /// Bytes to and from servers, hour by hour, for the Connections window's
    /// timeline. Hours with none are left out.
    public func serverHours(from start: Date, to end: Date,
                            filter: HistoryFilter = HistoryFilter()) -> [(hour: Date, bytes: Int64)] {
        guard let database else { return [] }
        flush()
        return queue.sync { Self.queryServerHours(database, from: start, to: end, filter: filter) }
    }

    /// What the Connections window shows: the servers in `span`, the period's
    /// hourly totals, and the first hour any server was recorded. Computed off
    /// the main thread and delivered on it, after writing what's pending, as
    /// `loadReport` does.
    public func loadServers(in span: DateInterval, hoursOf period: DateInterval,
                            filter: HistoryFilter,
                            completion: @escaping (ServerReport) -> Void) {
        guard let database else {
            completion(ServerReport(servers: [], hours: [], recordingSince: nil))
            return
        }
        flush()
        queue.async {
            let report = ServerReport(
                servers: Self.queryServers(database, from: span.start, to: span.end, filter: filter),
                hours: Self.queryServerHours(database, from: period.start, to: period.end, filter: filter),
                recordingSince: (try? database.scalar("SELECT MIN(hour) FROM server_traffic"))
                    .map { Date(timeIntervalSince1970: TimeInterval($0)) })
            DispatchQueue.main.async { completion(report) }
        }
    }

    private static func queryServers(_ database: SQLiteDatabase, from start: Date, to end: Date,
                                     filter: HistoryFilter) -> [ServerUsage] {
        let (whereSQL, values) = conditions(filter, hourColumn: "t.hour", appTable: "a")
        do {
            let query = try database.prepare("""
                SELECT a.app_key, v.address, SUM(t.bytes_in), SUM(t.bytes_out), a.first_seen,
                       p.name, p.bundle_path, p.is_system, p.parent_name, v.name
                FROM server_traffic t
                JOIN app_servers a ON a.id = t.app_server_id
                JOIN servers v ON v.id = a.server_id
                JOIN sessions s ON s.id = t.session_id
                LEFT JOIN apps p ON p.key = a.app_key
                WHERE \(whereSQL)
                GROUP BY t.app_server_id
                ORDER BY SUM(t.bytes_in) + SUM(t.bytes_out) DESC
                """)
            query.bind([.int(Int64(start.timeIntervalSince1970)),
                        .int(Int64(end.timeIntervalSince1970))] + values)
            var rows: [ServerUsage] = []
            while try query.step() {
                let key = query.string(0) ?? ""
                rows.append(ServerUsage(
                    appKey: key, address: query.string(1) ?? "",
                    bytesIn: query.int64(2), bytesOut: query.int64(3),
                    firstSeen: Date(timeIntervalSince1970: query.double(4)),
                    appName: query.string(5) ?? (key as NSString).lastPathComponent,
                    bundlePath: query.string(6), isSystem: query.int64(7) != 0,
                    parentName: query.string(8), name: query.string(9)))
            }
            return rows
        } catch {
            NSLog("NetworkMonitor: reading servers failed: \(error)")
            return []
        }
    }

    private static func queryServerHours(_ database: SQLiteDatabase, from start: Date, to end: Date,
                                         filter: HistoryFilter) -> [(hour: Date, bytes: Int64)] {
        let (whereSQL, values) = conditions(filter, hourColumn: "t.hour", appTable: "a")
        do {
            let query = try database.prepare("""
                SELECT t.hour, SUM(t.bytes_in + t.bytes_out)
                FROM server_traffic t
                JOIN app_servers a ON a.id = t.app_server_id
                JOIN sessions s ON s.id = t.session_id
                LEFT JOIN apps p ON p.key = a.app_key
                WHERE \(whereSQL)
                GROUP BY t.hour
                ORDER BY t.hour
                """)
            query.bind([.int(Int64(start.timeIntervalSince1970)),
                        .int(Int64(end.timeIntervalSince1970))] + values)
            var hours: [(hour: Date, bytes: Int64)] = []
            while try query.step() {
                hours.append((Date(timeIntervalSince1970: TimeInterval(query.int64(0))), query.int64(1)))
            }
            return hours
        } catch {
            NSLog("NetworkMonitor: reading server hours failed: \(error)")
            return []
        }
    }

    /// `WHERE` terms shared by every query, for the table aliased `s`
    /// (sessions) and the hour column `hourColumn`.
    private static func conditions(_ filter: HistoryFilter, hourColumn: String,
                                   appTable: String?) -> (sql: String, values: [SQLiteStatement.Value]) {
        var terms = ["\(hourColumn) >= ?1", "\(hourColumn) < ?2"]
        var values: [SQLiteStatement.Value] = []
        func add(_ term: String, _ value: SQLiteStatement.Value) {
            values.append(value)
            terms.append(term.replacingOccurrences(of: "?", with: "?\(values.count + 2)"))
        }
        if let id = filter.networkID { add("s.network_id = ?", .text(id)) }
        if let id = filter.sessionID { add("s.id = ?", .int(id)) }
        // `charted` folds a session that never learned its network into Other.
        if let kind = filter.kind?.charted {
            if kind == .other { terms.append("s.kind IN ('other', 'offline')") }
            else { add("s.kind = ?", .text(kind.rawValue)) }
        }
        if let key = filter.appKey, let appTable {
            values.append(.text(key))
            let index = values.count + 2
            terms.append("(\(appTable).app_key = ?\(index) OR p.parent_key = ?\(index))")
        }
        return (terms.joined(separator: " AND "), values)
    }

    private static func query(_ database: SQLiteDatabase, period: HistoryPeriod,
                              filter: HistoryFilter, calendar: Calendar) -> HistoryReport {
        let range: [SQLiteStatement.Value] = [.int(Int64(period.start.timeIntervalSince1970)),
                                              .int(Int64(period.end.timeIntervalSince1970))]
        do {
            // Sessions that overlap the period. Their kind colours the chart and
            // their totals fill the Sessions list.
            var sessions: [Int64: HistorySession] = [:]
            let sessionQuery = try database.prepare("""
                SELECT id, network_id, kind, label, started_at, ended_at, metered
                FROM sessions WHERE ended_at >= ?1 AND started_at < ?2
                """)
            sessionQuery.bind([.real(period.start.timeIntervalSince1970),
                               .real(period.end.timeIntervalSince1970)])
            while try sessionQuery.step() {
                let session = HistorySession(
                    id: sessionQuery.int64(0),
                    networkID: sessionQuery.string(1) ?? "",
                    kind: NetworkFingerprint.Kind(rawValue: sessionQuery.string(2) ?? "") ?? .other,
                    defaultLabel: sessionQuery.string(3) ?? "Network",
                    start: Date(timeIntervalSince1970: sessionQuery.double(4)),
                    end: Date(timeIntervalSince1970: sessionQuery.double(5)),
                    isMetered: sessionQuery.int64(6) != 0)
                sessions[session.id] = session
            }

            // Hourly totals. With an app chosen they are that app's bytes;
            // otherwise the internet figure, clamped exactly as the popover's is.
            let hourly: SQLiteStatement
            if filter.appKey != nil {
                let (whereSQL, values) = conditions(filter, hourColumn: "a.hour", appTable: "a")
                hourly = try database.prepare("""
                    SELECT a.hour, a.session_id, SUM(a.bytes_in), SUM(a.bytes_out)
                    FROM app_traffic a
                    JOIN apps p ON p.key = a.app_key
                    JOIN sessions s ON s.id = a.session_id
                    WHERE \(whereSQL)
                    GROUP BY a.hour, a.session_id
                    """)
                hourly.bind(range + values)
            } else {
                let (whereSQL, values) = conditions(filter, hourColumn: "t.hour", appTable: nil)
                hourly = try database.prepare("""
                    SELECT t.hour, t.session_id,
                           MIN(t.iface_in, MAX(t.iface_in - t.local_in, t.app_in)),
                           MIN(t.iface_out, MAX(t.iface_out - t.local_out, t.app_out))
                    FROM traffic t
                    JOIN sessions s ON s.id = t.session_id
                    WHERE \(whereSQL)
                    """)
                hourly.bind(range + values)
            }

            let binIntervals = period.bins(calendar: calendar)
            let binStarts = binIntervals.map(\.start)
            var binKinds = Array(repeating: [NetworkFingerprint.Kind: Int64](), count: binIntervals.count)
            var byKind: [NetworkFingerprint.Kind: Int64] = [:]
            var bytesIn: Int64 = 0, bytesOut: Int64 = 0, metered: Int64 = 0
            var bySession: [Int64: Int64] = [:]

            while try hourly.step() {
                let hour = Date(timeIntervalSince1970: TimeInterval(hourly.int64(0)))
                let sessionID = hourly.int64(1)
                let inBytes = max(hourly.int64(2), 0), outBytes = max(hourly.int64(3), 0)
                let bytes = inBytes + outBytes
                guard bytes > 0 else { continue }
                let session = sessions[sessionID]
                let kind = (session?.kind ?? .other).charted

                bytesIn += inBytes
                bytesOut += outBytes
                byKind[kind, default: 0] += bytes
                bySession[sessionID, default: 0] += bytes
                if session?.isMetered == true { metered += bytes }
                if let index = binIndex(of: hour, in: binStarts) {
                    binKinds[index][kind, default: 0] += bytes
                }
            }

            // Per-app totals, nested and grouped exactly as the popover does,
            // and split by the kind of network, which colours each app's bar.
            let (appWhere, appValues) = conditions(filter, hourColumn: "a.hour", appTable: "a")
            let appQuery = try database.prepare("""
                SELECT a.app_key, p.name, p.bundle_path, p.is_system,
                       p.parent_key, p.parent_name, p.parent_bundle_path,
                       SUM(a.bytes_in), SUM(a.bytes_out), s.kind
                FROM app_traffic a
                JOIN apps p ON p.key = a.app_key
                JOIN sessions s ON s.id = a.session_id
                WHERE \(appWhere)
                GROUP BY a.app_key, s.kind
                """)
            appQuery.bind(range + appValues)
            var apps: [String: AppTotals] = [:]
            var appKinds: [String: [NetworkFingerprint.Kind: Int64]] = [:]
            while try appQuery.step() {
                let key = appQuery.string(0) ?? ""
                let parent: ParentApp? = appQuery.string(4).map {
                    ParentApp(key: $0, displayName: appQuery.string(5) ?? "",
                              bundlePath: appQuery.string(6) ?? "")
                }
                let inBytes = appQuery.int64(7), outBytes = appQuery.int64(8)
                var totals = apps[key] ?? AppTotals(displayName: appQuery.string(1) ?? key,
                                                    bundlePath: appQuery.string(2),
                                                    isSystem: appQuery.int64(3) != 0,
                                                    parent: parent)
                totals.bytesIn += inBytes
                totals.bytesOut += outBytes
                apps[key] = totals
                let kind = (NetworkFingerprint.Kind(rawValue: appQuery.string(9) ?? "") ?? .other).charted
                appKinds[key, default: [:]][kind, default: 0] += inBytes + outBytes
            }
            let partitioned = UsageRow.partition(apps: apps, lastActivity: [:], now: period.start,
                                                 kinds: appKinds)

            // Networks: the period's visits grouped by where they were, named
            // after the most recent one.
            var networks: [String: HistoryReport.NetworkTotal] = [:]
            let sessionTotals = bySession.compactMap { id, bytes -> HistoryReport.SessionTotal? in
                sessions[id].map { HistoryReport.SessionTotal(session: $0, bytes: bytes) }
            }
            for total in sessionTotals.sorted(by: { $0.session.start < $1.session.start }) {
                let session = total.session
                let previous = networks[session.networkID]
                networks[session.networkID] = HistoryReport.NetworkTotal(
                    id: session.networkID, kind: session.kind,
                    defaultLabel: session.defaultLabel,
                    bytes: (previous?.bytes ?? 0) + total.bytes,
                    isMetered: (previous?.isMetered ?? false) || session.isMetered)
            }

            let since = try database.scalar("SELECT MIN(hour) FROM traffic")
                .map { Date(timeIntervalSince1970: TimeInterval($0)) }

            return HistoryReport(
                period: period, filter: filter,
                bins: zip(binIntervals, binKinds).map { HistoryReport.Bin(interval: $0, byKind: $1) },
                byKind: byKind, bytesIn: bytesIn, bytesOut: bytesOut, meteredBytes: metered,
                apps: partitioned.apps, systemRows: partitioned.system,
                systemTotal: partitioned.systemTotal,
                networks: networks.values.sorted {
                    $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.defaultLabel < $1.defaultLabel
                },
                sessions: sessionTotals.sorted { $0.session.start > $1.session.start },
                recordingSince: since)
        } catch {
            NSLog("NetworkMonitor: history query failed: \(error)")
            return .empty(period, filter, calendar: calendar)
        }
    }

    /// The bar `date` falls in, by binary search over the bars' start times.
    public static func binIndex(of date: Date, in starts: [Date]) -> Int? {
        guard let first = starts.first, date >= first else { return nil }
        var low = 0, high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= date { low = middle } else { high = middle - 1 }
        }
        return low
    }

    // MARK: Export

    /// The period as CSV, one line per app per hour per visit, in bytes.
    ///
    /// Hourly and per app because that is everything the history holds; a
    /// spreadsheet can total it up any way it likes, and could not split a
    /// daily figure back apart. Without an app filter, each hour also carries a
    /// "Not attributed to an app" line for the bytes the kernel counted that no
    /// process owned, so the file adds up to the same total as the window.
    public func exportCSV(for period: HistoryPeriod, filter: HistoryFilter = HistoryFilter(),
                          networkName: (String) -> String? = { _ in nil }) -> String {
        var lines = ["Hour,Network,Network Type,Metered,App,Downloaded (bytes),Uploaded (bytes)"]
        guard let database else { return lines.joined(separator: "\n") + "\n" }
        flush()

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        let range: [SQLiteStatement.Value] = [.int(Int64(period.start.timeIntervalSince1970)),
                                              .int(Int64(period.end.timeIntervalSince1970))]
        queue.sync {
            do {
                func line(_ hour: Int64, _ networkID: String, _ label: String, _ kind: String,
                          _ metered: Bool, _ app: String, _ bytesIn: Int64, _ bytesOut: Int64) -> String {
                    let date = Date(timeIntervalSince1970: TimeInterval(hour))
                    let kindLabel = (NetworkFingerprint.Kind(rawValue: kind) ?? .other).historyLabel
                    return [formatter.string(from: date), networkName(networkID) ?? label, kindLabel,
                            metered ? "Yes" : "No", app, String(bytesIn), String(bytesOut)]
                        .map(Self.csvField).joined(separator: ",")
                }

                // App lines, keyed by hour and session so the unattributed
                // remainder can be slotted in after each group.
                var appLines: [String: [String]] = [:]
                let (appWhere, appValues) = Self.conditions(filter, hourColumn: "a.hour", appTable: "a")
                let apps = try database.prepare("""
                    SELECT a.hour, s.id, s.network_id, s.label, s.kind, s.metered, p.name,
                           a.bytes_in, a.bytes_out
                    FROM app_traffic a
                    JOIN apps p ON p.key = a.app_key
                    JOIN sessions s ON s.id = a.session_id
                    WHERE \(appWhere)
                    ORDER BY a.hour, s.id, a.bytes_in + a.bytes_out DESC
                    """)
                apps.bind(range + appValues)
                var order: [String] = []
                while try apps.step() {
                    let key = "\(apps.int64(0)):\(apps.int64(1))"
                    if appLines[key] == nil { order.append(key) }
                    appLines[key, default: []].append(line(
                        apps.int64(0), apps.string(2) ?? "", apps.string(3) ?? "",
                        apps.string(4) ?? "", apps.int64(5) != 0, apps.string(6) ?? "",
                        apps.int64(7), apps.int64(8)))
                }

                guard filter.appKey == nil else {
                    for key in order { lines += appLines[key] ?? [] }
                    return
                }

                let (whereSQL, values) = Self.conditions(filter, hourColumn: "t.hour", appTable: nil)
                let totals = try database.prepare("""
                    SELECT t.hour, s.id, s.network_id, s.label, s.kind, s.metered,
                           MIN(t.iface_in, MAX(t.iface_in - t.local_in, t.app_in)) - t.app_in,
                           MIN(t.iface_out, MAX(t.iface_out - t.local_out, t.app_out)) - t.app_out
                    FROM traffic t
                    JOIN sessions s ON s.id = t.session_id
                    WHERE \(whereSQL)
                    ORDER BY t.hour, s.id
                    """)
                totals.bind(range + values)
                var written = Set<String>()
                while try totals.step() {
                    let key = "\(totals.int64(0)):\(totals.int64(1))"
                    lines += appLines[key] ?? []
                    written.insert(key)
                    let restIn = max(totals.int64(6), 0), restOut = max(totals.int64(7), 0)
                    if restIn > 0 || restOut > 0 {
                        lines.append(line(totals.int64(0), totals.string(2) ?? "",
                                          totals.string(3) ?? "", totals.string(4) ?? "",
                                          totals.int64(5) != 0, "Not attributed to an app",
                                          restIn, restOut))
                    }
                }
                // App lines in an hour the interface sampler never reached.
                for key in order where !written.contains(key) { lines += appLines[key] ?? [] }
            } catch {
                NSLog("NetworkMonitor: history export failed: \(error)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Quoted only when it has to be, with quotes doubled, per RFC 4180.
    public static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
        else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: Opening

    private static func defaultURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = support.appendingPathComponent("NetworkMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("history.sqlite")
    }

    /// Opens or creates the database. A file that will not open is moved aside,
    /// never deleted: it is the user's history, and it might be recoverable.
    private static func open(at url: URL) -> SQLiteDatabase? {
        if let database = try? openAndMigrate(url) { return database }
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = url.deletingPathExtension()
            .appendingPathExtension("unreadable-\(stamp).sqlite")
        try? FileManager.default.moveItem(at: url, to: aside)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
        return try? openAndMigrate(url)
    }

    private static func openAndMigrate(_ url: URL) throws -> SQLiteDatabase {
        let database = try SQLiteDatabase(url: url)
        // Must precede the first table, or it has no effect on this file.
        try database.execute("PRAGMA auto_vacuum = INCREMENTAL")
        // WAL with NORMAL sync: a write every 15 s costs an append, not an
        // fsync, and a crash can lose only the last moments — never corrupt.
        try database.execute("PRAGMA journal_mode = WAL")
        try database.execute("PRAGMA synchronous = NORMAL")
        try database.execute("""
            CREATE TABLE IF NOT EXISTS sessions (
                id INTEGER PRIMARY KEY,
                network_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                label TEXT NOT NULL,
                started_at REAL NOT NULL,
                ended_at REAL NOT NULL,
                metered INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS sessions_by_end ON sessions (ended_at);
            CREATE TABLE IF NOT EXISTS apps (
                key TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                bundle_path TEXT,
                is_system INTEGER NOT NULL DEFAULT 0,
                parent_key TEXT,
                parent_name TEXT,
                parent_bundle_path TEXT
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS traffic (
                hour INTEGER NOT NULL,
                session_id INTEGER NOT NULL,
                iface_in INTEGER NOT NULL DEFAULT 0,
                iface_out INTEGER NOT NULL DEFAULT 0,
                local_in INTEGER NOT NULL DEFAULT 0,
                local_out INTEGER NOT NULL DEFAULT 0,
                app_in INTEGER NOT NULL DEFAULT 0,
                app_out INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (hour, session_id)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS app_traffic (
                hour INTEGER NOT NULL,
                session_id INTEGER NOT NULL,
                app_key TEXT NOT NULL,
                bytes_in INTEGER NOT NULL DEFAULT 0,
                bytes_out INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (hour, session_id, app_key)
            ) WITHOUT ROWID;
            -- Connections (#115). Each app and server pair is stored once, so the
            -- hourly rows carry a small number instead of an app's path.
            CREATE TABLE IF NOT EXISTS servers (
                id INTEGER PRIMARY KEY,
                address TEXT NOT NULL UNIQUE,
                name TEXT
            );
            CREATE TABLE IF NOT EXISTS app_servers (
                id INTEGER PRIMARY KEY,
                app_key TEXT NOT NULL,
                server_id INTEGER NOT NULL,
                first_seen REAL NOT NULL,
                UNIQUE (app_key, server_id)
            );
            CREATE TABLE IF NOT EXISTS server_traffic (
                hour INTEGER NOT NULL,
                session_id INTEGER NOT NULL,
                app_server_id INTEGER NOT NULL,
                bytes_in INTEGER NOT NULL DEFAULT 0,
                bytes_out INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (hour, session_id, app_server_id)
            ) WITHOUT ROWID;
            PRAGMA user_version = 1;
            """)
        // Databases from before #128 have servers without a name column.
        if (try? database.scalar("SELECT COUNT(*) FROM pragma_table_info('servers') WHERE name = 'name'")) == 0 {
            try database.execute("ALTER TABLE servers ADD COLUMN name TEXT")
        }
        return database
    }

    /// Picks up where the last run left off: the newest session stays open, so
    /// a relaunch on the same network inside `sessionGap` continues it.
    private func loadLatestSession(from database: SQLiteDatabase) {
        queue.sync {
            guard let statement = try? database.prepare("""
                SELECT id, network_id, kind, label, started_at, ended_at, metered
                FROM sessions ORDER BY id DESC LIMIT 1
                """),
                  (try? statement.step()) == true
            else { return }
            let network = NetworkRef(
                id: statement.string(1) ?? NetworkFingerprint.offline.id,
                kind: NetworkFingerprint.Kind(rawValue: statement.string(2) ?? "") ?? .other,
                label: statement.string(3) ?? "Network")
            let session = OpenSession(
                id: statement.int64(0), network: network,
                start: Date(timeIntervalSince1970: statement.double(4)),
                lastSeen: Date(timeIntervalSince1970: statement.double(5)),
                isMetered: statement.int64(6) != 0, provisionalUntil: nil)
            open = session
            lastWrittenOpen = SessionRow(session)
            nextSessionID = session.id + 1
            if network.id != NetworkFingerprint.offline.id { lastJoined = network }
        }
    }

    // MARK: Pending writes

    private struct Slot: Hashable {
        let hour: Int64
        let session: Int64
    }

    private struct Traffic {
        var interfaceIn: Int64 = 0
        var interfaceOut: Int64 = 0
        var localIn: Int64 = 0
        var localOut: Int64 = 0
        var appIn: Int64 = 0
        var appOut: Int64 = 0

        mutating func add(interfaceIn: Int64, interfaceOut: Int64) {
            self.interfaceIn += interfaceIn
            self.interfaceOut += interfaceOut
        }
    }

    private struct SessionRow: Equatable {
        let id: Int64
        let networkID: String
        let kind: NetworkFingerprint.Kind
        let label: String
        let start: Date
        let end: Date
        let isMetered: Bool

        init(_ session: OpenSession) {
            id = session.id
            networkID = session.network.id
            kind = session.network.kind
            label = session.network.label
            start = session.start
            end = session.lastSeen
            isMetered = session.isMetered
        }
    }

    private struct ServerKey: Hashable {
        let appKey: String
        let address: String
    }

    private struct Pending {
        var traffic: [Slot: Traffic] = [:]
        var apps: [Slot: [String: (bytesIn: Int64, bytesOut: Int64)]] = [:]
        var servers: [Slot: [ServerKey: ByteCounts]] = [:]
        /// Server names from the content filter, by address.
        var names: [String: String] = [:]
        var identities: [String: AppIdentity] = [:]
        var sessions: [Int64: SessionRow] = [:]

        var isEmpty: Bool {
            traffic.isEmpty && apps.isEmpty && servers.isEmpty && names.isEmpty && identities.isEmpty
                && sessions.isEmpty
        }
    }
}
