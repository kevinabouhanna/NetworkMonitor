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
    /// What its chevron opens (#536): under a site, the apps that tried to
    /// reach it; under an app, the sites it tried. Most first.
    public let children: [AdsItem]
    /// The last hour it was blocked in the period.
    public let last: Date?

    /// Blocked only by malware lists, which *never block* doesn't change (#317).
    public var onlyThreats: Bool { !lists.isEmpty && lists.allSatisfy(ListCatalogue.isThreat) }

    public init(id: String, title: String, detail: String?, count: Int64, lists: [String], bundlePath: String? = nil,
                children: [AdsItem] = [], last: Date? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.count = count
        self.lists = lists
        self.bundlePath = bundlePath
        self.children = children
        self.last = last
    }

    /// The same row with only one of what's inside it: the list's row while
    /// that one is chosen (#593).
    public func keeping(_ childID: String) -> AdsItem {
        AdsItem(id: id, title: title, detail: detail, count: count, lists: lists, bundlePath: bundlePath,
                children: children.filter { $0.id == childID }, last: last)
    }
}

/// The chart's gridlines: from zero to just past the busiest bar, in round
/// steps of whole connections (#536), as `HistoryAxis` has them in bytes.
public enum AdsAxis {
    public static func ticks(forMaximum maximum: Int64, approximateCount: Int = 3) -> [Int64] {
        guard maximum > 0 else { return [0, 1] }
        let rough = Double(maximum) / Double(max(approximateCount, 1))
        let magnitude = pow(10, floor(log10(rough)))
        // 2.5 only where it's still a whole number.
        let steps = magnitude >= 10 ? [1, 2, 2.5, 5, 10] : [1.0, 2, 5, 10]
        let step = max(1, steps.map { $0 * magnitude }.first { $0 >= rough } ?? 10 * magnitude)
        var ticks: [Int64] = [0]
        var value = 0.0
        while value < Double(maximum) {
            value += step
            ticks.append(Int64(value.rounded()))
        }
        return ticks
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

        // Sites, by the part of the name a person would call the site, and
        // apps; each with what's under it, for its chevron (#536).
        struct Tally {
            var title: String
            var count: Int64 = 0
            var lists: Set<String> = []
            var last: Date?
            mutating func add(_ block: ListBlock) {
                count += block.count
                lists.insert(block.list)
                if let hour = block.last { last = max(last ?? hour, hour) }
            }
        }
        var sites: [String: (tally: Tally, names: [String: Int64], apps: [String: Tally])] = [:]
        var apps: [String: (tally: Tally, sites: [String: Tally])] = [:]
        for block in blocks {
            let site = SiteName.site(of: block.name)
            sites[site, default: (Tally(title: site), [:], [:])].tally.add(block)
            sites[site]?.names[block.name, default: 0] += block.count
            sites[site]?.apps[block.appKey, default: Tally(title: block.appName)].add(block)
            apps[block.appKey, default: (Tally(title: block.appName), [:])].tally.add(block)
            apps[block.appKey]?.sites[site, default: Tally(title: site)].add(block)
        }
        func item(_ id: String, _ tally: Tally, detail: String? = nil, bundlePath: String? = nil,
                  children: [AdsItem] = []) -> AdsItem {
            AdsItem(id: id, title: tally.title, detail: detail, count: tally.count, lists: tally.lists.sorted(),
                    bundlePath: bundlePath, children: children, last: tally.last)
        }
        self.sites = sites.map { site, entry in
            let names = Self.busiest(entry.names).filter { $0 != site }
            return item(site, entry.tally, detail: Self.listed(names),
                        children: entry.apps.map { item($0.key, $0.value, bundlePath: bundlePath($0.key)) }
                            .sorted(by: Self.order))
        }.sorted(by: Self.order)
        self.apps = apps.map { key, entry in
            item(key, entry.tally, detail: Self.listed(Self.busiest(entry.sites.mapValues(\.count))),
                 bundlePath: bundlePath(key),
                 children: entry.sites.map { item($0.key, $0.value) }.sorted(by: Self.order))
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
            return kind == .neverBlock ? L("Always allow %@ in %@", site, app) : L("Block %@ in %@", site, app)
        }
        // The words Connections uses for the same thing (#592).
        return kind == .neverBlock ? L("Always allow %@", site) : L("Block %@", site)
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

    /// Overview, the log (#252), or your rules (#592), at the top of the
    /// window. The lists (#254) are setup, so they're in Ads and Trackers'
    /// settings (#436); your rules are here, as Connections has its own.
    public enum Tab: String, CaseIterable, Identifiable {
        case overview, log, rules

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .overview: return L("Overview")
            case .log:      return L("Log")
            case .rules:    return L("Rules")
            }
        }

