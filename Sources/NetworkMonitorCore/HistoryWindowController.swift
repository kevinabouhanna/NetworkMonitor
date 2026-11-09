import AppKit
import Combine
import SwiftUI

/// The Usage History window (#436): its own, like Connections and Ads and
/// Trackers, rather than a pane of Settings, which holds only setup now. The
/// same toolbar as theirs: the period centred, ‹ Today › trailing, and the
/// gear, which opens Settings › History.
public final class HistoryWindowController: NSObject, NSToolbarDelegate {

    public let window: NSWindow
    private let model: HistoryViewModel
    private let scaleControl = NSSegmentedControl()
    private let stepControl = NSSegmentedControl()
    private var observation: AnyCancellable?
    private var languageObservation: AnyCancellable?

    private static let scaleItem = NSToolbarItem.Identifier("scale")
    private static let stepItem = NSToolbarItem.Identifier("step")
    /// Search, in the toolbar: a magnifying glass until it's used (#436).
    public let search = ToolbarSearch(NSToolbarItem.Identifier("search"))

    /// The toolbar's gear: Settings › History.
    public var onSettings: () -> Void = {}

    /// The content and the toolbar, for the window of its own or for a
    /// section of the main window (#436).
    public let content: NSViewController
    public let toolbar: NSToolbar
    private let standalone: Bool

    public init(model: HistoryViewModel, standalone: Bool = true) {
        self.model = model
        self.standalone = standalone
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        let host = NSHostingController(rootView: HistoryView(model: model).localizedRoot())
        content = host
        toolbar = NSToolbar(identifier: standalone ? "History" : "Main.history")
        super.init()
        // The window keeps the size it's given or dragged to.
        host.sizingOptions = []
        if standalone { window.contentViewController = host }
        window.setContentSize(NSSize(width: 860, height: 720))
        window.contentMinSize = NSSize(width: HistoryMetrics.windowMinWidth, height: HistoryMetrics.windowMinHeight)
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

    public func windowDidShow() {
        model.windowDidOpen()
        refreshControls()
    }

    public func windowWillClose() { model.windowDidClose() }

    private func configureControls() {
        PeriodControl.configure(scaleControl, target: self, action: #selector(scaleChosen))
        search.onChange = { [weak self] in self?.model.search = $0 }

        stepControl.segmentCount = 3
        stepControl.trackingMode = .momentary
        stepControl.target = self
        stepControl.action = #selector(stepped)
    }

    /// Sets every word AppKit shows, from `init` and again when the language
    /// changes.
    private func nameControls() {
        window.title = L("Usage History")

        PeriodControl.name(scaleControl)
        nameSearch()

        stepControl.setImage(NSImage(systemSymbolName: "chevron.left", accessibilityDescription: L("Previous")),
                             forSegment: 0)
        stepControl.setLabel(L("Today"), forSegment: 1)
        stepControl.setImage(NSImage(systemSymbolName: "chevron.right", accessibilityDescription: L("Next")),
                             forSegment: 2)
        stepControl.setToolTip(L("Previous (⌘←)"), forSegment: 0)
        stepControl.setToolTip(L("Back to the present"), forSegment: 1)
        stepControl.setToolTip(L("Next (⌘→)"), forSegment: 2)

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
        case scaleItem: return (L("Period"), L("A day, week, month or year at a time"))
        case stepItem:  return (L("Go"), L("Move through time"))
        case SettingsGear.identifier: return (L("Settings"), L("Settings for Usage History"))
        default:        return nil
        }
    }

    private func refreshControls() {
        scaleControl.selectedSegment = HistoryScale.allCases.firstIndex(of: model.scale) ?? 0
        stepControl.setEnabled(model.canStepBack, forSegment: 0)
        stepControl.setEnabled(model.canStepForward, forSegment: 2)
        search.show(model.search)
    }

    private func nameSearch() {
        search.name(placeholder: L("Search apps and networks"), help: L("Search apps and networks (⌘F)"))
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

    @objc private func openSettings() { onSettings() }

    // MARK: NSToolbarDelegate

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        (standalone ? [] : MainWindowController.sidebarItems)
            + [.flexibleSpace, Self.scaleItem, .flexibleSpace, Self.stepItem, search.restingIdentifier,
               SettingsGear.identifier]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar).filter { !search.identifiers.contains($0) } + search.identifiers
    }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                        willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == SettingsGear.identifier {
            return SettingsGear.item(target: self, action: #selector(openSettings),
                                     help: L("Settings for Usage History"))
        }
        if let item = MainWindowController.sidebarButton(identifier) { return item }
        if let item = search.item(for: identifier, in: toolbar) { return item }
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case Self.scaleItem: item.view = scaleControl
        case Self.stepItem:  item.view = stepControl
        default:             return nil
        }
        if let names = Self.names(for: identifier) {
            item.label = names.label
            item.toolTip = names.help
        }
        return item
    }
}
