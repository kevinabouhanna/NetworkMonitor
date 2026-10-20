import Foundation

/// Another app's traffic that crossed the connection while a test was running.
public struct CompetingTraffic: Equatable {
    public let displayName: String
    public let bytes: Int64

    public init(displayName: String, bytes: Int64) {
        self.displayName = displayName
        self.bytes = bytes
    }
}

/// One finished measurement, in the terms every speed test uses: download,
/// upload, ping, jitter, and ping while each direction is busy.
///
/// Built only from the JSON file of the run that produced it — see
/// `SpeedTestRunner` for why a result can never be an earlier run's.
///
/// `networkQuality`'s own headline figure, responsiveness in round trips per
/// minute, is deliberately not shown. It is Apple's unit and nobody else's, and
/// it blends latency *inside* the saturated connections — seconds, on a line
/// with deep buffers — with what another app actually waits for. The loaded
/// pings here are only the latter: requests on separate connections while the
/// line is full, which is what a video call running beside a download feels and
/// what other speed tests report as loaded latency.
public struct SpeedTestResult: Equatable {
    public let downloadBitsPerSecond: Double
    public let uploadBitsPerSecond: Double
    /// Round trip on a quiet line, in milliseconds.
    public let ping: Double?
    /// How much consecutive quiet-line pings differ, on average, in milliseconds.
    public let jitter: Double?
    /// Ping while the download is saturating the line.
    public let downloadPing: Double?
    /// Ping while the upload is saturating the line.
    public let uploadPing: Double?
    /// What the test itself cost: both directions, as the tool counted them.
    public let bytesTransferred: Int64
    public let interfaceName: String?
    /// "Ethernet", "Wi-Fi" or "Cellular", from the tool's own classification.
    public var interfaceKind: String?
    /// The Apple edge server measured against, e.g. `frmrs1-edge-fx-011.aaplimg.com`.
    public let endpoint: String?
    public let finishedAt: Date
    /// Filled in after the run, from the app's own per-app accounting.
    public var competingTraffic: [CompetingTraffic] = []

    public var competingBytes: Int64 {
        competingTraffic.reduce(0) { $0 + $1.bytes }
    }

    /// True when other apps moved enough during the test to drag it down.
    ///
    /// Both halves are needed: a share alone flags a few kilobytes on a slow line,
    /// and a floor alone flags a big background sync that a gigabit test shrugs off.
    public var wasContended: Bool {
        let total = competingBytes
        return total >= 1_048_576 && Double(total) >= Double(bytesTransferred) * 0.05
    }

    /// How far ping rises when the line is busy, in milliseconds — the gap
    /// between a quiet line and one carrying a download or upload.
    public var loadedPingIncrease: Double? {
        guard let ping else { return nil }
        let loaded = [downloadPing, uploadPing].compactMap { $0 }.max()
        return loaded.map { max($0 - ping, 0) }
    }

    public init(downloadBitsPerSecond: Double, uploadBitsPerSecond: Double,
                ping: Double?, jitter: Double?,
                downloadPing: Double?, uploadPing: Double?,
                bytesTransferred: Int64,
                interfaceName: String?, endpoint: String?, finishedAt: Date,
                competingTraffic: [CompetingTraffic] = []) {
        self.downloadBitsPerSecond = downloadBitsPerSecond
        self.uploadBitsPerSecond = uploadBitsPerSecond
        self.ping = ping
        self.jitter = jitter
        self.downloadPing = downloadPing
        self.uploadPing = uploadPing
        self.bytesTransferred = bytesTransferred
        self.interfaceName = interfaceName
        self.endpoint = endpoint
        self.finishedAt = finishedAt
        self.competingTraffic = competingTraffic
    }

    /// Why a run produced no result, in words fit for the popover.
    public enum Failure: Error, Equatable {
        case unreadable
        case toolError(String)
    }

    /// Decodes `networkQuality -s -c` output, plus the ping-only pass that
    /// follows it when there is one.
    ///
    /// Tolerant by design: the man page says the field list "is not meant to be
    /// comprehensive", and fields come and go between macOS releases. One
    /// sequential run on the development machine came back without
    /// `ul_throughput` at all, so `fallback` — the last live reading, which the
    /// final figure converges on — fills a missing throughput. Only a run with
    /// neither throughput, from either source, is a failure.
    public static func decode(_ data: Data, idlePass: Data? = nil,
                              fallback: SpeedTestProgress? = nil,
                              now: Date = Date()) -> Result<SpeedTestResult, Failure> {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any]
        else { return .failure(.unreadable) }