        /// Whether the toolbar shows the period (#311). The log is the
        /// present; Overview and Rules, what happened in the period.
        public var hasPeriod: Bool { self != .log }
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
    /// The toolbar's View on Overview (#524): Both by default, and whatever
    /// was chosen last after that, as Connections remembers its own.
    @Published public var layout: ChartLayout {
        didSet { defaults.set(layout.rawValue, forKey: Self.layoutKey) }
    }
    /// Overview's list: the sites blocked, or the apps that tried to reach
    /// them (#524), as the popover groups them.
    @Published public var grouping: PopoverAdsGrouping = .sites {
        // A chosen row belongs to its list (#536).
        didSet { if grouping != oldValue { clearSelection() } }
    }
    public static let layoutKey = "adsLayout"
    /// What each of your rules did in the period, for Rules (#592).
    public let rulesActivity = RulesActivity()
    /// Connections' own Rules, from the line under these (#592).
    public var onShowConnectionRules: () -> Void = {}
    @Published public var logShow: AdsLog.Show = .all
    /// The toolbar's search, on Overview and the Log. On Overview, a row
    /// shown only for what's inside it opens to show it (#593).
    @Published public var logSearch = "" {
        didSet { if logSearch != oldValue { openForSearch() } }
    }
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
    private let defaults: UserDefaults
    private var refreshTimer: Timer?
    private var icons: [String: NSImage] = [:]
    private var changes: AnyCancellable?
    private var libraryChanges: AnyCancellable?
    private var logChanges: AnyCancellable?

    public init(monitor: MonitorViewModel, calendar: Calendar = .current, defaults: UserDefaults = .standard) {
        self.monitor = monitor
        self.calendar = calendar
        self.defaults = defaults
        layout = defaults.string(forKey: Self.layoutKey).flatMap(ChartLayout.init) ?? .both
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
        adRules(site: entry.name, appKey: entry.appKey)
    }

