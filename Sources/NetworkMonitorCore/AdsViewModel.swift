import AppKit
import Combine
import FirewallPolicy
import Foundation

/// One line of the Ads window's lists: a site or an app, and how many of its
/// connections the lists blocked (#251).
public struct AdsItem: Equatable, Identifiable {
    /// The site (`doubleclick.net`) or the app's key.
    public let id: String
    public let title: String
    /// For a site, the names under it that were blocked; for an app, the
    /// sites it tried most.
    public let detail: String?
    public let count: Int64
    /// The lists that blocked it, by id, such as `ads`.
    public let lists: [String]
    /// An app's bundle, for its icon.
    public let bundlePath: String?

    public init(id: String, title: String, detail: String?, count: Int64, lists: [String], bundlePath: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.count = count
        self.lists = lists
        self.bundlePath = bundlePath
    }
}

/// What the lists blocked in a period, as the Ads window shows it (#251). Pure,
/// so it's tested on its own.
public struct AdsReport: Equatable {
    public var total: Int64 = 0
    /// Each list's count, most first.
    public var lists: [(list: String, count: Int64)] = []
    public var sites: [AdsItem] = []
    public var apps: [AdsItem] = []

    public init() {}

    public init(_ blocks: [ListBlock], bundlePath: (String) -> String? = { _ in nil }) {
        total = blocks.reduce(0) { $0 + $1.count }

        var byList: [String: Int64] = [:]
        for block in blocks { byList[block.list, default: 0] += block.count }
        lists = byList.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { ($0.key, $0.value) }

        // Sites, by the part of the name a person would call the site.
        var sites: [String: (count: Int64, names: [String: Int64], lists: Set<String>)] = [:]
        var apps: [String: (name: String, count: Int64, sites: [String: Int64], lists: Set<String>)] = [:]
        for block in blocks {
            let site = SiteName.site(of: block.name)
            sites[site, default: (0, [:], [])].count += block.count
            sites[site]?.names[block.name, default: 0] += block.count
            sites[site]?.lists.insert(block.list)
            apps[block.appKey, default: (block.appName, 0, [:], [])].count += block.count
            apps[block.appKey]?.sites[site, default: 0] += block.count
            apps[block.appKey]?.lists.insert(block.list)
        }
        self.sites = sites.map { site, entry in
            let names = Self.busiest(entry.names).filter { $0 != site }
            return AdsItem(id: site, title: site, detail: Self.listed(names), count: entry.count,
                           lists: entry.lists.sorted())
        }.sorted(by: Self.order)
        self.apps = apps.map { key, entry in
            AdsItem(id: key, title: entry.name, detail: Self.listed(Self.busiest(entry.sites)), count: entry.count,
                    lists: entry.lists.sorted(), bundlePath: bundlePath(key))
        }.sorted(by: Self.order)
    }

    public static func == (lhs: AdsReport, rhs: AdsReport) -> Bool {
        lhs.total == rhs.total && lhs.sites == rhs.sites && lhs.apps == rhs.apps
            && lhs.lists.map(\.list) == rhs.lists.map(\.list) && lhs.lists.map(\.count) == rhs.lists.map(\.count)
    }

    private static func order(_ lhs: AdsItem, _ rhs: AdsItem) -> Bool {
        lhs.count != rhs.count ? lhs.count > rhs.count : lhs.title < rhs.title
    }

    private static func busiest(_ counts: [String: Int64]) -> [String] {
        counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// "a.com, b.com and 3 more".
    public static func listed(_ names: [String], shown: Int = 2) -> String? {
        guard !names.isEmpty else { return nil }
        let head = names.prefix(shown).joined(separator: ", ")
        return names.count > shown ? "\(head) and \(names.count - shown) more" : head
    }

    /// A list's name as people read it.
    public static func title(ofList id: String) -> String {
        BlocklistTopic(rawValue: id)?.title ?? id
    }
}

/// Drives the Ads and Trackers window (#251): which period, what the lists
/// blocked in it, and pausing. It reloads every 30 s while it shows the
/// present, as Connections does.
public final class AdsViewModel: ObservableObject {

