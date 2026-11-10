import FirewallPolicy
import Foundation
import SwiftUI
import ServerDirectory

/// A period at a glance (#436, #449): what the apps used, who they talked to
/// and what the lists blocked, for the popover's views and the line that
/// heads Connections' settings. Read from Usage History, from the period's
/// start on every network, when asked (the popover opening, a switch
/// changed, a pane shown), and while the popover is open on Data, never on a
/// timer of its own, so it costs nothing while nobody looks.
public final class TodayGlance: ObservableObject {
    /// The period every number covers. The popover's own glance remembers
    /// it, and the groupings; Settings' always reads today.
    @Published public var period: PopoverPeriod = .today {
        didSet { remember(period.rawValue, Keys.period); if period != oldValue { refresh() } }
    }
    @Published public var dataGrouping: PopoverDataGrouping = .apps {
        didSet { remember(dataGrouping.rawValue, Keys.data) }
    }
    @Published public var connectionsGrouping: ConnectionsGrouping = .companies {
        didSet { remember(connectionsGrouping.rawValue, Keys.connections); if connectionsGrouping != oldValue { regroup() } }
    }
    @Published public var adsGrouping: PopoverAdsGrouping = .sites {
        didSet { remember(adsGrouping.rawValue, Keys.ads) }
    }

    /// The period's apps, networks and totals, as Usage History reports them.
    @Published public private(set) var report: HistoryReport?
    /// The biggest companies, countries or apps, by `connectionsGrouping`,
    /// each with what it opens into: a company or country into its apps or
    /// companies, an app into its companies.
    @Published public private(set) var groups: [ConnectionsGroup] = []
    /// The period's traffic to servers: companies, countries, apps.
    @Published public private(set) var summary = ConnectionsSummary()
    /// Each app talking to a server counts once (#449). An app's servers
    /// past its hourly limit, kept as one row, aren't counted.
    @Published public private(set) var connections = 0
    /// What the lists blocked in the period, by site and by app.
    @Published public private(set) var ads = AdsReport()
    /// For each site the lists blocked, the apps that tried it, most first:
    /// what a site's row opens into in the popover (#436).
    @Published public private(set) var siteApps: [String: [AdsItem]] = [:]
    /// For each app, the sites the lists blocked it from, most first (#449).
    @Published public private(set) var appSites: [String: [AdsItem]] = [:]
    /// The popover's rows that are open, companies and sites alike.
    @Published public var expanded: Set<String> = []
    /// Whether anything has been read yet, so a view can wait rather than say
    /// "nothing" before it knows.
    @Published public private(set) var hasLoaded = false

    /// How many rows each of the popover's lists holds; it scrolls past
    /// the first few, as Data does.
    public static let rows = 25
    /// How often Data reads again while the popover is open on it.
    public static let liveInterval: TimeInterval = 5

    private enum Keys {
        static let period = "popoverPeriod"
        static let data = "popoverDataGrouping"
        static let connections = "popoverConnectionsGrouping"
        static let ads = "popoverAdsGrouping"
    }

    private let history: () -> UsageHistory?
    private let calendar: Calendar
    private let defaults: UserDefaults?
    private let naming = DispatchQueue(label: "com.networkmonitor.glance")  // untranslated: queue label
    private var directory: ServerDirectory?
    private var directoryOpened = false
    private var named: [Connection] = []
    private var generation = 0
    private var lastData: Date = .distantPast

    /// `defaults` remembers the period and groupings; nil reads today.
    public init(history: @escaping () -> UsageHistory?, calendar: Calendar = .current,
                defaults: UserDefaults? = nil) {
        self.history = history
        self.calendar = calendar
        self.defaults = defaults
        // Observers don't run in a class's own initialiser: nothing is
        // written back or read again here.
        if let defaults {
            period = defaults.string(forKey: Keys.period).flatMap(PopoverPeriod.init) ?? .today
            dataGrouping = defaults.string(forKey: Keys.data).flatMap(PopoverDataGrouping.init) ?? .apps
            connectionsGrouping = defaults.string(forKey: Keys.connections).flatMap(ConnectionsGrouping.init)
                ?? .companies
            adsGrouping = defaults.string(forKey: Keys.ads).flatMap(PopoverAdsGrouping.init) ?? .sites
        }
    }

