import AppKit
import Combine
import SwiftUI

/// Connections, a section of the main window (#436); a window of its own only
/// for the accessibility tests. Once its own window, not a Settings pane, because it's read
/// beside other work and wants room for the list and the map side by side.
///
/// Its controls are a real window toolbar (#123), laid out as Apple's own
/// windows lay theirs out: the view on the leading side as in Finder, the
/// period centred and ‹ Today › trailing as in Calendar, then search. What the
/// list is grouped by and narrowed to is a labelled row in the window.
public final class ConnectionsWindowController: NSObject, NSToolbarDelegate {

    public let window: NSWindow
    private let model: ConnectionsViewModel
    private let layoutControl = NSSegmentedControl()
    private let scaleControl = NSSegmentedControl()
    private let stepControl = NSSegmentedControl()
    /// Search, in the toolbar: a magnifying glass until it's used (#436).
    public let search = ToolbarSearch(NSToolbarItem.Identifier("search"))
    private var observation: AnyCancellable?
    private var occlusion: AnyCancellable?
    private var languageObservation: AnyCancellable?

    private static let layoutItem = ViewControl.identifier
    private static let scaleItem = NSToolbarItem.Identifier("scale")
    private static let stepItem = NSToolbarItem.Identifier("step")

    /// The content and the toolbar, for the window of its own or for a
    /// section of the main window (#436), which shows them in its place.
    public let content: NSViewController
    public let toolbar: NSToolbar
    private let standalone: Bool

    public init(model: ConnectionsViewModel, standalone: Bool = true) {
        self.model = model
        self.standalone = standalone
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        let host = NSHostingController(rootView: ConnectionsView(model: model).localizedRoot())
        content = host
        toolbar = NSToolbar(identifier: standalone ? "Connections" : "Main.connections")
        super.init()
        // The window keeps the size it's given or dragged to. Sized to its
        // content, it would jump each time the list grew or shrank.
        host.sizingOptions = []
        if standalone { window.contentViewController = host }
        window.setContentSize(NSSize(width: 1120, height: 760))
        window.contentMinSize = NSSize(width: ConnectionsMetrics.minWidth, height: ConnectionsMetrics.minHeight)
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

        // `objectWillChange` fires before the change lands, so the controls
        // are brought in step on the next turn of the run loop.
        observation = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshControls() }
        }
        refreshControls()
        // The map pulses only while someone can see it (#182).
        occlusion = NotificationCenter.default
            .publisher(for: NSWindow.didChangeOcclusionStateNotification, object: window)
            .sink { [weak self] _ in
                guard let self else { return }
                self.model.windowIsVisible = self.window.occlusionState.contains(.visible)
            }
    }

    public var isVisible: Bool { window.isVisible }

    /// The toolbar's gear: Connections' settings (#436).
    public var onSettings: () -> Void = {}

    /// `fresh` false: shown again in the open main window, as it was (#436).
    public func windowDidShow(fresh: Bool = true) { model.windowDidOpen(reset: fresh) }

    public func windowWillClose() { model.windowDidClose() }

    // MARK: Controls

    private func configureControls() {
        ViewControl.configure(layoutControl, ConnectionsViewModel.Layout.self,
                              target: self, action: #selector(layoutChosen))

        PeriodControl.configure(scaleControl, target: self, action: #selector(scaleChosen))
        search.onChange = { [weak self] in self?.model.search = $0 }

        stepControl.segmentCount = 3
        stepControl.trackingMode = .momentary
        stepControl.target = self
        stepControl.action = #selector(stepped)
    }

    /// Sets every word AppKit shows, from `init` and again when the language
    /// changes: the title, the segments' labels and tooltips, the toolbar
    /// items' names and the search field's placeholder.
    private func nameControls() {
        window.title = L("Connections")

        ViewControl.name(layoutControl, ConnectionsViewModel.Layout.self)

        PeriodControl.name(scaleControl)

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
        search.name(placeholder: L("Company, app, country or address"),
                    help: L("Search companies, apps, countries and addresses (⌘F)"))
    }

    /// A toolbar item's name and tooltip, in the language shown.
    private static func names(for identifier: NSToolbarItem.Identifier) -> (label: String, help: String)? {
        switch identifier {
        case layoutItem: return ViewControl.names(chart: false)
        case scaleItem:  return (L("Period"), L("A day, week, month or year at a time"))
        case stepItem:   return (L("Go"), L("Move through time"))
        case SettingsGear.identifier: return (L("Settings"), L("Settings for Connections"))
        default:         return nil
        }
    }

    private func refreshControls() {
        ViewControl.select(model.layout, in: layoutControl)
        scaleControl.selectedSegment = HistoryScale.allCases.firstIndex(of: model.scale) ?? 0
        stepControl.setEnabled(model.canStepBack, forSegment: 0)
        stepControl.setEnabled(model.canStepForward, forSegment: 2)
        search.show(model.search)
        search.fitGlass()
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

    @objc private func openSettings() { onSettings() }

    // MARK: NSToolbarDelegate

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        (standalone ? [] : MainWindowController.sidebarItems)
            + [Self.layoutItem, .flexibleSpace, Self.scaleItem, .flexibleSpace, Self.stepItem,
               search.restingIdentifier, .space, SettingsGear.identifier]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar).filter { !search.identifiers.contains($0) } + search.identifiers
    }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                        willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if let item = search.item(for: identifier, in: toolbar) { return item }
        switch identifier {
        case Self.layoutItem:
            return item(identifier, control: layoutControl)
        case Self.scaleItem:
            return item(identifier, control: scaleControl)
        case Self.stepItem:
            return item(identifier, control: stepControl)
        case SettingsGear.identifier:
            return SettingsGear.item(target: self, action: #selector(openSettings),
                                     help: L("Settings for Connections"))
        default:
            return nil
        }
    }

    private func item(_ identifier: NSToolbarItem.Identifier, control: NSControl) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = control
        item.label = Self.names(for: identifier)?.label ?? ""
        item.toolTip = Self.names(for: identifier)?.help
        return item
    }
}
