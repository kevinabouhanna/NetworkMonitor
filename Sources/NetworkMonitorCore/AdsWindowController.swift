import AppKit
import Combine
import SwiftUI

/// The Ads and Trackers window (#251): its own, like Connections, since what
/// the lists blocked is a job of its own and not every connection. On
/// Overview its toolbar has Connections' View (List · Both · Chart, #524),
/// period and ‹ Today › (#311); the tabs are in the window, at the top of its
/// content (#358).
public final class AdsWindowController: NSObject, NSToolbarDelegate {

    public let window: NSWindow
    private let model: AdsViewModel
    private let layoutControl = NSSegmentedControl()
    private let scaleControl = NSSegmentedControl()
    private let stepControl = NSSegmentedControl()
    private var observation: AnyCancellable?
    private var languageObservation: AnyCancellable?

    private static let layoutItem = ViewControl.identifier
    private static let scaleItem = NSToolbarItem.Identifier("scale")
    private static let stepItem = NSToolbarItem.Identifier("step")
    /// Search, in the toolbar: a magnifying glass until it's used (#436).
    public let search = ToolbarSearch(NSToolbarItem.Identifier("search"))

    /// The content and the toolbar, for the window of its own or for a
    /// section of the main window (#436).
    public let content: NSViewController
    public let toolbar: NSToolbar
    private let standalone: Bool

    public init(model: AdsViewModel, standalone: Bool = true) {
        self.model = model
        self.standalone = standalone
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        let host = NSHostingController(rootView: AdsView(model: model).localizedRoot())
        content = host
        toolbar = NSToolbar(identifier: standalone ? "Ads" : "Main.ads")
        super.init()
        host.sizingOptions = []
        if standalone { window.contentViewController = host }
        window.setContentSize(NSSize(width: 900, height: 640))
        window.contentMinSize = NSSize(width: AdsMetrics.minWidth, height: AdsMetrics.minHeight)
        window.isReleasedWhenClosed = false

        configureControls()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Self.scaleItem]
        if standalone {
            window.toolbar = toolbar
            window.toolbarStyle = .unified
        }
        nameControls()
        // The words follow a language chosen while the window is open (#433).
        languageObservation = NotificationCenter.default
            .publisher(for: Localization.didChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.nameControls() }

