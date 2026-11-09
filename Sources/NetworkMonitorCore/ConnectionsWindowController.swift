import AppKit
import Combine
import SwiftUI

/// The Connections window: its own, not a Settings pane, because it's read
/// beside other work and wants room for the list and the map side by side.
///
/// Its controls are a real window toolbar (#123), laid out as Apple's own
/// windows lay theirs out: the view on the leading side as in Finder, the
/// period centred and ‹ Today › trailing as in Calendar, then search. What the
/// list is grouped by and narrowed to is a labelled row in the window.
public final class ConnectionsWindowController: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {

    public let window: NSWindow
    private let model: ConnectionsViewModel
    private let layoutControl = NSSegmentedControl()
    private let scaleControl = NSSegmentedControl()
    private let stepControl = NSSegmentedControl()
    private var searchField: NSSearchField?
    private var observation: AnyCancellable?
    private var occlusion: AnyCancellable?
    private var languageObservation: AnyCancellable?

    private static let layoutItem = NSToolbarItem.Identifier("layout")
    private static let scaleItem = NSToolbarItem.Identifier("scale")
    private static let stepItem = NSToolbarItem.Identifier("step")
    private static let searchItem = NSToolbarItem.Identifier("search")

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

    /// The toolbar's gear: Settings › Connections (#436).
    public var onSettings: () -> Void = {}

    public func windowDidShow() { model.windowDidOpen() }

    public func windowWillClose() { model.windowDidClose() }

    // MARK: Controls

    private func configureControls() {
        let layouts = ConnectionsViewModel.Layout.allCases
        layoutControl.segmentCount = layouts.count
        layoutControl.trackingMode = .selectOne
        layoutControl.target = self
        layoutControl.action = #selector(layoutChosen)

        let scales = HistoryScale.allCases
        scaleControl.segmentCount = scales.count
        scaleControl.trackingMode = .selectOne
        scaleControl.target = self
        scaleControl.action = #selector(scaleChosen)

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

        for (index, layout) in ConnectionsViewModel.Layout.allCases.enumerated() {
            layoutControl.setImage(NSImage(systemSymbolName: Self.symbol(for: layout),
                                           accessibilityDescription: layout.label), forSegment: index)
            layoutControl.setToolTip(layout.label, forSegment: index)
        }

        for (index, scale) in HistoryScale.allCases.enumerated() {
            scaleControl.setLabel(scale.label, forSegment: index)
        }

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
        searchField?.placeholderString = L("Company, app, country or address")
    }

    /// A toolbar item's name and tooltip, in the language shown.
    private static func names(for identifier: NSToolbarItem.Identifier) -> (label: String, help: String)? {
        switch identifier {
        case layoutItem: return (L("View"), L("The list, both side by side, or the map"))
        case scaleItem:  return (L("Period"), L("A day, week, month or year at a time"))
        case stepItem:   return (L("Go"), L("Move through time"))
        case SettingsGear.identifier: return (L("Settings"), L("Settings for Connections"))
        default:         return nil
        }
    }

    private func refreshControls() {
        layoutControl.selectedSegment = ConnectionsViewModel.Layout.allCases.firstIndex(of: model.layout) ?? 0
        scaleControl.selectedSegment = HistoryScale.allCases.firstIndex(of: model.scale) ?? 0
        stepControl.setEnabled(model.canStepBack, forSegment: 0)
        stepControl.setEnabled(model.canStepForward, forSegment: 2)
        if let searchField, searchField.stringValue != model.search {
            searchField.stringValue = model.search
        }
    }

    @objc private func layoutChosen(_ sender: NSSegmentedControl) {
        model.layout = ConnectionsViewModel.Layout.allCases[sender.selectedSegment]
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

    public func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        model.search = field.stringValue
    }

    static func symbol(for layout: ConnectionsViewModel.Layout) -> String {
        switch layout {
        case .list: return "list.bullet"
        case .both: return "rectangle.split.2x1"
        case .map:  return "map"
        }
    }

    // MARK: NSToolbarDelegate

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        (standalone ? [] : MainWindowController.sidebarItems)
            + [Self.layoutItem, .flexibleSpace, Self.scaleItem, .flexibleSpace, Self.stepItem, Self.searchItem,
               SettingsGear.identifier]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                        willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case Self.layoutItem:
            return item(identifier, control: layoutControl)
        case Self.scaleItem:
            return item(identifier, control: scaleControl)
        case Self.stepItem:
            return item(identifier, control: stepControl)
        case Self.searchItem:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.searchField.delegate = self
            item.searchField.placeholderString = L("Company, app, country or address")
            item.preferredWidthForSearchField = 240
            searchField = item.searchField
            return item
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
