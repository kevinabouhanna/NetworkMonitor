import Combine
import Foundation

/// How far back the Live view's graph goes (#802): the switch where the other
/// views have their grouping.
public enum LiveSpan: String, CaseIterable, Identifiable, Sendable {
    case oneMinute, fiveMinutes, fifteenMinutes
    public var id: String { rawValue }

    public var seconds: TimeInterval {
        switch self {
        case .oneMinute:      return 60
        case .fiveMinutes:    return 300
        case .fifteenMinutes: return 900
        }
    }

    public var label: String {
        switch self {
        case .oneMinute:      return L("1 min")
        case .fiveMinutes:    return L("5 min")
        case .fifteenMinutes: return L("15 min")
        }
    }

    /// As VoiceOver reads it with the graph.
    public var phrase: String {
        switch self {
        case .oneMinute:      return L("The last minute")
        case .fiveMinutes:    return L("The last 5 minutes")
        case .fifteenMinutes: return L("The last 15 minutes")
        }
    }
}

/// One reading of the live rates, in bytes per second, at a time on the
/// monotonic clock (`MonotonicClock`).
public struct LiveSample: Equatable, Sendable {
    public let time: TimeInterval
    public let down: Double
    public let up: Double

    public init(time: TimeInterval, down: Double, up: Double) {
        self.time = time
        self.down = down
        self.up = up
    }
}

/// An app moving data right now, with its rates in bytes per second.
public struct LiveApp: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let bundlePath: String?
    public let down: Double
    public let up: Double
    public var total: Double { down + up }

    public init(id: String, name: String, bundlePath: String?, down: Double, up: Double) {
        self.id = id
        self.name = name
        self.bundlePath = bundlePath
        self.down = down
        self.up = up
    }
}

/// The popover's Live line and view (#802): the menu bar's own rates, kept for
/// 15 minutes, and the apps moving data now.
///
/// Its own object, observed only by the Live views, for the reason
/// `MonitorViewModel.downBytesPerSecond` isn't `@Published`: a rate that
/// changes every second would re-measure the whole popover with it. And it
/// tells its observers only while the popover is open (`isWatched`): the
/// samples keep coming in while it's closed, so the graph is whole when it
/// opens, but nothing is redrawn for them.
public final class LiveSpeed: ObservableObject {
    /// The longest span, and so all that's kept: at most one sample a second,
    /// 900 of them.
    public static let kept: TimeInterval = 900
    /// An app's sample further from the one before than this says nothing
    /// about a rate now: the Mac slept, or nettop restarted.
    static let longestAppGap: TimeInterval = 30

    public private(set) var samples: [LiveSample] = []
    public private(set) var apps: [LiveApp] = []
    @Published public var span: LiveSpan {
        didSet { defaults?.set(span.rawValue, forKey: Self.spanKey) }
    }
    /// Set while the popover or the window's Live page is open; a change is
    /// told then only.
    public var isWatched = false {
        didSet { if isWatched && !oldValue { objectWillChange.send() } }
    }

