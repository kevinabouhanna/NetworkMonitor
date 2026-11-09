import Foundation
import ServerDirectory

/// Today at a glance (#436): who the apps talked to and what the lists
/// blocked, for the popover's Companies and Blocked views and the lines that
/// head Settings › Connections and › Ads. Read from Usage History when asked
/// (the popover opening, a view chosen, a pane shown), never on a timer of its
/// own, so it costs nothing while nobody looks.
public final class TodayGlance: ObservableObject {
    /// The companies with the most traffic today, biggest first.
    @Published public private(set) var companies: [ConnectionsItem] = []
    /// Today's traffic to servers: companies, countries, apps.
    @Published public private(set) var summary = ConnectionsSummary()
    /// Connections the filter blocked today, by rules and lists alike.
    @Published public private(set) var blockedConnections: Int64 = 0
    /// What the lists blocked today, by site and by list.
    @Published public private(set) var ads = AdsReport()
    /// Whether anything has been read yet, so a view can wait rather than say
    /// "nothing" before it knows.
    @Published public private(set) var hasLoaded = false

    /// How many rows each list shows.
    public static let rows = 5

    private let history: () -> UsageHistory?
    private let calendar: Calendar
    private let naming = DispatchQueue(label: "com.networkmonitor.glance")  // untranslated: queue label
    private var directory: ServerDirectory?
    private var directoryOpened = false
    private var generation = 0

    public init(history: @escaping () -> UsageHistory?, calendar: Calendar = .current) {
        self.history = history
        self.calendar = calendar
    }

    /// Reads today again.
    public func refresh(now: Date = Date()) {
        generation += 1
        let request = generation
        guard let history = history() else {
            hasLoaded = true
            return
        }
        let day = calendar.dateInterval(of: .day, for: now) ?? DateInterval(start: now, duration: 86_400)
        let blocks = history.listBlocks(from: day.start, to: now.addingTimeInterval(3600))
        ads = AdsReport(blocks) { key in AppIdentityResolver.identity(forKey: key).bundlePath }

        history.loadServers(in: day, hoursOf: day, filter: HistoryFilter(), measure: .bytes) { [weak self] report in
            guard let self, request == self.generation else { return }
            self.naming.async { [weak self] in
                guard let self else { return }
                if !self.directoryOpened {
                    self.directory = ServerDirectory.newest(downloaded: GeoDataUpdater.downloadedDirectory)?.directory
                    self.directoryOpened = true
                }
                let named = report.servers.map { Connection($0, directory: self.directory) }
                let groups = ConnectionsReport.groups(named, by: .companies)
                let summary = ConnectionsReport.summary(named)
                DispatchQueue.main.async {
                    guard request == self.generation else { return }
                    self.companies = Array(groups.prefix(Self.rows).map(\.item))
                    self.summary = summary
                    self.hasLoaded = true
                }
            }
        }
        history.loadServers(in: day, hoursOf: day, filter: HistoryFilter(), measure: .blocked) { [weak self] report in
            guard let self, request == self.generation else { return }
            self.blockedConnections = report.servers.reduce(0) { $0 + $1.total }
        }
    }
}