    /// Your rules about a name or a site, in every app or `appKey`'s, and
    /// about that app; or, with no site, the app's own (#536).
    public func adRules(site: String?, appKey: String?) -> [AdRule] {
        guard let site else { return adRules.filter { $0.appKey != nil && $0.appKey == appKey } }
        let domains = Set(SiteName.domains(of: site))
        return adRules.filter { rule in
            (rule.appKey == nil || rule.appKey == appKey)
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

    /// Whether a list that blocked something in the period blocks now (#402):
    /// one switched off since keeps its earlier blocks in the period's count,
    /// and the header's breakdown marks it off. Your own rules are always on.
    public func isListOn(_ id: String) -> Bool {
        if id == BlockReason.ownList { return true }
        if let topic = BlocklistTopic(rawValue: id) { return isShippedOn(topic) }
        return library.isEnabled(id)
    }

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

    /// `reset` false: the section shown again in the open window (#436).
    public func windowDidOpen(reset: Bool = true) {
        if reset {
            period = HistoryPeriod(scale: period.scale, containing: Date(), calendar: calendar)
            spanStart = nil
            selection = nil
            selectedCounts = [:]
            expanded.removeAll()
            openedByChoosing.reset()
            openedBySearch.reset()
            showingAll.removeAll()
        }
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
        spanStart = nil
        hoveredBin = nil
        reload()
    }

    public func reload() {
        guard let history = monitor.store.history else { return }
        bins = Self.chart(for: period, hours: history.listBlockHours(from: period.start, to: period.end),
                          calendar: calendar)
        let shown = spanInterval ?? DateInterval(start: period.start, end: period.end)
        let blocks = history.listBlocks(from: shown.start, to: shown.end)
        report = AdsReport(blocks) { key in AppIdentityResolver.identity(forKey: key).bundlePath }
        if !logSearch.trimmingCharacters(in: .whitespaces).isEmpty { openForSearch(fresh: false) }
        recordingSince = history.listBlocksSince()
        reloadSelection()
        reloadToday()
    }

    // MARK: The chart and the list (#536)

    /// A row chosen in the list: a site or an app, or one inside the other.
    /// The chart shows its share of each bar, as Usage History's chart shows
    /// the app chosen there.
    public struct Selection: Equatable {
        public let grouping: PopoverAdsGrouping
        /// The row: a site, or an app's key.
        public let parent: String
        /// A row inside it: an app's key under a site, or a site under an app.
        public let child: String?
        /// What it's called, for its chip and the chart's tooltip: "Safari",
        /// or "doubleclick.net in Safari".
        public let title: String

        public init(grouping: PopoverAdsGrouping, parent: String, child: String? = nil, title: String) {
            self.grouping = grouping
            self.parent = parent
            self.child = child
            self.title = title
        }

        public var site: String? { grouping == .sites ? parent : child }
        public var appKey: String? { grouping == .apps ? parent : child }
        /// The row's id in the list, as `rowID` makes it.
        public var rowID: String { AdsViewModel.rowID(parent, child) }
    }

    /// A list row's id: a site or an app, or one inside it.
    public static func rowID(_ parent: String, _ child: String? = nil) -> String {
        child.map { parent + "\u{1}" + $0 } ?? parent
    }

    /// The bar under the pointer, for its tooltip, as in Usage History.
    @Published public var hoveredBin: Date?
    /// The bar clicked, as in Connections: the list and the total are that
    /// hour's, day's or month's. nil for the whole period.
    @Published public private(set) var spanStart: Date?
    @Published public private(set) var selection: Selection?
    /// The chosen row's blocks in each bar, by the bar's start.
    @Published public private(set) var selectedCounts: [Date: Int64] = [:]
    /// Rows open, by `grouping` and row id, so Sites and Apps keep their own.
    @Published public private(set) var expanded: Set<String> = []
    /// Rows opened by choosing, and by search, to close again (#593).
    private var openedByChoosing = OpenedByItself()
    private var openedBySearch = OpenedByItself()
    /// Rows whose whole inside is shown, past the first few.
    @Published public var showingAll: Set<String> = []
    /// How many of a row's inside show before "Show all", as in Connections.
    public static let preview = ConnectionsViewModel.sectionPreview

    public func hover(_ binStart: Date?) {
        if hoveredBin != binStart { hoveredBin = binStart }
    }

    /// Narrows the list to a bar, or back to the period when it's the bar
    /// already picked.
    public func pick(binStarting start: Date) {
        spanStart = spanStart == start ? nil : start
        reload()
    }

    public func clearSpan() {
        guard spanStart != nil else { return }
        spanStart = nil
        reload()
    }

    /// The bar picked, while it's one of the period's.
    public var spanInterval: DateInterval? {
        guard let spanStart else { return nil }
        return bins.first { $0.interval.start == spanStart }?.interval
    }

    /// "9 – 10 AM", "Wed, Oct 21".
    public var spanTitle: String? {
        spanInterval.map { HistoryFormat.binTitle($0, scale: period.scale) }
    }

    /// Chooses a row, or lets go of the one chosen (#593): the list keeps
    /// only it, opened when there's something inside, and the total is its
    /// own, as choosing a row does in Usage History and Connections.
    public func select(_ next: Selection) {
        selection = selection == next ? nil : next
        openedByChoosing.close(in: &expanded)
        if let selection, !(item(selection.parent)?.children.isEmpty ?? true) {
            openedByChoosing.open(expansionKey(selection.parent), in: &expanded)
        }
        reloadSelection()
    }

    public func clearSelection() {
        guard selection != nil else { return }
        selection = nil
        selectedCounts = [:]
        openedByChoosing.close(in: &expanded)
    }

    /// A row of the list shown, by its id.
    private func item(_ id: String) -> AdsItem? {
        (grouping == .sites ? report.sites : report.apps).first { $0.id == id }
    }

    /// The chosen row's count in the period, or the bar picked: the header's
    /// total while a row is chosen.
    public var chosenCount: Int64? {
        guard let selection, let parent = item(selection.parent) else { return nil }
        guard let child = selection.child else { return parent.count }
        return parent.children.first { $0.id == child }?.count
    }

    /// Escape: the bar first, then the row, as each was added.
    public func goBack() {
        if spanStart != nil { clearSpan() } else { clearSelection() }
    }

    public var canGoBack: Bool { spanStart != nil || selection != nil }

    public func expansionKey(_ id: String) -> String { grouping.rawValue + ":" + id }

    public func isExpanded(_ id: String) -> Bool { expanded.contains(expansionKey(id)) }

    /// The ▸, or → and ←: the person's from then on.
    public func setExpanded(_ id: String, _ open: Bool) {
        let key = expansionKey(id)
        openedByChoosing.handOver(key)
        openedBySearch.handOver(key)
        if open { expanded.insert(key) } else { expanded.remove(key) }
    }

    /// Opens the rows of both lists shown only for what's inside them: a site
    /// for an app that tried it, an app for a site. `fresh`: a new search, so
    /// what the last one opened closes first.
    private func openForSearch(fresh: Bool = true) {
        if fresh { openedBySearch.close(in: &expanded) }
        for (list, items) in [(PopoverAdsGrouping.sites, report.sites), (.apps, report.apps)] {
            for item in items where Self.matchesInside(item, logSearch) {
                openedBySearch.openOnce(list.rawValue + ":" + item.id, in: &expanded)
            }
        }
    }

    /// A row search finds by what's inside it, not by its own name, the names
    /// under it, or its key.
    public static func matchesInside(_ item: AdsItem, _ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return false }
        func matches(_ item: AdsItem) -> Bool {
            item.title.localizedCaseInsensitiveContains(query) || item.id.localizedCaseInsensitiveContains(query)
                || (item.detail?.localizedCaseInsensitiveContains(query) ?? false)
        }
        return !matches(item) && item.children.contains(where: matches)
    }

    public func toggleExpanded(_ id: String) { setExpanded(id, !isExpanded(id)) }

    /// Everything blocked in the period, whichever bar is picked.
    public var periodTotal: Int64 { bins.reduce(0) { $0 + $1.count } }

    private func reloadSelection() {
        guard let selection, let history = monitor.store.history else {
            selectedCounts = [:]
            return
        }
        let hours = history.listBlockHours(from: period.start, to: period.end,
                                           appKey: selection.appKey, site: selection.site)
        selectedCounts = Dictionary(uniqueKeysWithValues: Self.chart(for: period, hours: hours, calendar: calendar)
            .map { ($0.interval.start, $0.count) })
    }

    /// What each list blocked today, for the lists in Ads and Trackers' settings.
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

    public func pauseUntilTomorrow() { firewall.pauseListsUntilTomorrow(calendar: calendar) }

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
