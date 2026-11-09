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

    /// Blocked only by malware lists, which *never block* doesn't change (#317).
    public var onlyThreats: Bool { !lists.isEmpty && lists.allSatisfy(ListCatalogue.isThreat) }

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
        let head = names.prefix(shown).joined(separator: L(", "))
        return names.count > shown ? L("%@ and %@ more", head, String(names.count - shown)) : head
    }

    /// A list's name as people read it.
    public static func title(ofList id: String) -> String {
        if id == BlockReason.ownList { return L("Your Rules") }
        return BlocklistTopic(rawValue: id)?.shownTitle ?? ListLibrary.title(of: id) ?? id
    }
}

extension BlocklistTopic {
    /// `title` in the language shown: FirewallPolicy can't call `L` (#433).
    var shownTitle: String {
        switch self {
        case .ads:     return L("Ads and trackers")
        case .malware: return L("Malware and phishing")
        }
    }
}

extension AdRule {
    /// `summary` in the language shown: FirewallPolicy can't call `L` (#433).
    var shownSummary: String {
        let app = appTitle ?? appKey.map { ($0 as NSString).lastPathComponent }
        if skipsApp { return app.map { L("Don't filter %@", $0) } ?? L("Don't filter this app") }
        let site = site ?? ""
        if let app {
            return kind == .neverBlock ? L("Never block %@ in %@", site, app) : L("Always block %@ in %@", site, app)
        }
        return kind == .neverBlock ? L("Never block %@", site) : L("Always block %@", site)
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

    /// Overview or the log (#252), at the top of the window. The lists (#254)
    /// and your rules (#253) are setup, so they're in Settings › Ads (#436).
    public enum Tab: String, CaseIterable, Identifiable {
        case overview, log

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .overview: return L("Overview")
            case .log:      return L("Log")
            }
        }