    private func remember(_ value: String, _ key: String) {
        defaults?.set(value, forKey: key)
    }

    public func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// Reads Data again, at most every `liveInterval`: called on each sample
    /// while the popover is open on it, so its figures keep moving.
    public func tick(now: Date = Date()) {
        let interval = period == .today ? Self.liveInterval : Self.liveInterval * 6
        guard now.timeIntervalSince(lastData) >= interval else { return }
        refreshData(now: now)
        if period != .today { readBlocks(now: now, request: generation) }
    }

    /// The popover opening (#436): what was open is closed again, as Data's
    /// apps are, and a report from another day isn't shown, even for a moment.
    public func popoverWillOpen(now: Date = Date()) {
        expanded = []
        if let report, !report.period.interval.contains(now) { self.report = nil }
        refresh(now: now)
    }

    /// Reads the period again.
    public func refresh(now: Date = Date()) {
        generation += 1
        let request = generation
        guard let history = history() else {
            hasLoaded = true
            return
        }
        refreshData(now: now)
        readBlocks(now: now, request: request)
        let span = period.period(containing: now, calendar: calendar).interval

        history.loadServers(in: span, hoursOf: span, filter: HistoryFilter(), measure: .bytes) { [weak self] report in
            guard let self, request == self.generation else { return }
            self.naming.async { [weak self] in
                guard let self else { return }
                if !self.directoryOpened {
                    self.directory = ServerDirectory.newest(downloaded: GeoDataUpdater.downloadedDirectory)?.directory
                    self.directoryOpened = true
                }
                let named = report.servers.map { Connection($0, directory: self.directory) }
                let summary = ConnectionsReport.summary(named)
                let count = report.servers.filter { $0.address != UsageHistory.otherServers }.count
                DispatchQueue.main.async {
                    guard request == self.generation else { return }
                    Motion.content {
                        self.named = named
                        self.summary = summary
                        self.connections = count
                        self.regroup()
                        self.hasLoaded = true
                    }
                }
            }
        }
    }

    /// What the lists blocked in the period, read off the main thread (#436):
    /// waited for, a month of them held the popover back as it opened.
    private func readBlocks(now: Date, request: Int) {
        guard let history = history() else { return }
        let span = period.period(containing: now, calendar: calendar).interval
        history.loadListBlocks(from: span.start, to: span.end) { [weak self] blocks in
            guard let self, request == self.generation else { return }
            let ads = AdsReport(blocks) { key in AppIdentityResolver.identity(forKey: key).bundlePath }
            // What each row's chevron opens: the report has it (#536).
            let siteApps = Dictionary(uniqueKeysWithValues: ads.sites.map { ($0.id, $0.children) })
            let appSites = Dictionary(uniqueKeysWithValues: ads.apps.map { ($0.id, $0.children) })
            Motion.content {
                self.ads = ads
                self.siteApps = siteApps
                self.appSites = appSites
            }
        }
    }

    private func refreshData(now: Date) {
        lastData = now
        // Without History's database, Data shows the live rows, as before.
        guard let history = history(), history.isOpen else {
            report = nil
            return
        }
        history.loadReport(for: period.period(containing: now, calendar: calendar)) { [weak self] report in
            guard let self, report.period.scale == self.period.scale else { return }
            Motion.content { self.report = report }
        }
    }

    /// Groups what's been read by `connectionsGrouping`, without reading again.
    private func regroup() {
        groups = Array(ConnectionsReport.groups(named, by: connectionsGrouping).prefix(Self.rows))
    }
}