    static let spanKey = "popoverLiveSpan"
    private let defaults: UserDefaults?
    private var lastAppSample: Date?
    /// When each app last moved data, and its last rates: what the window's
    /// list keeps for a moment after it goes quiet.
    private var lastMoving: [String: (app: LiveApp, at: Date)] = [:]
    private var lastAppDate: Date?

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        span = defaults?.string(forKey: Self.spanKey).flatMap(LiveSpan.init) ?? .oneMinute
    }

    public var latest: LiveSample? { samples.last }

    /// The menu bar's rates, as each interface sample has them. A second
    /// sample within the same second takes the first's place, so the history
    /// holds one a second however fast the sampler runs.
    public func record(down: Double, up: Double, at time: TimeInterval, now: Date = Date()) {
        if isWatched { objectWillChange.send() }
        // No app sample for a while (nettop stopped, or only the last
        // network's came in): the list no longer says what's moving now.
        if !apps.isEmpty || !lastMoving.isEmpty,
           lastAppSample.map({ now.timeIntervalSince($0) > Self.longestAppGap }) ?? true {
            apps = []
            lastMoving = [:]
        }
        // An app quiet for longer than it lingers goes, even while nettop's
        // samples have paused (#812).
        if !lastMoving.isEmpty {
            lastMoving = lastMoving.filter { now.timeIntervalSince($0.value.at) <= Self.lingers }
        }
        let sample = LiveSample(time: time, down: max(down, 0), up: max(up, 0))
        if let last = samples.last {
            if time < last.time {
                // The clock went back, as it never should: start again rather
                // than draw a line backwards.
                samples.removeAll()
            } else if floor(time) == floor(last.time) {
                samples.removeLast()
            }
        }
        samples.append(sample)
        let oldest = time - Self.kept
        if let first = samples.firstIndex(where: { $0.time >= oldest }), first > 0 {
            samples.removeFirst(first)
        }
    }

    /// The apps in one nettop sample: their bytes since the sample before,
    /// over the time between the two, fastest first. The first sample, or one
    /// after a long gap, only sets the clock.
    public func recordApps(_ entries: [(id: String, name: String, bundlePath: String?, bytesIn: Int64, bytesOut: Int64)],
                           at date: Date) {
        defer { lastAppSample = date }
        guard let last = lastAppSample else { return }
        let elapsed = date.timeIntervalSince(last)
        if isWatched { objectWillChange.send() }
        guard elapsed > 0, elapsed <= Self.longestAppGap else {
            apps = []
            lastMoving = [:]
            return
        }
        apps = entries
            .filter { $0.bytesIn > 0 || $0.bytesOut > 0 }
            .map { LiveApp(id: $0.id, name: $0.name, bundlePath: $0.bundlePath,
                           down: Double($0.bytesIn) / elapsed, up: Double($0.bytesOut) / elapsed) }
            .sorted { $0.total != $1.total ? $0.total > $1.total : $0.name < $1.name }
        for app in apps { lastMoving[app.id] = (app, date) }
        lastMoving = lastMoving.filter { date.timeIntervalSince($0.value.at) <= Self.lingers }
        lastAppDate = date
    }

    /// How long the window's list keeps an app that has gone quiet (#812), at
    /// nothing, so its rows don't come and go with every pause.
    public static let lingers: TimeInterval = 5

    /// The apps moving data now, then the ones that were a moment ago, at
    /// nothing, for the main window's Live page (#812).
    public var recentApps: [LiveApp] {
        guard let now = lastAppDate, !apps.isEmpty || !lastMoving.isEmpty else { return apps }
        let moving = Set(apps.map(\.id))
        let quiet = lastMoving.values
            .filter { !moving.contains($0.app.id) && now.timeIntervalSince($0.at) <= Self.lingers }
            .map { LiveApp(id: $0.app.id, name: $0.app.name, bundlePath: $0.app.bundlePath, down: 0, up: 0) }
            .sorted { $0.name < $1.name }
        return apps + quiet
    }

    /// A sample whose apps aren't this network's: only its time counts.
    public func skipAppSample(at date: Date) {
        lastAppSample = date
    }

    /// The samples a span shows, ending at `now`.
    public func samples(in span: LiveSpan, now: TimeInterval) -> [LiveSample] {
        let start = now - span.seconds
        return samples.filter { $0.time >= start && $0.time <= now }
    }

    /// The graph's top: the peak rounded up to 1, 2 or 5 of the unit's steps
    /// (KB/s and MB/s in 1024s, Kbps and Mbps in 1000s), never under 1 KB/s or
    /// 1 Kbps, so an idle Mac draws a flat line rather than its noise at full
    /// height. In bytes per second, with the label to write at the top.
    public static func scale(peak bytesPerSecond: Double, unit: SpeedUnit) -> (top: Double, label: String) {
        let base: Double = unit == .bits ? 1000 : 1024
        let names = unit == .bits ? ["bps", "Kbps", "Mbps", "Gbps", "Tbps"] : ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        var value = max(unit == .bits ? bytesPerSecond * 8 : bytesPerSecond, base)
        var index = 0
        while value >= base, index < names.count - 1 {
            value /= base
            index += 1
        }
        // `value` is now from 1 up to the next step of the unit.
        let steps: [Double] = [1, 2, 5, 10, 20, 50, 100, 200, 500]
        var top: Double
        if let step = steps.first(where: { $0 >= value * (1 - 1e-9) }) {
            top = step
        } else if index < names.count - 1 {
            top = 1
            index += 1
        } else {
            top = 1000
        }
        let inUnit = top * pow(base, Double(index))
        return (unit == .bits ? inUnit / 8 : inUnit, "\(Int(top)) \(names[index])")
    }
}

extension LiveSpeed {
    /// The Live line as VoiceOver reads it: "Live, download 4.80 megabytes
    /// per second, upload 1.70 megabytes per second".
    public static func spoken(_ sample: LiveSample?, unit: SpeedUnit) -> String {
        guard let sample else { return L("Live, no speeds yet") }
        return L("Live, download %@, upload %@", ByteFormat.spokenSpeed(sample.down * 8, unit: unit),
                 ByteFormat.spokenSpeed(sample.up * 8, unit: unit))
    }
}