        func number(_ key: String) -> Double? {
            (json[key] as? NSNumber)?.doubleValue
        }
        func samples(_ key: String) -> [Double] {
            (json[key] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
        }
        func live(_ value: Double?) -> Double? {
            value.flatMap { $0 > 0 ? $0 : nil }
        }

        let down = number("dl_throughput") ?? live(fallback?.downloadBitsPerSecond)
        let up = number("ul_throughput") ?? live(fallback?.uploadBitsPerSecond)
        guard down != nil || up != nil else {
            if let domain = json["error_domain"] as? String {
                let code = number("error_code").map { " \(Int($0))" } ?? ""
                return .failure(.toolError("\(domain)\(code)"))
            }
            return .failure(.unreadable)
        }

        // HTTP request/response on an open connection: one round trip, with no
        // handshake folded in — the closest thing in the output to a ping. The
        // test itself takes only eight, at its start; the ping-only pass after
        // it adds eight more from a second moment, which on Wi-Fi — measured
        // between 49 and 74 ms across three passes a minute apart — is the
        // difference between a figure and a guess.
        let idle = samples("il_h2_req_resp")
        let extra = idlePass.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            .flatMap { $0 as? [String: Any] }
            .flatMap { $0["il_h2_req_resp"] as? [Any] }?
            .compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
        let ping = Latency.interquartileMean(idle + extra)
            ?? number("base_rtt").flatMap { $0 > 0 ? $0 : nil }

        let bytes = Int64(number("dl_bytes_transferred") ?? 0)
            + Int64(number("ul_bytes_transferred") ?? 0)

        var result = SpeedTestResult(
            downloadBitsPerSecond: down ?? 0,
            uploadBitsPerSecond: up ?? 0,
            ping: ping,
            jitter: Latency.jitter(batches: [idle, extra]),
            // "Foreign" probes: separate connections opened while the test's own
            // flows fill the line, i.e. what another app experiences.
            downloadPing: Latency.interquartileMean(samples("lud_foreign_dl_h2_req_resp")),
            uploadPing: Latency.interquartileMean(samples("lud_foreign_ul_h2_req_resp")),
            bytesTransferred: max(bytes, fallback?.bytesTransferred ?? 0),
            interfaceName: json["interface_name"] as? String,
            endpoint: json["test_endpoint"] as? String,
            finishedAt: now)
        result.interfaceKind = interfaceKind(json)
        return .success(result)
    }

    /// `other.interface-type` counts probes per link type, e.g. `{"wired": 329}`.
    /// The busiest one names the link the test ran over.
    private static func interfaceKind(_ json: [String: Any]) -> String? {
        guard let other = json["other"] as? [String: Any],
              let types = other["interface-type"] as? [String: Any],
              let busiest = types.max(by: {
                  (($0.value as? NSNumber)?.intValue ?? 0) < (($1.value as? NSNumber)?.intValue ?? 0)
              })?.key
        else { return nil }
        switch busiest {
        case "wired":    return "Ethernet"
        case "wifi":     return "Wi-Fi"
        case "cellular": return "Cellular"
        default:         return busiest.capitalized
        }
    }
}

/// How latency samples become the single figures speed tests show.
public enum Latency {

    /// Mean of the middle half of the samples — the summary Ookla's Speedtest
    /// uses for ping. A plain mean lets one stalled probe (633 ms among a run of
    /// 75s, seen live) drag the figure; a minimum flatters the line.
    public static func interquartileMean(_ samples: [Double]) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let quarter = sorted.count / 4
        let middle = sorted[quarter..<(sorted.count - quarter)]
        let kept = middle.isEmpty ? sorted[...] : middle
        return kept.reduce(0, +) / Double(kept.count)
    }

    /// Average difference between consecutive samples, in the order taken: the
    /// usual definition of jitter, and the one that matters to a call, which
    /// suffers from ping changing rather than from ping being high.
    public static func jitter(_ samples: [Double]) -> Double? {
        jitter(batches: [samples])
    }

    /// Jitter over several runs of samples, never stepping from the end of one
    /// run to the start of the next — a minute apart, that gap is not jitter.
    public static func jitter(batches: [[Double]]) -> Double? {
        let steps = batches.flatMap { batch in
            zip(batch, batch.dropFirst()).map { abs($1 - $0) }
        }
        guard !steps.isEmpty else { return nil }
        return steps.reduce(0, +) / Double(steps.count)
    }
}

/// A live reading while a test runs.
public struct SpeedTestProgress: Equatable {
    public var downloadBitsPerSecond: Double = 0
    public var uploadBitsPerSecond: Double = 0
    public var downloadBytes: Int64 = 0
    public var uploadBytes: Int64 = 0
    /// Set once both halves are done, for the short ping-only pass that follows.
    public var isFinishing = false

    /// Which half of the test is running, from which direction has moved bytes.
    ///
    /// With `-s` the tool fills the download first and only then starts the
    /// upload, and its status line shows the upload at exactly "0 B" until that
    /// moment — measured on macOS 26 — so the byte counts alone say where the
    /// test is.
    public enum Stage: Equatable {
        case starting, download, upload, finishing
    }

