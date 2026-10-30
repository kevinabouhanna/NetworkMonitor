import AppKit
import Combine
import FirewallPolicy
import ServerDirectory

/// Drives the Connections window: which period and part of it, what the list
/// is grouped by and narrowed to, and the groups that makes.
///
/// Every change of period, timeline span or network kind asks `UsageHistory`
/// for the servers again, off the main thread. Grouping, narrowing and search
/// only regroup what's loaded, so they answer at once. While the window shows
/// a period that includes the present, it reloads every 30 s, as History does.
public final class ConnectionsViewModel: ObservableObject {

    /// One bar of the timeline.
    public struct Bin: Identifiable, Equatable {
        public let interval: DateInterval
        public var bytes: Int64
        public var id: Date { interval.start }
    }

    /// Who made an app, and the companies it talks to besides its maker.
    public struct AppDetail: Equatable {
        public let maker: String?
        public let others: [String]
    }

    /// What the window shows: the list, the map, or both side by side.
    public enum Layout: String, CaseIterable, Identifiable {
        case list, both, map
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .list: return "List"
            case .both: return "Both"
            case .map:  return "Map"
            }
        }
    }

    @Published public private(set) var period: HistoryPeriod
    @Published public var grouping: ConnectionsGrouping = .companies {
        didSet { if grouping != oldValue { expanded.removeAll(); rebuild() } }
    }
    @Published public var search = "" {
        didSet { if search != oldValue { rebuild() } }
    }
    @Published public private(set) var kind: NetworkFingerprint.Kind?
    /// What the list is narrowed to, one item per dimension, as chips.
    @Published public private(set) var selected: [ConnectionsDimension: ConnectionsItem] = [:]
    /// The bins picked on the timeline, or nil for the whole period.
    @Published public private(set) var span: ClosedRange<Int>?
    /// The bins under a drag across the timeline, before it's let go.
    @Published public var dragging: ClosedRange<Int>?
    @Published public private(set) var bins: [Bin] = []
    @Published public private(set) var groups: [ConnectionsGroup] = []
    @Published public private(set) var summary = ConnectionsSummary()
    @Published public private(set) var appDetails: [String: AppDetail] = [:]
    @Published public private(set) var recordingSince: Date?
    @Published public private(set) var hasLoaded = false
    @Published public var expanded: Set<String> = []
    /// Sections showing every item rather than the first few.
    @Published public var showingAll: Set<String> = []

    /// Both by default, and whatever was chosen last after that.
    @Published public var layout: Layout {
        didSet { defaults.set(layout.rawValue, forKey: Self.layoutKey) }
    }
    /// What the map shades, for the same narrowing as the list.
    @Published public private(set) var geography = ConnectionsGeography()
    /// Countries a server answered from in the last `liveWindow`, while Live is on.
    @Published public private(set) var liveCountries: [String: Date] = [:]
    /// The map's Live switch. Calm by default: a summary of the period.
    @Published public var isLive = false {
        didSet { if isLive != oldValue { updateLive() } }
    }
    /// Where the map's lines start: the Mac's Region setting, never Location.
    public let homeCountry: String? = Locale.current.region?.identifier
    /// The offer of website names above the list, until it's taken or closed
    /// (#134). Closed, it stays closed: Settings › Connections still has it.
    @Published public var offersWebsiteNames: Bool {
        didSet { defaults.set(!offersWebsiteNames, forKey: Self.websiteNamesOfferClosedKey) }
    }
    public var filter: FilterController { monitor.filter }
    public var firewall: FirewallRules { monitor.firewall }

    /// From a row's menu (#114). Rules are kept whether or not the filter is
    /// on; if it isn't, this is the moment to turn it on, so the offer above
    /// the list comes back to walk through it.
    public func setRule(_ action: RuleAction, for item: ConnectionsItem) {
        firewall.set(action, for: item)
        switch filter.state {
        case .off, .failed:
            offersWebsiteNames = true
            filter.turnOn()
        default:
            break
        }
    }

    /// How many items a section shows before "Show all".
    public static let sectionPreview = 8
    public static let layoutKey = "connectionsLayout"
    public static let websiteNamesOfferClosedKey = "websiteNamesOfferClosed"
    /// How long a country stays lit on the Live map after its last packet.
    public static let liveWindow: TimeInterval = 30

    private let monitor: MonitorViewModel
    private let calendar: Calendar
    private let defaults: UserDefaults
    private var liveSubscription: AnyCancellable?
    private var livePrune: Timer?
    private var connections: [Connection] = []
    private var icons: [String: NSImage] = [:]
    private var generation = 0
    private var refreshTimer: Timer?
    private let naming = DispatchQueue(label: "com.kevinabouhanna.NetworkMonitor.connections",
                                       qos: .userInitiated)
    /// Opened on first use, off the main thread: mapping the files is quick,
    /// but there's no reason to do it before the window is ever opened.
    private var directory: ServerDirectory?
    private var directoryOpened = false

    public init(monitor: MonitorViewModel, calendar: Calendar = .current,
                defaults: UserDefaults = .standard) {
        self.monitor = monitor
        self.calendar = calendar
        self.defaults = defaults
        layout = defaults.string(forKey: Self.layoutKey).flatMap(Layout.init) ?? .both
        offersWebsiteNames = !defaults.bool(forKey: Self.websiteNamesOfferClosedKey)
        period = HistoryPeriod(scale: .day, containing: Date(), calendar: calendar)
    }

    private var history: UsageHistory? { monitor.store.history }

    // MARK: Window lifecycle

    /// Each opening starts on the present, unfiltered, or on Hotspot while the
    /// Mac is on one, as History does.
    public func windowDidOpen() {
        selected = [:]
        span = nil
        dragging = nil
        search = ""
        expanded.removeAll()
        showingAll.removeAll()
        kind = HistoryFilter.opening(on: monitor.store.currentNetwork.kind).kind
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
        // Nothing is drawn while nobody can see it.
        isLive = false
    }

    // MARK: Period

    public var scale: HistoryScale {
        get { period.scale }
        set {
            guard newValue != period.scale else { return }
            let now = Date()
            let anchor = period.contains(now) ? now : period.start
            show(HistoryPeriod(scale: newValue, containing: anchor, calendar: calendar))
        }
    }

    public var title: String { period.title(now: Date(), calendar: calendar) }
    public var isCurrent: Bool { period.contains(Date()) }
    public var canStepForward: Bool { period.end <= Date() }

    /// Back as far as the first hour a server was recorded, and no further.
    public var canStepBack: Bool {
        guard let since = recordingSince else { return false }
        return period.start > since
    }

    public func step(_ count: Int) {
        show(period.shifted(by: count, calendar: calendar))
    }

    public func goToPresent() {
        show(HistoryPeriod(scale: period.scale, containing: Date(), calendar: calendar))
    }

    private func show(_ period: HistoryPeriod) {
        self.period = period
        span = nil
        reload()
    }

    /// All, Wi-Fi or Hotspot, as in History.
    public func setKind(_ kind: NetworkFingerprint.Kind?) {
        guard kind != self.kind else { return }
        self.kind = kind
        reload()
    }

    // MARK: Timeline

    /// Narrows to the bins picked on the timeline. Picking the one bin already
    /// picked shows the whole period again.
    public func pick(_ bins: ClosedRange<Int>) {
        span = (span == bins && bins.count == 1) ? nil : bins
        reload()
    }

    public func clearSpan() {
        span = nil
        reload()
    }

    /// The part of the period the list covers.
    public var spanInterval: DateInterval {
        guard let span, span.upperBound < bins.count else { return period.interval }
        return DateInterval(start: bins[span.lowerBound].interval.start,
                            end: bins[span.upperBound].interval.end)
    }

    /// "9 – 10 AM", or "9 AM – 1 PM" for several.
    public var spanTitle: String? {
        guard let span, span.upperBound < bins.count else { return nil }
        let first = HistoryFormat.binTitle(bins[span.lowerBound].interval, scale: period.scale)
        guard span.count > 1 else { return first }
        let last = HistoryFormat.binTitle(bins[span.upperBound].interval, scale: period.scale)
        return "\(first) – \(last)"
    }

    // MARK: Narrowing

    /// A click on a row inside a group: narrows to it, and to the group it's in,
    /// so Microsoft › Teams reads as it was chosen.
    public func narrow(to item: ConnectionsItem, in group: ConnectionsItem? = nil) {
        if let group { selected[group.dimension] = group }
        selected[item.dimension] = item
        showingAll.removeAll()
        rebuild()
    }

    public func clear(_ dimension: ConnectionsDimension) {
        selected[dimension] = nil
        rebuild()
    }

    public func toggle(_ groupID: String) {
        if expanded.contains(groupID) { expanded.remove(groupID) } else { expanded.insert(groupID) }
    }

    /// The chips, in the order the dimensions read.
    public var chips: [ConnectionsItem] {
        ConnectionsDimension.allCases.compactMap { selected[$0] }
    }

    // MARK: Apps

    public func icon(for item: ConnectionsItem) -> NSImage? {
        guard let path = item.bundlePath else { return nil }
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }

    /// "By Microsoft Corporation · also Google and Meta".
    public func subtitle(forApp item: ConnectionsItem) -> String? {
        let detail = appDetails[item.key]
        var parts: [String] = []
        if let parent = item.subtitle { parts.append(parent) }
        if let maker = detail?.maker { parts.append("By \(maker)") }
        if let others = detail?.others, !others.isEmpty {
            let shown = others.prefix(3).joined(separator: ", ")
            parts.append("also " + shown + (others.count > 3 ? " and \(others.count - 3) more" : ""))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Loading

    /// Asks for the servers again, and drops an answer that something newer
    /// was asked for while it was computing.
    public func reload() {
        generation += 1
        let request = generation
        guard let history else {
            hasLoaded = true
            return
        }
        let period = self.period
        let span = spanInterval
        history.loadServers(in: span, hoursOf: period.interval,
                            filter: HistoryFilter(kind: kind)) { [weak self] report in
            guard let self, request == self.generation else { return }
            self.naming.async { [weak self] in
                guard let self else { return }
                self.openDirectoryIfNeeded()
                let named = report.servers.map { Connection($0, directory: self.directory) }
                let details = Self.appDetails(for: named)
                DispatchQueue.main.async {
                    guard request == self.generation else { return }
                    self.connections = named
                    self.appDetails = details
                    self.recordingSince = report.recordingSince
                    self.bins = Self.timeline(for: period, hours: report.hours, calendar: self.calendar)
                    self.hasLoaded = true
                    self.rebuild()
                }
            }
        }
    }

    private func rebuild() {
        let filter = ConnectionsFilter(keys: selected.mapValues(\.key))
        groups = ConnectionsReport.groups(connections, by: grouping, filter: filter, search: search)
        summary = ConnectionsReport.summary(connections, filter: filter, search: search)
        geography = ConnectionsReport.geography(connections, filter: filter, search: search)
        // Narrowed to one, it may as well be open.
        if groups.count == 1, let only = groups.first { expanded.insert(only.id) }
    }

    // MARK: Map

    /// The country's row, for narrowing to it from the map. Nil for a country
    /// nothing went to.
    public func countryItem(_ code: String) -> ConnectionsItem? {
        connections.first { $0.country == code }.map { ConnectionsReport.item(for: $0, .country) }
    }

    /// The companies with servers in `code`, for the map's card.
    public func companies(inCountry code: String) -> [(item: ConnectionsItem, bytes: Int64)] {
        ConnectionsReport.companies(inCountry: code, connections,
                                    filter: ConnectionsFilter(keys: selected.mapValues(\.key)), search: search)
    }

    /// Follows the servers each sample reaches while Live is on, and nothing
    /// otherwise. Anycast networks are left out, as they are from the shading.
    private func updateLive() {
        liveSubscription = nil
        livePrune?.invalidate()
        livePrune = nil
        liveCountries = [:]
        guard isLive else { return }
        liveSubscription = monitor.serverActivity
            .receive(on: naming)
            .map { [weak self] addresses -> Set<String> in
                guard let self else { return [] }
                self.openDirectoryIfNeeded()
                return Set(addresses.compactMap { address -> String? in
                    guard let info = self.directory?.lookup(address),
                          info.owner?.company.answersEverywhere != true else { return nil }
                    return info.country
                })
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] countries in
                let now = Date()
                for country in countries { self?.liveCountries[country] = now }
            }
        livePrune = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let cutoff = Date() - Self.liveWindow
            self.liveCountries = self.liveCountries.filter { $0.value > cutoff }
        }
    }

    /// On `naming` only.
    private func openDirectoryIfNeeded() {
        guard !directoryOpened else { return }
        directory = ServerDirectory.bundled()
        directoryOpened = true
    }

    /// The period's bars, each with the bytes of the hours inside it.
    public static func timeline(for period: HistoryPeriod, hours: [(hour: Date, bytes: Int64)],
                                calendar: Calendar) -> [Bin] {
        var bins = period.bins(calendar: calendar).map { Bin(interval: $0, bytes: 0) }
        let starts = bins.map(\.interval.start)
        for (hour, bytes) in hours {
            if let index = UsageHistory.binIndex(of: hour, in: starts) { bins[index].bytes += bytes }
        }
        return bins
    }

    /// Each app's maker, and the companies other than it that it talks to.
    /// Hosts don't count: an app on Amazon's network isn't talking to Amazon.
    static func appDetails(for connections: [Connection]) -> [String: AppDetail] {
        var paths: [String: String?] = [:]
        for connection in connections where paths[connection.usage.appKey] == nil {
            paths[connection.usage.appKey] = connection.usage.bundlePath
        }
        var details: [String: AppDetail] = [:]
        for (key, path) in paths {
            let maker = path.flatMap { AppMaker.name(ofBundleAt: $0) }
            let makerCompany = maker.map { Company.owning(asn: 0, registeredName: $0).name }
            let others = ConnectionsReport.companies(ofApp: key, in: connections)
                .filter { $0 != makerCompany }
                .sorted()
            details[key] = AppDetail(maker: maker, others: others)
        }
        return details
    }
}