    public struct Bin: Equatable, Identifiable {
        public let interval: DateInterval
        public var count: Int64
        public var id: Date { interval.start }
    }

    @Published public private(set) var period: HistoryPeriod
    @Published public private(set) var report = AdsReport()
    @Published public private(set) var bins: [Bin] = []
    @Published public private(set) var recordingSince: Date?

    public let monitor: MonitorViewModel
    private let calendar: Calendar
    private var refreshTimer: Timer?
    private var icons: [String: NSImage] = [:]
    private var changes: AnyCancellable?

    public init(monitor: MonitorViewModel, calendar: Calendar = .current) {
        self.monitor = monitor
        self.calendar = calendar
        period = HistoryPeriod(scale: .day, containing: Date(), calendar: calendar)
        // The switch, the lists and pausing show at once.
        changes = monitor.firewall.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
    }

    public var firewall: FirewallRules { monitor.firewall }
    public var isOn: Bool { !firewall.lists.isEmpty }
    public var pausedUntil: Date? { firewall.listsPausedUntil }

    // MARK: Window lifecycle

    public func windowDidOpen() {
        period = HistoryPeriod(scale: period.scale, containing: Date(), calendar: calendar)
        reload()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, self.period.contains(Date()) else { return }
            self.reload()
        }
    }

    public func windowDidClose() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: Period

    public var scale: HistoryScale {
        get { period.scale }
        set {
            guard newValue != period.scale else { return }
            let now = Date()
            show(HistoryPeriod(scale: newValue, containing: period.contains(now) ? now : period.start,
                               calendar: calendar))
        }
    }

    public var title: String { period.title(now: Date(), calendar: calendar) }
    public var canStepForward: Bool { period.end <= Date() }
    public var canStepBack: Bool { recordingSince.map { period.start > $0 } ?? false }

    public func step(_ count: Int) { show(period.shifted(by: count, calendar: calendar)) }

    public func goToPresent() { show(HistoryPeriod(scale: period.scale, containing: Date(), calendar: calendar)) }

    private func show(_ period: HistoryPeriod) {
        self.period = period
        reload()
    }

    public func reload() {
        guard let history = monitor.store.history else { return }
        let blocks = history.listBlocks(from: period.start, to: period.end)
        report = AdsReport(blocks) { key in AppIdentityResolver.identity(forKey: key).bundlePath }
        bins = Self.chart(for: period, hours: history.listBlockHours(from: period.start, to: period.end),
                          calendar: calendar)
        recordingSince = history.listBlocksSince()
    }

    /// The period's bars, each with the blocks of the hours inside it.
    public static func chart(for period: HistoryPeriod, hours: [(hour: Date, count: Int64)],
                             calendar: Calendar) -> [Bin] {
        var bins = period.bins(calendar: calendar).map { Bin(interval: $0, count: 0) }
        let starts = bins.map(\.interval.start)
        for (hour, count) in hours {
            if let index = UsageHistory.binIndex(of: hour, in: starts) { bins[index].count += count }
        }
        return bins
    }

    // MARK: Actions

    public func turnOn() {
        firewall.lists = Set(BlocklistTopic.allCases)
        switch monitor.filter.state {
        case .off, .failed: monitor.filter.turnOn()
        default: break
        }
    }

    public func pause(for interval: TimeInterval) { firewall.pauseLists(until: Date().addingTimeInterval(interval)) }

    public func pauseUntilTomorrow() {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))
        firewall.pauseLists(until: tomorrow)
    }

    public func resume() { firewall.pauseLists(until: nil) }

    public func icon(for item: AdsItem) -> NSImage? {
        guard let path = item.bundlePath else { return nil }
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }
}
