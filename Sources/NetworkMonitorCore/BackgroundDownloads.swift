import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "com.kevinabouhanna.NetworkMonitor", category: "background-downloads")

/// Only the sockets already seen by the main nettop stream. The log supplies
/// ownership, never byte counts.
struct BackgroundSocket: Equatable {
    enum Transport: Hashable { case tcp, quic }

    enum Address: Hashable {
        case v4(Network.IPv4Address)
        case v6(Network.IPv6Address)

        init?(_ raw: String) {
            let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let address = String(host.prefix { $0 != "%" })
            if let v4 = Network.IPv4Address(address) { self = .v4(v4) }
            else if let v6 = Network.IPv6Address(address) { self = .v6(v6) }
            else { return nil }
        }
    }

    struct Key: Hashable {
        let pid: Int32
        let interface: String
        let transport: Transport
        let local: Address
        let localPort: Int
        let remotePort: Int
    }

    let key: Key
    let peer: Address
    let counts: ByteCounts
}

/// Matches closed sockets to their owners, retaining just the history slots
/// that were charged while each socket was visible.
struct BackgroundDownloads {
    struct Sample {
        let sockets: [BackgroundSocket]
        /// Nil when the sockets' deltas cannot safely come out of this sample.
        let source: String?
    }

    struct Observation {
        let samples: [Sample]
        let time: Date
    }

    struct Charge: Hashable {
        let slot: UsageHistory.AppSlot
        let source: String
    }

    struct Closed {
        let key: BackgroundSocket.Key
        let peer: BackgroundSocket.Address
        let firstSeen: Date
        let lastSeen: Date
        /// The last sample it moved bytes in. nettop can list a socket for a
        /// moment after it closed, so the close is after this, not `lastSeen`.
        let lastActive: Date
        let missingAt: Date
        let charges: [Charge: ByteCounts]
        /// Log reads that found no owner yet: the close line can land in the
        /// log a moment after the socket is gone, so it's asked again.
        var attempts = 0

        /// Where the log is read from for its close: after its last bytes,
        /// and never more than a window before it went.
        var readFrom: Date { max(lastActive, missingAt - (BackgroundDownloads.window - 2)) }
    }

    /// How many hours or networks one socket's bytes may span. Past that,
    /// the whole socket stays under the daemon rather than half of it moving.
    static let maxCharges = 24
    /// How often a close is looked for before its bytes stay where they are.
    static let maxAttempts = 3
    /// The widest stretch of the log one query reads.
    static let window: TimeInterval = 40

    struct CloseRecord {
        let key: BackgroundSocket.Key
        let peer: BackgroundSocket.Address?
        let owner: String?
        let start: Date
        let end: Date

