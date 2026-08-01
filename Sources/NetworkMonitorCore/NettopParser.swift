import Foundation

/// One process's byte movement within a single `nettop` sample.
public struct NettopRow: Equatable {
    public let pid: Int32
    /// Process name as `nettop` reports it — truncated to the kernel's 15-char
    /// `p_comm` limit, e.g. "Google Chrome H". Only a display fallback; real
    /// identity comes from `proc_pidpath`.
    public let processName: String
    /// Everything the process moved, local and internet together.
    public let bytesIn: Int64
    public let bytesOut: Int64
    /// The part of the above that never left the LAN, summed from the process's
    /// connection rows. Kept out of every displayed figure. See `RemoteEndpoint`.
    public let localBytesIn: Int64
    public let localBytesOut: Int64
    /// The subset of the local bytes trustworthy enough to subtract from the
    /// kernel's interface total: unicast LAN peers only, never multicast.
    public let subtractableLocalIn: Int64
    public let subtractableLocalOut: Int64

    /// What the app reports: bytes that actually crossed the internet.
    ///
    /// Clamped at zero because the two figures come from different rows of the
    /// same sample, and a process whose connections churn mid-sample can report
    /// slightly more local bytes than its parent row totals.
    public var internetBytesIn: Int64 { max(bytesIn - localBytesIn, 0) }
    public var internetBytesOut: Int64 { max(bytesOut - localBytesOut, 0) }

    public init(pid: Int32, processName: String, bytesIn: Int64, bytesOut: Int64,
                localBytesIn: Int64 = 0, localBytesOut: Int64 = 0,
                subtractableLocalIn: Int64 = 0, subtractableLocalOut: Int64 = 0) {
        self.pid = pid
        self.processName = processName
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.localBytesIn = localBytesIn
        self.localBytesOut = localBytesOut
        self.subtractableLocalIn = subtractableLocalIn
        self.subtractableLocalOut = subtractableLocalOut
    }
}

/// Parses the CSV stream produced by
/// `nettop -P -x -d -L 0 -s 1 -J time,bytes_in,bytes_out`.
///
/// Two findings drove this design, both verified against `nettop` on macOS 26:
///
/// 1. **Delta mode is mandatory.** In cumulative mode a process total is the sum
///    over its *currently live* sockets, so it goes **down** when a socket
///    closes — Google Chrome Helper was observed at
///    `4529465 → 4529330 → 4523833 → 4518819`. Diffing those snapshots
///    under-counts every app that opens and closes connections. With `-d`, the
///    first sample is a cumulative baseline and every later sample is a true
///    per-interval delta.
///
/// 2. **The first sample must be discarded.** It carries lifetime totals, not a
///    delta. Adding it would credit every process with all traffic since boot.
public struct NettopParser {

    /// Discards the priming sample, whose values are cumulative rather than deltas.
    private var sawFirstSample = false
    private var pending: [NettopRow] = []
    private var buffer = ""

    public init() {}