    public var stage: Stage {
        if isFinishing { return .finishing }
        if uploadBytes > 0 { return .upload }
        if downloadBytes > 0 { return .download }
        return .starting
    }

    /// Both directions so far, as the tool reports them.
    public var bytesTransferred: Int64 { downloadBytes + uploadBytes }

    public init(downloadBitsPerSecond: Double = 0, uploadBitsPerSecond: Double = 0,
                downloadBytes: Int64 = 0, uploadBytes: Int64 = 0) {
        self.downloadBitsPerSecond = downloadBitsPerSecond
        self.uploadBitsPerSecond = uploadBitsPerSecond
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
    }
}

/// Turns `networkQuality -v`'s terminal output into progress readings.
///
/// The tool redraws one status line in place — `ESC[2K` to clear it, `\r` to
/// return — roughly five times a second, but only when stdout is a terminal.
/// Through a pipe it prints nothing until the end, which is why the runner gives
/// it a pseudo-terminal (see `SpeedTestRunner.spawn`). A line reads:
///
///     Downlink: capacity 15.093 Mbps, responsiveness 107 RPM (24.202 MB, 6 flows)
///       - Uplink: capacity 28.461 Mbps, responsiveness 107 RPM (38.500 MB, 11 flows)
///
/// Without `-v` the words "capacity" and "responsiveness" and the byte counts are
/// dropped; both shapes parse, the byte counts simply staying at zero.
public struct SpeedTestOutputParser {

    /// The latest reading, if any line has parsed yet.
    public private(set) var progress: SpeedTestProgress?
    /// The last line that was neither progress nor summary — where the tool puts
    /// an error such as an offline connection.
    public private(set) var lastMessage: String?

    private var pending = ""
    private var inSummary = false

    public init() {}

    /// Feeds raw output. Returns true when `progress` changed.
    @discardableResult
    public mutating func consume(_ text: String) -> Bool {
        pending += text
        var changed = false
        // `isNewline`, not a comparison with "\r" and "\n": Swift treats "\r\n" as
        // one Character, which matches neither, and the summary ends lines with it.
        while let index = pending.firstIndex(where: \.isNewline) {
            let line = String(pending[..<index])
            pending.removeSubrange(...index)
            if handle(line) { changed = true }
        }
        return changed
    }

    private mutating func handle(_ raw: String) -> Bool {
        let line = Self.stripEscapes(raw).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return false }

        if line.hasPrefix("Downlink:"), line.contains("Uplink:") {
            guard let reading = Self.parseProgress(line) else { return false }
            progress = reading
            return true
        }
        if line.hasPrefix("====") {
            inSummary = true
            return false
        }
        if !inSummary { lastMessage = line }
        return false
    }

    /// Drops CSI sequences (`ESC [ … letter`), the only escapes the tool emits.
    static func stripEscapes(_ line: String) -> String {
        guard line.contains("\u{1B}") else { return line }
        var output = ""
        var iterator = line.makeIterator()
        while let character = iterator.next() {
            guard character == "\u{1B}" else { output.append(character); continue }
            guard iterator.next() == "[" else { continue }
            while let next = iterator.next(), !next.isLetter {}
        }
        return output
    }

    static func parseProgress(_ line: String) -> SpeedTestProgress? {
        let halves = line.components(separatedBy: " - Uplink:")
        guard halves.count == 2 else { return nil }
        guard let down = parseHalf(halves[0].replacingOccurrences(of: "Downlink:", with: "")),
              let up = parseHalf(halves[1])
        else { return nil }
        return SpeedTestProgress(downloadBitsPerSecond: down.bits,
                                 uploadBitsPerSecond: up.bits,
                                 downloadBytes: down.bytes,
                                 uploadBytes: up.bytes)
    }

    /// One direction: "capacity 15.093 Mbps, responsiveness 107 RPM (24.202 MB, 6 flows)".
    private static func parseHalf(_ text: String) -> (bits: Double, bytes: Int64)? {
        let tokens = text.replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .split(separator: " ").map(String.init)

        var bits: Double?
        var bytes: Int64 = 0
        for (index, token) in tokens.enumerated() where index > 0 {
            guard let value = Double(tokens[index - 1]) else { continue }
            if let scale = bitScale[token] {
                bits = value * scale
            } else if let scale = byteScale[token] {
                bytes = Int64(value * scale)
            }
        }
        guard let bits else { return nil }
        return (bits, bytes)
    }

    private static let bitScale: [String: Double] = [
        "bps": 1, "Kbps": 1e3, "Mbps": 1e6, "Gbps": 1e9,
    ]
    /// Binary steps: the tool shows "1023.930 KB" before rolling over to MB.
    private static let byteScale: [String: Double] = [
        "B": 1, "KB": 1024, "MB": 1_048_576, "GB": 1_073_741_824,
    ]
}