        /// Whether the toolbar shows the period (#311). Only Overview has one:
        /// the log is the present.
        public var hasPeriod: Bool { self == .overview }
    }

    /// The lists or your rules, in Settings › Ads (#436).
    public enum SetupTab: String, CaseIterable, Identifiable {
        case lists, rules

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .lists: return L("Lists")
            case .rules: return L("Your Rules")
            }
        }
    }

    /// An app a rule can be for: its key and its name.
    public struct RuleApp: Hashable, Identifiable {
        public let key: String
        public let name: String
        public var id: String { key }

        public init(key: String, name: String) {
            self.key = key
            self.name = name
        }
    }

    @Published public var tab: Tab = .overview
    @Published public var setupTab: SetupTab = .lists
    @Published public var logShow: AdsLog.Show = .all
    @Published public var logSearch = ""
    /// What the log showed when it was paused; nil while it's live.
    @Published public private(set) var frozenLog: [AdsLogEntry]?

    /// The Rules tab's form (#253): a site, and every app or one.
    @Published public var newSite = ""
    @Published public var newSiteApp: RuleApp?
    @Published public private(set) var ruleError: String?

    @Published public private(set) var period: HistoryPeriod
    @Published public private(set) var report = AdsReport()
    @Published public private(set) var bins: [Bin] = []
    @Published public private(set) var recordingSince: Date?
    /// What each list blocked today, for the Lists tab (#311).
    @Published public private(set) var listsToday: [String: Int64] = [:]

    public let monitor: MonitorViewModel
    private let calendar: Calendar
    private var refreshTimer: Timer?
    private var icons: [String: NSImage] = [:]
    private var changes: AnyCancellable?
    private var libraryChanges: AnyCancellable?
    private var logChanges: AnyCancellable?

    public init(monitor: MonitorViewModel, calendar: Calendar = .current) {
        self.monitor = monitor
        self.calendar = calendar
        period = HistoryPeriod(scale: .day, containing: Date(), calendar: calendar)
        // The switch, the lists and pausing show at once.
        changes = monitor.firewall.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
        libraryChanges = monitor.listLibrary.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
        // At most twice a second, and only while the log is what's shown.
        logChanges = monitor.adsLog.objectWillChange
            .throttle(for: .milliseconds(500), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                guard let self, self.tab == .log, self.frozenLog == nil else { return }
                self.objectWillChange.send()
            }
    }

    // MARK: Log (#252)

    public var logEntries: [AdsLogEntry] {
        AdsLog.filtered(frozenLog ?? monitor.adsLog.entries, show: logShow, search: logSearch, reason: reason(for:))
    }

    public var logIsPaused: Bool { frozenLog != nil }

    public func reason(for entry: AdsLogEntry) -> String {
        AdsLog.reason(for: entry, rules: firewall.rules, adRules: firewall.adRules)
    }

    public func toggleLogPause() {
        frozenLog = frozenLog == nil ? monitor.adsLog.entries : nil
    }

    public func clearLog() {
        monitor.adsLog.clear()
        if frozenLog != nil { frozenLog = [] }
    }

    public func logText() -> String {
        AdsLog.text(logEntries, reason: reason(for:))
    }

    /// A rule for a site from a row: every app, or only the row's app.
    public func setSite(_ action: RuleAction, domain: String, name: String, in entry: AdsLogEntry?) {
        if let entry, let key = entry.appKey {
            firewall.add(FirewallRule(subject: .site, key: domain, title: domain == name ? domain : "*.\(domain)",
                                      action: action, appKey: key, appTitle: entry.appName))
        } else {
            firewall.setSite(action, domain: domain, forName: name)
        }
        objectWillChange.send()
    }

    /// The rule already made for a site, for every app or one, if any.
    public func rule(forDomain domain: String, appKey: String?) -> FirewallRule? {
        firewall.rules.first { $0.subject == .site && $0.key == domain && $0.appKey == appKey }
    }

    public func remove(_ rule: FirewallRule) {
        firewall.remove(rule)
        objectWillChange.send()
    }

    public func icon(forBundle path: String?) -> NSImage? {
        guard let path else { return nil }
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }

    // MARK: Your rules (#253)

    public var adRules: [AdRule] { firewall.adRules }

    /// Sites never blocked, sites always blocked, and apps left alone, each
    /// newest first.
    public var neverBlocked: [AdRule] { adRules.filter { $0.kind == .neverBlock && $0.site != nil } }
    public var alwaysBlocked: [AdRule] { adRules.filter { $0.kind == .alwaysBlock } }
    public var unfilteredApps: [AdRule] { adRules.filter(\.skipsApp) }

    /// From the form: false, with a reason shown, when there's no site in it.
    @discardableResult
    public func addSite(_ kind: AdRule.Kind) -> Bool {
        guard let site = AdRule.site(from: newSite) else {
            ruleError = newSite.trimmingCharacters(in: .whitespaces).isEmpty
                ? L("Type a site first, like example.com.")
                : L("\"%@\" isn't a site name. Type one like example.com.", newSite)
            return false
        }
        firewall.add(AdRule(kind: kind, site: site, appKey: newSiteApp?.key, appTitle: newSiteApp?.name))
        newSite = ""
        ruleError = nil
        objectWillChange.send()
        return true
    }

    public func clearRuleError() {
        if ruleError != nil { ruleError = nil }
    }

    /// A rule from a row of the overview or the log.
    public func setSite(_ kind: AdRule.Kind, site: String, app: RuleApp?) {
        firewall.add(AdRule(kind: kind, site: site, appKey: app?.key, appTitle: app?.name))
        objectWillChange.send()
    }

    /// Leave an app's connections to the lists alone.
    public func dontFilter(_ app: RuleApp) {
        firewall.add(AdRule(kind: .neverBlock, site: nil, appKey: app.key, appTitle: app.name))
        objectWillChange.send()
    }

    /// An app chosen in a panel, keyed as Connections keys apps.
    public static func ruleApp(at url: URL) -> RuleApp {
        let name = FileManager.default.displayName(atPath: url.path)
        return RuleApp(key: url.standardizedFileURL.path,
                       name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name)
    }

    public func remove(_ rule: AdRule) {
        firewall.remove(rule)
        objectWillChange.send()
    }

    // MARK: Bringing rules over (#253)

    /// The import sheet: pasted text, then what it would bring.
    @Published public var isImporting = false
    @Published public var importText = ""
    @Published public private(set) var importPreview: AdImport?
    @Published public private(set) var importError: String?

    public func beginImport() {
        importText = ""
        importPreview = nil
        importError = nil
        isImporting = true
    }

    public func cancelImport() {
        isImporting = false
        importPreview = nil
        importError = nil
    }

    /// Back from the summary to the text.
    public func editImport() {
        importPreview = nil
    }

    /// A file, or what was pasted: read, and shown before anything changes.
    public func readImport(_ data: Data) {
        do {
            importPreview = try AdImport.read(data, existing: adRules, findApp: Self.findApp)
            importError = nil
        } catch {
            importPreview = nil
            importError = L("That isn't a uBlock Origin backup, AdGuard's settings, or rules NetworkMonitor can read.")
        }
    }

    public func readImportText() { readImport(Data(importText.utf8)) }

    /// Adds what was read, and switches on the lists it had on.
    public func applyImport() {
        guard let preview = importPreview else { return }
        firewall.add(preview.rules)
        for id in preview.downloadedLists { library.setEnabled(id, true) }
        for url in preview.addedLists { library.add(url.absoluteString) }
        if !preview.lists.isSubset(of: firewall.lists) {
            firewall.lists.formUnion(preview.lists)
            switch monitor.filter.state {
            case .off, .failed: monitor.filter.turnOn()
            default: break
            }
        }
        cancelImport()
        objectWillChange.send()
    }

    /// Your rules as Adblock syntax.
    public func exportText() -> String {
        AdImport.export(adRules) { Bundle(path: $0)?.bundleIdentifier }
    }

    /// An app named by a rule: a path, a bundle ID, or a name in
    /// Applications.
    public static func findApp(_ name: String) -> (key: String, name: String)? {
        let manager = FileManager.default
        var url: URL?
        if name.hasPrefix("/") {
            url = URL(fileURLWithPath: name)
        } else if let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
            url = found
        } else {
            let bare = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
            url = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
                .map { URL(fileURLWithPath: $0).appendingPathComponent(bare + ".app") }
                .first { manager.fileExists(atPath: $0.path) }
        }
        guard let url, manager.fileExists(atPath: url.path) else { return nil }
        let app = ruleApp(at: url)
        return (app.key, app.name)
    }

    /// Your rules about a log row's site or app.
    public func adRules(for entry: AdsLogEntry) -> [AdRule] {
        let domains = Set(entry.name.map(SiteName.domains(of:)) ?? [])
        return adRules.filter { rule in
            (rule.appKey == nil || rule.appKey == entry.appKey)
                && (rule.site.map(domains.contains) ?? (rule.appKey != nil))
        }
    }

    /// Apps seen in the period and the log, for the form's menu.
    public var knownApps: [RuleApp] {
        var seen: [String: String] = [:]
        for app in report.apps { seen[app.id] = app.title }
        for entry in monitor.adsLog.entries.prefix(1000) {
            if let key = entry.appKey, seen[key] == nil { seen[key] = entry.appName }
        }
        return seen.map { RuleApp(key: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Lists (#254)

    /// The Lists tab's form: a list's address.
    @Published public var newListURL = ""
    @Published public private(set) var listError: String?

    public var library: ListLibrary { monitor.listLibrary }

    /// The catalogue's lists and the added ones, by topic, in the topics' order.
    public var listGroups: [(topic: ListTopic, lists: [ListSource])] {
        let all = library.all
        return ListTopic.allCases.compactMap { topic in
            let lists = all.filter { $0.topic == topic }
            return lists.isEmpty ? nil : (topic, lists)
        }
    }

    /// What a list blocked today (#311).
    public func blockedToday(byList id: String) -> Int64 { listsToday[id] ?? 0 }

    public func isShippedOn(_ topic: BlocklistTopic) -> Bool { firewall.lists.contains(topic) }

    public func setShipped(_ topic: BlocklistTopic, _ on: Bool) {
        if on {
            firewall.lists.insert(topic)
            switch monitor.filter.state {
            case .off, .failed: monitor.filter.turnOn()
            default: break
            }
        } else {
            firewall.lists.remove(topic)
        }
    }

    /// A shipped list's size and date, as "85,312 sites, from 31 Oct".
    public func shippedDetail(_ topic: BlocklistTopic) -> String {
        let lists = monitor.blocklists.lists
        let count = lists?.tables[topic]?.count ?? 0
        guard let date = BlocklistUpdater.displayDate(lists?.version) else {
            return L("%@ sites", count.formatted())
        }
        return L("%@ sites, from %@", count.formatted(), date)
    }

    public func setList(_ id: String, _ on: Bool) {
        library.setEnabled(id, on)
    }

    /// The recommended lists (#314), in the catalogue's terms.
    public var recommendedLists: [ListSource] { ListCatalogue.recommended.compactMap(ListCatalogue.source) }

    public func setUsesRecommended(_ on: Bool) {
        library.setUsesRecommended(on)
        if !on { advancedListsShown = true }
    }

    /// Whether Advanced is open: by hand, or else while your own choice is in
    /// use, since that's where it's made.
    @Published public var advancedListsShown: Bool?
    public var showsAdvancedLists: Bool { advancedListsShown ?? !library.usesRecommended }

    /// From the form: false, with a reason shown, when it isn't one.
    @discardableResult
    public func addList() -> Bool {
        switch library.add(newListURL) {
        case .success:
            newListURL = ""
            listError = nil
            return true
        case .failure(.notAnAddress):
            listError = newListURL.trimmingCharacters(in: .whitespaces).isEmpty
                ? L("Paste a list's address first, starting https://.")
                : L("That isn't a list's address. It needs to start https://.")
        case .failure(.alreadyThere(let title)):
            listError = L("That list is here already, as %@.", title)
        }
        return false
    }

    public func clearListError() {
        if listError != nil { listError = nil }
    }

    /// "219,320 sites, updated 6 Nov", what's under way, or why it isn't there.
    public func listDetail(_ id: String) -> (text: String, isProblem: Bool) {
        if library.downloading.contains(id) { return (L("Downloading…"), false) }
        let status = library.status[id]
        // The reason is kept in English with the list's status, and shown in
        // the language shown.
        let error = status?.error.map(ListLibrary.shownError)
        if let updated = status?.updated, let names = status?.names {
            let date = updated.formatted(.dateTime.day().month(.abbreviated))
            if let error { return (L("%@ sites, from %@. %@", names.formatted(), date, error), true) }
            return (L("%@ sites, updated %@", names.formatted(), date), false)
        }
        if let error { return (error, true) }
        return library.isEnabled(id) ? (L("Not downloaded yet"), false) : ("", false)
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
            guard let self else { return }
            if self.period.contains(Date()) { self.reload() } else { self.reloadToday() }
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

    /// The period of `scale` that holds now, as the popover's period chose
    /// (#449), so Open … shows the window on the numbers the popover showed.
    public func showPresent(_ scale: HistoryScale) {
        show(HistoryPeriod(scale: scale, containing: Date(), calendar: calendar))
    }
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
        reloadToday()
    }

    /// What each list blocked today, for the lists in Settings › Ads.
    public func reloadToday() {
        guard let history = monitor.store.history else { return }
        let now = Date()
        let blocks = history.listBlocks(from: calendar.startOfDay(for: now), to: now.addingTimeInterval(3600))
        listsToday = Self.byList(blocks)
    }

    /// Each list's count.
    public static func byList(_ blocks: [ListBlock]) -> [String: Int64] {
        blocks.reduce(into: [:]) { $0[$1.list, default: 0] += $1.count }
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

    // MARK: Off on a network (#253)

    /// The network the Mac is on, for "On This Network".
    public var currentNetwork: FirewallRules.CurrentNetwork? { monitor.currentNetwork }

    /// Ad blocking is off on the network the Mac is on: its name.
    public var pausedHere: String? { monitor.adsPausedHere }

    /// Networks where ad blocking is off, by name.
    public var pausedNetworks: [(id: String, name: String)] {
        firewall.listsPausedNetworks.map { ($0.key, $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func pauseOnThisNetwork() {
        guard let network = currentNetwork else { return }
        firewall.pauseLists(on: network, true)
    }

    public func resumeOnNetwork(_ id: String) {
        firewall.resumeLists(onNetwork: id)
    }

    public func icon(for item: AdsItem) -> NSImage? { icon(forBundle: item.bundlePath) }
}