        static func parse(pid: Int32, time: Date, message: String) -> Self? {
            let lines = message.split(separator: "\n")
            guard let header = lines.first, header.hasSuffix("] cancelled"),
                  header.hasPrefix("[C"), message.contains("bytes in/out:"),
                  let interface = group(#"interface: ([A-Za-z][A-Za-z0-9]*[0-9])\b"#, in: message),
                  let duration = group(#"Duration: ([0-9]+(?:\.[0-9]+)?)s"#, in: message).flatMap(Double.init),
                  duration > 0, duration.isFinite else { return nil }

            // The header names what was asked for: a "quic-connection" can
            // end up on TCP (on macOS 27.2, a background download did). The
            // Duration line says which handshake ran, so it decides.
            let timing = lines.first { $0.contains("Duration: ") }.map(String.init) ?? ""
            let transport: BackgroundSocket.Transport
            if timing.contains("TCP @") { transport = .tcp }
            else if timing.contains("QUIC @") { transport = .quic }
            else if header.contains(" quic-connection,") { transport = .quic }
            else if header.contains(" tcp,") { transport = .tcp }
            else { return nil }

            let endpoints = lines.filter { $0.contains("<->") }
            guard endpoints.count == 1,
                  let path = endpoints.first.map(String.init),
                  let localHost = group(endpointsPattern, in: path),
                  let local = BackgroundSocket.Address(localHost),
                  let localPort = group(endpointsPattern, in: path, capture: 2).flatMap(Int.init),
                  let remote = group(endpointsPattern, in: path, capture: 3),
                  let remotePort = group(endpointsPattern, in: path, capture: 4).flatMap(Int.init),
                  (1...65535).contains(localPort), (1...65535).contains(remotePort) else { return nil }

            let peer = BackgroundSocket.Address(remote)
            let remoteHost = remote.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            guard peer != nil || remoteHost.range(of: #"^IPv[46]#[A-Fa-f0-9]+$"#, options: .regularExpression) != nil
            else { return nil }

            // Keep a close with an unknown owner in the candidate set. It
            // may be a competing socket when the remote address is hidden.
            let owner = group(#"bundle id: ([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+), "#, in: String(header))
            let key = BackgroundSocket.Key(pid: pid, interface: interface, transport: transport,
                                           local: local, localPort: localPort, remotePort: remotePort)
            return Self(key: key, peer: peer, owner: owner, start: time - duration, end: time)
        }

        private static let endpointsPattern = #"\s(\S+)[:.]([0-9]{1,5})<->(\S+)[:.]([0-9]{1,5})\]\s*$"#

        private static func group(_ pattern: String, in value: String, capture: Int = 1) -> String? {
            guard let match = try? NSRegularExpression(pattern: pattern)
                .firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  let range = Range(match.range(at: capture), in: value) else { return nil }
            return String(value[range])
        }
    }

    private struct Active {
        let peer: BackgroundSocket.Address
        let firstSeen: Date
        var lastSeen: Date
        var lastActive: Date
        var charges: [Charge: ByteCounts] = [:]
        /// More hours or networks than `maxCharges`: never moved.
        var overflowed = false
    }

    private var active: [BackgroundSocket.Key: Active] = [:]
    private var lastSample: Date?

    mutating func update(_ samples: [Sample], slot: UsageHistory.AppSlot?, now: Date) -> [Closed] {
        if let lastSample, now < lastSample || now.timeIntervalSince(lastSample) > 35 {
            active.removeAll()
        }
        lastSample = now
        if active.isEmpty && samples.isEmpty { return [] }

        let sockets = samples.flatMap { sample in sample.sockets.map { ($0, sample.source) } }
        // A collision is ambiguous even if one of the rows moved zero bytes.
        let byKey = Dictionary(grouping: sockets, by: { $0.0.key })
        guard byKey.count <= 128 else {
            active.removeAll()
            return []
        }

        var ended: [Closed] = []
        for (key, socket) in active where byKey[key] == nil && !socket.charges.isEmpty && !socket.overflowed {
            ended.append(Closed(key: key, peer: socket.peer, firstSeen: socket.firstSeen,
                                lastSeen: socket.lastSeen, lastActive: socket.lastActive,
                                missingAt: now, charges: socket.charges))
        }
        var next: [BackgroundSocket.Key: Active] = [:]
        for (key, observations) in byKey {
            guard observations.count == 1, let (socket, source) = observations.first else { continue }
            var tracked = active[key].flatMap { $0.peer == socket.peer ? $0 : nil }
                ?? Active(peer: socket.peer, firstSeen: now, lastSeen: now, lastActive: now)
            tracked.lastSeen = now
            if socket.counts.bytesIn > 0 || socket.counts.bytesOut > 0 { tracked.lastActive = now }
            if let slot, let source, socket.counts.bytesIn > 0 || socket.counts.bytesOut > 0 {
                let charge = Charge(slot: slot, source: source)
                if tracked.charges.count < Self.maxCharges || tracked.charges[charge] != nil {
                    tracked.charges[charge, default: ByteCounts(bytesIn: 0, bytesOut: 0)] += socket.counts
                } else {
                    tracked.overflowed = true
                }
            }
            next[key] = tracked
        }
        active = next
        return ended
    }

    /// How far the log's start and close may sit on the wrong side of the
    /// samples that saw the socket. The start is the close minus `Duration`,
    /// which can begin a few tens of milliseconds after nettop first listed
    /// the socket with its bytes (#785); nettop can see the last bytes a
    /// moment before the close says they moved. A key reused inside it by
    /// another app makes two owners, and then nothing moves.
    static let clockSlack: TimeInterval = 0.25

    static func owner(for socket: Closed, in records: [CloseRecord]) -> String? {
        let candidates = Set(records.lazy.filter {
            $0.key == socket.key
                && ($0.peer == nil || $0.peer == socket.peer)
                && $0.start <= socket.firstSeen + clockSlack
                && $0.end >= socket.lastActive - clockSlack
                && $0.end <= socket.missingAt + 1
        }.map(\.owner))
        return candidates.count == 1 ? (candidates.first ?? nil) : nil
    }
}

/// Reads a bounded slice of the local log only after observed sockets go away.
/// One query runs at a time. The system log is optional for a non-admin account.
final class BackgroundDownloadReader {
    private var tracking = BackgroundDownloads()
    private var pending: [BackgroundDownloads.Closed] = []
    private var reading = false
    private var retryAfter = Date.distantPast
    private let queue = DispatchQueue(label: "com.networkmonitor.background-downloads", qos: .utility) // untranslated: queue label

    func observe(_ samples: [BackgroundDownloads.Sample], slot: UsageHistory.AppSlot?, now: Date,
                 result: @escaping ([(String, BackgroundDownloads.Closed)]) -> Void) {
        guard now >= retryAfter else { return }
        pending.append(contentsOf: tracking.update(samples, slot: slot, now: now))
        if pending.count > 128 { pending.removeFirst(pending.count - 128) }
        read(result: result)
    }

    private func read(result: @escaping ([(String, BackgroundDownloads.Closed)]) -> Void) {
        guard !reading, !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        reading = true
        queue.asyncAfter(deadline: .now() + 1.25) { [weak self] in
            let records = try? Self.readLog(for: batch)
            var matched: [(String, BackgroundDownloads.Closed)] = []
            var unmatched: [BackgroundDownloads.Closed] = []
            for socket in batch {
                if let records, let owner = BackgroundDownloads.owner(for: socket, in: records) {
                    matched.append((owner, socket))
                } else {
                    unmatched.append(socket)
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.reading = false
                guard let records else {
                    log.info("the system log can't be read: background downloads stay under nsurlsessiond for 5 minutes")
                    self.retryAfter = Date() + 300
                    self.pending.removeAll()
                    return
                }
                for (owner, socket) in matched {
                    let bytes = socket.charges.values.reduce(0) { $0 + $1.bytesIn + $1.bytesOut }
                    log.info("background download of \(bytes, privacy: .public) bytes is \(owner, privacy: .public)'s")
                }
                for socket in unmatched where socket.attempts + 1 >= BackgroundDownloads.maxAttempts {
                    let near = records.filter { $0.key.localPort == socket.key.localPort }
                    log.debug("no owner for port \(socket.key.localPort, privacy: .public) (\(String(describing: socket.key.transport), privacy: .public)) seen \(socket.firstSeen.timeIntervalSince1970, privacy: .public)–\(socket.lastActive.timeIntervalSince1970, privacy: .public), gone \(socket.missingAt.timeIntervalSince1970, privacy: .public); \(records.count, privacy: .public) closes read, \(near.count, privacy: .public) on its port")
                }
                if !matched.isEmpty { result(matched) }
                // Not in the log yet, perhaps: asked again on the next read,
                // a few times at most.
                let again = unmatched.compactMap { socket -> BackgroundDownloads.Closed? in
                    var socket = socket
                    socket.attempts += 1
                    return socket.attempts < BackgroundDownloads.maxAttempts ? socket : nil
                }
                self.pending.insert(contentsOf: again, at: 0)
                self.read(result: result)
            }
        }
    }

    /// The batch's closes, read a window of the log at a time, so a batch
    /// gathered over a long read is never too wide to ask about.
    private static func readLog(for batch: [BackgroundDownloads.Closed]) throws -> [BackgroundDownloads.CloseRecord] {
        let store = try OSLogStore.local()
        var records: [BackgroundDownloads.CloseRecord] = []
        var window: [BackgroundDownloads.Closed] = []
        for socket in batch.sorted(by: { $0.readFrom < $1.readFrom }) {
            if let first = window.first, socket.missingAt.timeIntervalSince(first.readFrom) >= BackgroundDownloads.window {
                records += try readWindow(window, from: store)
                window = []
            }
            window.append(socket)
        }
        if !window.isEmpty { records += try readWindow(window, from: store) }
        return records
    }

    private static func readWindow(_ batch: [BackgroundDownloads.Closed],
                                   from store: OSLogStore) throws -> [BackgroundDownloads.CloseRecord] {
        guard let first = batch.map(\.readFrom).min(), let last = batch.map(\.missingAt).max() else { return [] }
        let query = NSPredicate(format: "process == %@ AND subsystem == %@ AND category == %@ AND eventMessage CONTAINS %@",
                                "nsurlsessiond", "com.apple.network", "connection", "bytes in/out:")
        let entries = try store.getEntries(at: store.position(date: first - 1), matching: query)
        var result: [BackgroundDownloads.CloseRecord] = []
        for (index, entry) in entries.enumerated() {
            if entry.date > last + 1 { break }
            // A partial answer could conceal a conflicting owner.
            if index >= 512 { return [] }
            guard entry.date >= first - 1, let log = entry as? OSLogEntryLog,
                  let pid = Int32(exactly: log.processIdentifier),
                  let close = BackgroundDownloads.CloseRecord.parse(pid: pid, time: entry.date,
                                                                      message: entry.composedMessage)
            else { continue }
            result.append(close)
        }
        return result
    }
}
