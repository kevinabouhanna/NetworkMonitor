import Foundation

/// One process's byte movement within a single `nettop` sample.
public struct NettopRow: Equatable {
    public let pid: Int32
    /// Process name as `nettop` reports it — truncated to the kernel's 15-char
    /// `p_comm` limit, e.g. "Google Chrome H". Only a display fallback; real
    /// identity comes from `proc_pidpath`.
    public let processName: String
    public let bytesIn: Int64
    public let bytesOut: Int64

    public init(pid: Int32, processName: String, bytesIn: Int64, bytesOut: Int64) {
        self.pid = pid
        self.processName = processName
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
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
            if let row = Self.parseRow(line) { pending.append(row) }
        }
        return samples
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