    /// Feeds raw stdout text and returns any samples completed by it.
    ///
    /// A sample is emitted when the *next* sample's header arrives, which is the
    /// only unambiguous boundary in the stream. That costs up to one second of
    /// latency on the app list; the menu bar rate comes from interface counters
    /// and is unaffected.
    public mutating func consume(_ text: String) -> [[NettopRow]] {
        buffer += text
        var samples: [[NettopRow]] = []

        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newline])
            buffer = String(buffer[buffer.index(after: newline)...])

            if Self.isHeader(line) {
                if let sample = closeSample() { samples.append(sample) }
                continue
            }
            // A connection row belongs to the process row above it — nettop emits
            // each process followed by its own sockets — so it is folded into the
            // row already pending rather than becoming a row of its own.
            if let connection = Self.parseConnection(line) {
                foldConnection(connection)
                continue
            }
            if let row = Self.parseRow(line) { pending.append(row) }
        }
        return samples
    }

    /// Adds a connection's bytes to its parent process, if they stayed local.
    private mutating func foldConnection(_ connection: Connection) {
        guard let index = pending.indices.last else { return }
        guard connection.scope.isLocal else { return }
        let parent = pending[index]
        let subtractable = connection.scope.isSubtractable
        pending[index] = NettopRow(
            pid: parent.pid,
            processName: parent.processName,
            bytesIn: parent.bytesIn,
            bytesOut: parent.bytesOut,
            localBytesIn: parent.localBytesIn + connection.bytesIn,
            localBytesOut: parent.localBytesOut + connection.bytesOut,
            subtractableLocalIn: parent.subtractableLocalIn
                + (subtractable ? connection.bytesIn : 0),
            subtractableLocalOut: parent.subtractableLocalOut
                + (subtractable ? connection.bytesOut : 0))
    }

    struct Connection {
        let scope: TrafficScope
        let bytesIn: Int64
        let bytesOut: Int64
    }

    /// Parses a per-socket row such as
    /// `02:21:32,tcp4 192.168.1.107:60282<->192.168.1.1:445,263,287,`
    ///
    /// These exist only because the stream does not pass `-P`. They carry the one
    /// thing the process rows cannot: where the bytes were going.
    static func parseConnection(_ line: String) -> Connection? {
        guard line.contains("<->") else { return nil }
        var fields = line.components(separatedBy: ",")
        if fields.last?.isEmpty == true { fields.removeLast() }
        guard fields.count >= 4 else { return nil }

        let bytesOut = Int64(fields.removeLast().trimmingCharacters(in: .whitespaces)) ?? 0
        let bytesIn = Int64(fields.removeLast().trimmingCharacters(in: .whitespaces)) ?? 0
        let label = fields.dropFirst().joined(separator: ",")
            .trimmingCharacters(in: .whitespaces)
        return Connection(scope: RemoteEndpoint.scope(connectionLabel: label),
                          bytesIn: bytesIn, bytesOut: bytesOut)
    }

    /// Emits whatever is buffered, for use when the stream ends.
    public mutating func flush() -> [NettopRow]? { closeSample() }

    private mutating func closeSample() -> [NettopRow]? {
        defer { pending = [] }
        guard !pending.isEmpty else { return nil }
        guard sawFirstSample else {
            sawFirstSample = true   // priming sample: cumulative, not a delta
            return nil
        }
        return pending
    }

    /// Call when the `nettop` process restarts — the next sample is cumulative again.
    public mutating func resetForRestart() {
        sawFirstSample = false
        pending = []
        buffer = ""
    }

    public static func isHeader(_ line: String) -> Bool {
        line.hasPrefix("time,") || line.hasPrefix(",bytes_in")
    }

    /// Parses one data row, e.g. `02:21:32.760799,mDNSResponder.501,7845,6862,`
    ///
    /// Fields are read from the **right**, not the left. A process name may
    /// contain a comma (nettop does not quote it), which would break
    /// left-to-right field indexing; the trailing numeric columns are always the
    /// last two populated fields regardless.
    public static func parseRow(_ line: String) -> NettopRow? {
        guard !line.isEmpty else { return nil }

        var fields = line.components(separatedBy: ",")
        // The row ends with a delimiter, leaving a trailing empty field.
        if fields.last?.isEmpty == true { fields.removeLast() }
        // time + name + 2 counters
        guard fields.count >= 4 else { return nil }

        let bytesOut = Int64(fields.removeLast().trimmingCharacters(in: .whitespaces)) ?? 0
        let bytesIn = Int64(fields.removeLast().trimmingCharacters(in: .whitespaces)) ?? 0

        // Whatever sits between the timestamp and the counters is the name,
        // rejoined so embedded commas survive.
        let identifier = fields.dropFirst().joined(separator: ",")
            .trimmingCharacters(in: .whitespaces)
        guard !identifier.isEmpty else { return nil }

        // Per-connection sub-rows appear if `-P` is ever dropped. They carry no
        // pid and would otherwise double-count their parent process.
        guard !identifier.contains("<->") else { return nil }

        // `name.pid` — split on the LAST dot, because names contain dots
        // (`com.apple.WebKit`, `launchd.develop`).
        guard let dot = identifier.lastIndex(of: "."),
              let pid = Int32(identifier[identifier.index(after: dot)...])
        else { return nil }

        return NettopRow(pid: pid,
                         processName: String(identifier[identifier.startIndex..<dot]),
                         bytesIn: bytesIn,
                         bytesOut: bytesOut)
    }
}
