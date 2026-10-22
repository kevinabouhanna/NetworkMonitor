import AppKit
import Combine
import UniformTypeIdentifiers

/// Drives the Usage History window: which period is shown, what it is filtered
/// to, and the report for that combination.
///
/// Every change of period or filter asks `UsageHistory` for one new report,
/// computed off the main thread. While the window shows a period that includes
/// the present, the report is refreshed every 30 s, so the current hour fills
/// in without the window being reopened.
public final class HistoryViewModel: ObservableObject {

    public enum Tab: String, CaseIterable, Identifiable {
        case apps, networks, sessions
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .apps:     return "Apps"
            case .networks: return "Networks"
            case .sessions: return "Sessions"
            }
        }
    }

    @Published public private(set) var period: HistoryPeriod
    @Published public private(set) var filter = HistoryFilter()
    @Published public private(set) var report: HistoryReport
    @Published public var tab: Tab = .apps
    /// The bar under the pointer, by its start.
    @Published public var hoveredBin: Date?
    @Published public var expandedApps: Set<String> = []
    @Published public var systemExpanded = false
    @Published public private(set) var retention: HistoryRetention

    public static let retentionKey = "historyRetention"

    private let monitor: MonitorViewModel
    private let calendar: Calendar
    private var generation = 0
    private var refreshTimer: Timer?

    public init(monitor: MonitorViewModel, calendar: Calendar = .current) {
        self.monitor = monitor
        self.calendar = calendar
        let period = HistoryPeriod(scale: .day, containing: Date(), calendar: calendar)
        self.period = period
        self.report = .empty(period, HistoryFilter(), calendar: calendar)
        self.retention = monitor.store.history?.retention ?? .forever
    }

    private var history: UsageHistory? { monitor.store.history }

    // MARK: Window lifecycle

    /// Each opening starts at the present, unfiltered, at the scale last used.
    public func windowDidOpen() {
        retention = history?.retention ?? .forever
        hoveredBin = nil
        expandedApps.removeAll()
        systemExpanded = false
        show(HistoryPeriod(scale: period.scale, containing: Date(), calendar: calendar),
             filter: HistoryFilter())
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

    // MARK: Navigation

    public var scale: HistoryScale {
        get { period.scale }
        set {
            guard newValue != period.scale else { return }
            // Stay on the moment being looked at: the present if the current
            // period includes it, otherwise the start of the one on screen.
            let now = Date()
            let anchor = period.contains(now) ? now : period.start
            show(HistoryPeriod(scale: newValue, containing: anchor, calendar: calendar),
                 filter: filter)
        }
    }

    public var title: String { period.title(now: Date(), calendar: calendar) }

    public var isCurrent: Bool { period.contains(Date()) }

    public var canStepForward: Bool { period.end <= Date() }

    /// Back as far as the first hour on record, and no further.
    public var canStepBack: Bool {
        guard let since = report.recordingSince else { return false }
        return period.start > since
    }

    public func step(_ count: Int) {
        show(period.shifted(by: count, calendar: calendar), filter: filter)
    }

    public func goToPresent() {
        show(HistoryPeriod(scale: period.scale, containing: Date(), calendar: calendar),
             filter: filter)
    }

    /// A click on a bar opens it: a week's day, a year's month.
    public func open(binStarting start: Date) {
        guard let finer = period.scale.drillDown else { return }
        hoveredBin = nil
        show(HistoryPeriod(scale: finer, containing: start, calendar: calendar), filter: filter)
    }

    // MARK: Filters

    public func toggleApp(_ key: String) {
        var next = filter
        next.appKey = next.appKey == key ? nil : key
        show(period, filter: next)
    }

    public func toggleNetwork(_ id: String) {
        var next = filter
        next.networkID = next.networkID == id ? nil : id
        next.sessionID = nil
        show(period, filter: next)
    }

    public func toggleSession(_ id: Int64) {
        var next = filter
        next.sessionID = next.sessionID == id ? nil : id
        next.networkID = nil
        show(period, filter: next)
    }

    public var meteredOnly: Bool {
        get { filter.meteredOnly }
        set {
            var next = filter
            next.meteredOnly = newValue
            show(period, filter: next)
        }
    }

    public func clearApp() { var next = filter; next.appKey = nil; show(period, filter: next) }
    public func clearNetwork() { var next = filter; next.networkID = nil; show(period, filter: next) }
    public func clearSession() { var next = filter; next.sessionID = nil; show(period, filter: next) }

    /// The name a chip shows for the app filter. Looked up in the report, which
    /// holds the app whenever the filter does.
    public var filteredAppName: String? {
        guard let key = filter.appKey else { return nil }
        for row in report.apps + report.systemRows {
            if row.id == key { return row.displayName }
            if let child = row.children.first(where: { $0.id == key }) { return child.displayName }
        }
        return "App"
    }

    public var filteredSession: HistorySession? {
        guard let id = filter.sessionID else { return nil }
        return report.sessions.first { $0.id == id }?.session
    }

    // MARK: Names

    /// The user's name for a network if they gave it one, else the default.
    public func networkName(_ id: String, defaultLabel: String) -> String {
        monitor.store.customLabel(for: id) ?? defaultLabel
    }

    public var filteredNetworkName: String? {
        guard let id = filter.networkID else { return nil }
        let fallback = report.networks.first { $0.id == id }?.defaultLabel ?? "Network"
        return networkName(id, defaultLabel: fallback)
    }

    /// Asks for a new name, in a sheet on the history window.
    public func rename(networkID id: String, defaultLabel: String, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Rename Network"
        alert.informativeText = "The name is used in Usage History and its exports. "
            + "Leave it empty to go back to “\(defaultLabel)”."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = monitor.store.customLabel(for: id) ?? ""
        field.placeholderString = defaultLabel
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.monitor.store.setLabel(field.stringValue, for: id)
            self.objectWillChange.send()
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: apply) }
        else { apply(alert.runModal()) }
    }

    // MARK: Lists

    /// Only on a change of bar. The pointer reports every point it crosses,
    /// and each assignment, equal or not, would redraw the whole window.
    public func hover(_ binStart: Date?) {
        if hoveredBin != binStart { hoveredBin = binStart }
    }

    public func toggleExpanded(_ id: String) {
        if expandedApps.contains(id) { expandedApps.remove(id) } else { expandedApps.insert(id) }
    }

    public func icon(for row: UsageRow) -> NSImage { monitor.icon(for: row) }

    // MARK: Retention, clearing, export

    /// Shortening retention deletes history, so it asks first whenever there
    /// is history old enough to lose.
    public func requestRetention(_ next: HistoryRetention, in window: NSWindow?) {
        guard next != retention else { return }
        let commit = { [weak self] in
            guard let self else { return }
            self.retention = next
            UserDefaults.standard.set(next.rawValue, forKey: Self.retentionKey)
            self.history?.retention = next
            self.reload()
        }
        guard let cutoff = next.cutoff(now: Date(), calendar: calendar),
              let since = report.recordingSince, since < cutoff
        else { return commit() }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete history older than \(next.label.lowercased())?"
        alert.informativeText = "Everything recorded before "
            + cutoff.formatted(date: .abbreviated, time: .omitted)
            + " is deleted now, and from then on history is kept for \(next.label.lowercased())."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        let decide: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .alertFirstButtonReturn { commit() } else { self?.objectWillChange.send() }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: decide) }
        else { decide(alert.runModal()) }
    }

    public func confirmClear(in window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear all usage history?"
        var detail = "Every hour NetworkMonitor has recorded is deleted. "
        if let since = report.recordingSince {
            detail = "Everything recorded since "
                + since.formatted(date: .abbreviated, time: .omitted) + " is deleted. "
        }
        alert.informativeText = detail + "The totals in the menu bar are not affected."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        let decide: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.history?.clear()
            self.goToPresent()
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: decide) }
        else { decide(alert.runModal()) }
    }

    /// Saves the period on screen, with its filter, as CSV.
    public func export(in window: NSWindow?) {
        guard let history else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "NetworkMonitor Usage – \(title).csv"
            .replacingOccurrences(of: "/", with: "-")
        let period = period, filter = filter
        let save: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let csv = history.exportCSV(for: period, filter: filter) { [weak self] id in
                self?.monitor.store.customLabel(for: id)
            }
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: save) }
        else { save(panel.runModal()) }
    }

    // MARK: Loading

    private func show(_ period: HistoryPeriod, filter: HistoryFilter) {
        self.period = period
        self.filter = filter
        reload()
    }

    /// Requests a report, and drops it if something newer was asked for while
    /// it was computing — a quick ‹ ‹ ‹ must land on the last period, not the
    /// slowest.
    public func reload() {
        generation += 1
        let request = generation
        guard let history else { return }
        history.loadReport(for: period, filter: filter) { [weak self] report in
            guard let self, request == self.generation else { return }
            self.report = report
        }
    }
}
