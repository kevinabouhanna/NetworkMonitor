import AppKit
import Combine
import CoreLocation
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
    /// The toolbar's View (#524), as Usage History's and Ads and Trackers'.
    public enum Layout: String, SectionLayout, Identifiable {
        case list, both, map
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .list: return L("List")
            case .both: return L("Both")
            case .map:  return L("Map")
            }
        }
        public var symbol: String {
            switch self {
            case .list: return "list.bullet"
            case .both: return "rectangle.split.2x1"
            case .map:  return "map"
            }
        }
    }

    @Published public private(set) var period: HistoryPeriod {
        didSet { refreshLive() }
    }
    /// What's open stays open while the window is (#593): each grouping's
    /// rows have their own ids, so Companies, Apps and Countries keep theirs.
    @Published public var grouping: ConnectionsGrouping = .companies {
        didSet { if grouping != oldValue { rebuild() } }
    }
    /// Traffic, or the connections the filter blocked (#114). The map's
    /// pulses are traffic as it happens, so they stop while Blocked is shown.
    @Published public var measure: ServerMeasure = .bytes {
        didSet {
            guard measure != oldValue else { return }
            refreshLive()
            reload()
        }
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
    @Published public private(set) var expanded: Set<String> = []
    /// Rows opened by search, to close again once it changes (#593).
    private var openedBySearch = OpenedByItself()
    /// The search `openedBySearch` opened rows for.
    private var openedFor = ""
    /// Sections showing every item rather than the first few.
    @Published public var showingAll: Set<String> = []

    /// Both by default, and whatever was chosen last after that.
    @Published public var layout: Layout {
        didSet { defaults.set(layout.rawValue, forKey: Self.layoutKey) }
    }
    /// What the map shades, for the same narrowing as the list.
    @Published public private(set) var geography = ConnectionsGeography()
    /// Countries a server answered from in the last `liveWindow`, while the
    /// map is live.
    public let live = LiveCountries()
    /// Whether the map pulses to the countries answering right now (#182):
    /// whenever it's on screen showing traffic for a period that includes
    /// now. There's no switch, and nothing runs while nobody can see it.
    @Published public private(set) var isLive = false {
        didSet { if isLive != oldValue { updateLive() } }
    }
    /// Maps on screen, counted: a change of layout can show the new map
    /// before the old one goes.
    private var mapsShown = 0 {
        didSet { refreshLive() }
    }
    /// Whether any of the window can be seen: open, and not minimised,
    /// covered or on another Space.
    public var windowIsVisible = false {
        didSet { refreshLive() }
    }
    /// Where the map's lines start, and where that came from (#231).
    @Published public private(set) var home: HomeCountry?
    private let homeSources: HomeCountryFinder.Sources?
    private lazy var homeFinder = HomeCountryFinder(sources: homeSources ?? liveHomeSources())
    private var homeSubscription: AnyCancellable?
    /// The offer of website names above the list, until it's taken or closed
    /// (#134). Closed, it stays closed: Connections' settings still has it.
    @Published public var offersWebsiteNames: Bool {
        didSet { defaults.set(!offersWebsiteNames, forKey: Self.websiteNamesOfferClosedKey) }
    }
    public var filter: FilterController { monitor.filter }
    public var firewall: FirewallRules { monitor.firewall }

    /// Rules in place of Traffic and Blocked (#592): every rule, with what
    /// each did in the period. Read from `rulesActivity`.
    @Published public var showsRules = false
    public let rulesActivity = RulesActivity()
    /// Ads and Trackers' own Rules, from the line under these (#592).
    public var onShowAdRules: () -> Void = {}
    /// How many rules Ads and Trackers has, for that line.
    public var adRuleCount: Int { firewall.adRules.count + firewall.listsPausedNetworks.count }

    /// A figure as the window shows it: bytes, or a count of blocked
    /// connections.
    public func format(_ value: Int64) -> String {
        Self.format(value, measure)
    }

    public static func format(_ value: Int64, _ measure: ServerMeasure) -> String {
        switch measure {
        case .bytes:   return ByteFormat.bytes(value)
        case .blocked: return value == 1 ? L("1 time") : L("%@ times", value.formatted())
        }
    }

    /// From a row's menu (#114). Rules are kept whether or not the filter is
    /// on; if it isn't, this is the moment to turn it on, so the offer above
    /// the list comes back to walk through it.
    public func setRule(_ action: RuleAction, for item: ConnectionsItem, onThisNetwork: Bool = false) {
        firewall.set(action, for: item, network: onThisNetwork ? monitor.currentNetwork : nil)
        turnOnFilterForRules()
    }

    /// The network the Mac is on, for "Block on …" (#200). Nil offline.
    public var currentNetwork: FirewallRules.CurrentNetwork? { monitor.currentNetwork }

    /// The lists switched on (#176). Like a rule, they need the content
    /// filter: switching them on while it's off starts turning it on.
    public func setLists(_ lists: Set<BlocklistTopic>) {
        firewall.lists = lists
        if !lists.isEmpty { turnOnFilterForRules() }
    }

    /// The list holding a named server, for its tag (#176).
    public func listed(_ item: ConnectionsItem) -> BlocklistTopic? {
        guard let name = FirewallRules.serverName(of: item) else { return nil }
        return monitor.blocklists.lists?.topics(listing: name).sorted().first
    }

    /// A rule for a site by name, from a server row that has one (#197).
    public func setSiteRule(_ action: RuleAction, domain: String, forName name: String, onThisNetwork: Bool = false) {
        firewall.setSite(action, domain: domain, forName: name, network: onThisNetwork ? monitor.currentNetwork : nil)
        turnOnFilterForRules()
    }

    /// Rules need the content filter: choosing one while it's off starts
    /// turning it on.
    private func turnOnFilterForRules() {
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
    /// How long a country stays lit on the map after its last packet.
    public static let liveWindow: TimeInterval = 30

    private let monitor: MonitorViewModel
    private let calendar: Calendar
    private let defaults: UserDefaults
    private var liveSubscription: AnyCancellable?
    /// A new month of data (#121): named afresh from it.
    private var geoSubscription: AnyCancellable?
    private var livePrune: Timer?
    private var connections: [Connection] = []
    private var icons: [String: NSImage] = [:]
    private var generation = 0
    private var refreshTimer: Timer?
    private let naming = DispatchQueue(label: "com.kevinabouhanna.NetworkMonitor.connections", // untranslated: a queue's identifier
                                       qos: .userInitiated)
    /// Opened on first use, off the main thread: mapping the files is quick,
    /// but there's no reason to do it before the window is ever opened.
    private var directory: ServerDirectory?
    private var directoryOpened = false

    /// `homeSources`: where the Mac's country comes from, for tests; the
    /// app's own otherwise.
    public init(monitor: MonitorViewModel, calendar: Calendar = .current,
                defaults: UserDefaults = .standard, homeSources: HomeCountryFinder.Sources? = nil) {
        self.monitor = monitor
        self.calendar = calendar
        self.defaults = defaults
        self.homeSources = homeSources
        layout = defaults.string(forKey: Self.layoutKey).flatMap(Layout.init) ?? .both
        offersWebsiteNames = !defaults.bool(forKey: Self.websiteNamesOfferClosedKey)
        period = HistoryPeriod(scale: .day, containing: Date(), calendar: calendar)
        geoSubscription = monitor.geoData.$month.dropFirst().removeDuplicates().sink { [weak self] _ in
            guard let self else { return }
            self.naming.async { self.directoryOpened = false }
            self.reload()
        }
        homeSubscription = homeFinder.$home.sink { [weak self] in self?.home = $0 }
    }

    var history: UsageHistory? { monitor.store.history }

    // MARK: Window lifecycle

    /// Each opening starts on the present, unfiltered, or on Hotspot while the
    /// Mac is on one, as History does.
    /// `reset` false: the section shown again in the open window (#436),
    /// read again with its period, filters and search as they were.
    public func windowDidOpen(reset: Bool = true) {
        if reset {
            selected = [:]
            span = nil
            dragging = nil
            search = ""
            expanded.removeAll()
            openedBySearch.reset()
            showingAll.removeAll()
            kind = HistoryFilter.opening(on: monitor.store.currentNetwork.kind).kind
            period = HistoryPeriod(scale: period.scale, containing: Date(), calendar: calendar)
            // Traffic, unless only what's allowed may connect: then what was
            // blocked is where someone looks to allow it.
            measure = firewall.mode == .onlyAllowed ? .blocked : .bytes
            showsRules = false
        }
        reload()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Past midnight, today is yesterday, and no longer live.
            self.refreshLive()
            guard self.period.contains(Date()) else { return }
            self.reload()
        }
        windowIsVisible = true
    }

    public func windowDidClose() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        windowIsVisible = false
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

    /// The period of `scale` that holds now, as the popover's period chose
    /// (#449), so Open … shows the window on the numbers the popover showed.
    public func showPresent(_ scale: HistoryScale) {
        show(HistoryPeriod(scale: scale, containing: Date(), calendar: calendar))
    }
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

    /// The Filter button of a row inside a group: narrows to it, and to the
    /// group it's in, so Microsoft › Teams reads as it was chosen. On the one
    /// filtered to, it lets it go and keeps the group (#593).
    public func narrow(to item: ConnectionsItem, in group: ConnectionsItem? = nil) {
        if isChosen(item) { return clear(item.dimension) }
        if let group { selected[group.dimension] = group }
        selected[item.dimension] = item
        showingAll.removeAll()
        rebuild()
    }

    /// A group's Filter button (#593): shows only it; on the one filtered
    /// to, lets it go, as in Usage History and Ads and Trackers. What's open
    /// stays as the person left it.
    public func toggleFilter(_ group: ConnectionsItem) {
        narrow(to: group)
    }

    /// Whether the window is narrowed to it: its row is marked.
    public func isChosen(_ item: ConnectionsItem) -> Bool {
        selected[item.dimension]?.key == item.key
    }

    public func clear(_ dimension: ConnectionsDimension) {
        selected[dimension] = nil
        rebuild()
    }

    /// Escape (#593): lets go of the bar picked on the timeline first, then
    /// the narrowest chip, as they read from the right.
    public func goBack() {
        if span != nil { return clearSpan() }
        if let last = chips.last { clear(last.dimension) }
    }

    /// Whether there's a choice for Escape to let go of. Only then does it
    /// take Escape, so Escape still closes search the rest of the time.
    public var canGoBack: Bool { span != nil || !selected.isEmpty }

    /// A click on the row, its ▸, or → and ←: the person's from then on.
    public func setExpanded(_ groupID: String, _ open: Bool) {
        openedBySearch.handOver(groupID)
        if open { expanded.insert(groupID) } else { expanded.remove(groupID) }
    }

    public func toggle(_ groupID: String) { setExpanded(groupID, !expanded.contains(groupID)) }

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
        if let maker = detail?.maker { parts.append(L("By %@", maker)) }
        if let others = detail?.others, !others.isEmpty {
            let shown = others.prefix(3).joined(separator: L(", "))
            parts.append(others.count > 3 ? L("also %@ and %@ more", shown, String(others.count - 3))
                                          : L("also %@", shown))
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
                            filter: HistoryFilter(kind: kind), measure: measure) { [weak self] report in
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
        // Filtering opens and closes nothing (#593): what's open stays as the
        // person left it. A group shown only for what's inside it opens to
        // show it.
        let query = search.trimmingCharacters(in: .whitespaces)
        if query != openedFor {
            openedBySearch.close(in: &expanded)
            openedFor = query
        }
        for group in groups where !query.isEmpty && !Self.matches(group.item, query) {
            openedBySearch.openOnce(group.id, in: &expanded)
        }
    }

    /// Whether search finds a group by its own name (or its maker's, under
    /// an app), rather than by something inside it.
    private static func matches(_ item: ConnectionsItem, _ query: String) -> Bool {
        item.title.localizedCaseInsensitiveContains(query) || item.key.localizedCaseInsensitiveContains(query)
            || (item.subtitle?.localizedCaseInsensitiveContains(query) ?? false)
    }

    /// The servers to read, in place of the record: for the tests and the
    /// pictures, which have no history to read them from.
    public func showConnections(_ connections: [Connection]) {
        self.connections = connections
        hasLoaded = true
        rebuild()
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

    public func mapDidAppear() {
        mapsShown += 1
        homeFinder.refresh()
    }

    /// Location, through Wi-Fi names' permission; the Mac's own address; the
    /// Region setting.
    private func liveHomeSources() -> HomeCountryFinder.Sources {
        HomeCountryFinder.Sources(
            location: { [wifiNames = monitor.wifiNames] answer in
                wifiNames.locate { location in
                    // The coordinates go no further than this.
                    answer(location.flatMap {
                        WorldShapes.shared?.map.country(longitude: $0.coordinate.longitude,
                                                        latitude: $0.coordinate.latitude)
                    })
                }
            },
            internetAddress: { [weak self] answer in
                guard let self else { return answer(nil) }
                self.internetAddressCountry(answer)
            },
            region: { Locale.current.region?.identifier })
    }

    /// The country DB-IP places the Mac's own internet address in, when it
    /// holds one the internet sees (#231). Answers on the main thread.
    private func internetAddressCountry(_ answer: @escaping (String?) -> Void) {
        naming.async { [weak self] in
            guard let self else { return }
            self.openDirectoryIfNeeded()
            let country = MacAddresses.publicAddresses().lazy
                .compactMap { self.directory?.lookup($0).country }.first
            DispatchQueue.main.async { answer(country) }
        }
    }

    public func mapDidDisappear() { mapsShown = max(0, mapsShown - 1) }

    private func refreshLive() {
        isLive = windowIsVisible && mapsShown > 0 && measure == .bytes && period.contains(Date())
    }

    /// Follows the servers each sample reaches while the map is live, and
    /// nothing otherwise. Anycast networks are left out, as they are from the
    /// shading.
    private func updateLive() {
        liveSubscription = nil
        livePrune?.invalidate()
        livePrune = nil
        live.countries = [:]
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
                for country in countries { self?.live.countries[country] = now }
            }
        livePrune = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let cutoff = Date() - Self.liveWindow
            self.live.countries = self.live.countries.filter { $0.value > cutoff }
        }
    }

    /// On `naming` only.
    private func openDirectoryIfNeeded() {
        guard !directoryOpened else { return }
        directory = ServerDirectory.newest(downloaded: GeoDataUpdater.downloadedDirectory)?.directory
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

/// The countries answering right now, with when each last did, for the map's
/// pulses. Their own object, so a sample redraws the pulses and not the list
/// or the countries (#182).
public final class LiveCountries: ObservableObject {
    @Published public fileprivate(set) var countries: [String: Date] = [:]
}