        observation = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshControls() }
        }
        refreshControls()
    }

    public var isVisible: Bool { window.isVisible }

    public func select(_ tab: AdsViewModel.Tab) { model.tab = tab }

    /// The toolbar's gear: Ads and Trackers' settings, where the lists and rules are (#436).
    public var onSettings: () -> Void = {}

    @objc private func openSettings() { onSettings() }

    /// `fresh` false: shown again in the open main window, as it was (#436).
    public func windowDidShow(fresh: Bool = true) {
        model.windowDidOpen(reset: fresh)
        refreshControls()
    }

    public func windowWillClose() { model.windowDidClose() }

    private func configureControls() {
        ViewControl.configure(layoutControl, ChartLayout.self, target: self, action: #selector(layoutChosen))
        PeriodControl.configure(scaleControl, target: self, action: #selector(scaleChosen))
        search.onChange = { [weak self] in self?.model.logSearch = $0 }

        stepControl.segmentCount = 3
        stepControl.trackingMode = .momentary
        stepControl.target = self
        stepControl.action = #selector(stepped)
    }

    /// Sets every word AppKit shows, from `init` and again when the language
    /// changes: the title, the segments' labels and tooltips, and the toolbar
    /// items' names.
    private func nameControls() {
        window.title = L("Ads and Trackers")

        ViewControl.name(layoutControl, ChartLayout.self)
        PeriodControl.name(scaleControl)
        nameSearch()

        stepControl.setImage(NSImage(systemSymbolName: "chevron.left", accessibilityDescription: L("Previous")),
                             forSegment: 0)
        stepControl.setLabel(L("Today"), forSegment: 1)
        stepControl.setImage(NSImage(systemSymbolName: "chevron.right", accessibilityDescription: L("Next")),
                             forSegment: 2)
        stepControl.setToolTip(L("Previous"), forSegment: 0)
        stepControl.setToolTip(L("Back to the present"), forSegment: 1)
        stepControl.setToolTip(L("Next"), forSegment: 2)

        for item in toolbar.items {
            if let names = Self.names(for: item.itemIdentifier) {
                item.label = names.label
                item.toolTip = names.help
            }
        }
    }

    /// A toolbar item's name and tooltip, in the language shown.
    private static func names(for identifier: NSToolbarItem.Identifier) -> (label: String, help: String)? {
        switch identifier {
        case layoutItem: return ViewControl.names(chart: true)
        case scaleItem: return (L("Period"), L("A day, week, month or year at a time"))
        case stepItem:  return (L("Go"), L("Move through time"))
        case SettingsGear.identifier: return (L("Settings"), L("Settings for ads and trackers: the lists and your rules"))
        default:        return nil
        }
    }

    private func refreshControls() {
        ViewControl.select(model.layout, in: layoutControl)
        scaleControl.selectedSegment = HistoryScale.allCases.firstIndex(of: model.scale) ?? 0
        stepControl.setEnabled(model.canStepBack, forSegment: 0)
        stepControl.setEnabled(model.canStepForward, forSegment: 2)
        showPeriod(model.tab.hasPeriod)
        search.show(model.logSearch)
        search.fitGlass()
        if model.tab != shownTab {
            shownTab = model.tab
            nameSearch()
        }
    }

    private var shownTab: AdsViewModel.Tab?

    /// One search for both tabs: sites and apps on Overview, the log on Log.
    private func nameSearch() {
        if model.tab == .log {
            search.name(placeholder: L("Search apps, sites and addresses"),
                        help: L("Search the log (⌘F)"))
        } else {
            search.name(placeholder: L("Search sites and apps"), help: L("Search sites and apps (⌘F)"))
        }
    }

    /// The View, the period and ‹ Today › are in the toolbar only on
    /// Overview (#311, #524): the log is the present and has no chart, so
    /// there they'd only sit there doing nothing.
    private func showPeriod(_ show: Bool) {
        for item in toolbar.items
        where [Self.layoutItem, Self.scaleItem, Self.stepItem].contains(item.itemIdentifier) {
            if #available(macOS 15, *) {
                item.isHidden = !show
            } else {
                item.view?.isHidden = !show
            }
        }
    }

    @objc private func layoutChosen(_ sender: NSSegmentedControl) {
        model.layout = ViewControl.chosen(sender)
    }

    @objc private func scaleChosen(_ sender: NSSegmentedControl) {
        model.scale = HistoryScale.allCases[sender.selectedSegment]
    }

    @objc private func stepped(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0:  model.step(-1)
        case 2:  model.step(1)
        default: model.goToPresent()
        }
    }

    // MARK: NSToolbarDelegate

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // As Connections: the View leading, the period centred, ‹ Today ›
        // trailing, and the gear last, where it stays put when the View and
        // the period hide on Log.
        (standalone ? [] : MainWindowController.sidebarItems)
            + [Self.layoutItem, .flexibleSpace, Self.scaleItem, .flexibleSpace, Self.stepItem, search.restingIdentifier,
               .space, SettingsGear.identifier]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar).filter { !search.identifiers.contains($0) } + search.identifiers
    }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                        willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == SettingsGear.identifier {
            return SettingsGear.item(target: self, action: #selector(openSettings),
                                     help: L("Settings for ads and trackers: the lists and your rules"))
        }
        if let item = search.item(for: identifier, in: toolbar) { return item }
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case Self.layoutItem:
            item.view = layoutControl
        case Self.scaleItem:
            item.view = scaleControl
        case Self.stepItem:
            item.view = stepControl
        default:
            return nil
        }
        if let names = Self.names(for: identifier) {
            item.label = names.label
            item.toolTip = names.help
        }
        return item
    }
}
