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

    private static let layoutItem = NSToolbarItem.Identifier("layout")
    private static let scaleItem = NSToolbarItem.Identifier("scale")
    private static let stepItem = NSToolbarItem.Identifier("step")
    private static let searchItem = NSToolbarItem.Identifier("search")

    public init(model: ConnectionsViewModel) {
        self.model = model
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        let host = NSHostingController(rootView: ConnectionsView(model: model))
        // The window keeps the size it's given or dragged to. Sized to its
        // content, it would jump each time the list grew or shrank.
        host.sizingOptions = []
        window.contentViewController = host
        window.title = "Connections"
        window.setContentSize(NSSize(width: 1120, height: 760))
        window.contentMinSize = NSSize(width: ConnectionsMetrics.minWidth, height: ConnectionsMetrics.minHeight)
        window.isReleasedWhenClosed = false

        configureControls()
        let toolbar = NSToolbar(identifier: "Connections")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Self.scaleItem]
        window.toolbar = toolbar
        window.toolbarStyle = .unified

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

    public func windowDidShow() { model.windowDidOpen() }

    public func windowWillClose() { model.windowDidClose() }

    // MARK: Controls

    private func configureControls() {
        let layouts = ConnectionsViewModel.Layout.allCases
        layoutControl.segmentCount = layouts.count
        layoutControl.trackingMode = .selectOne
        for (index, layout) in layouts.enumerated() {
            layoutControl.setImage(NSImage(systemSymbolName: Self.symbol(for: layout),
                                           accessibilityDescription: layout.label), forSegment: index)
            layoutControl.setToolTip(layout.label, forSegment: index)
        }
        layoutControl.target = self
        layoutControl.action = #selector(layoutChosen)

        let scales = HistoryScale.allCases
        scaleControl.segmentCount = scales.count
        scaleControl.trackingMode = .selectOne
        for (index, scale) in scales.enumerated() {
            scaleControl.setLabel(scale.label, forSegment: index)
            scaleControl.setWidth(64, forSegment: index)
        }
        scaleControl.target = self
        scaleControl.action = #selector(scaleChosen)

        stepControl.segmentCount = 3
        stepControl.trackingMode = .momentary
        stepControl.setImage(NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous"),
                             forSegment: 0)
        stepControl.setLabel("Today", forSegment: 1)
        stepControl.setImage(NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next"),
                             forSegment: 2)
        stepControl.setToolTip("Previous (⌘←)", forSegment: 0)
        stepControl.setToolTip("Back to the present", forSegment: 1)
        stepControl.setToolTip("Next (⌘→)", forSegment: 2)
        stepControl.target = self
        stepControl.action = #selector(stepped)
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
        [Self.layoutItem, .flexibleSpace, Self.scaleItem, .flexibleSpace, Self.stepItem, Self.searchItem]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                        willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case Self.layoutItem:
            return item(identifier, label: "View", control: layoutControl,
                        help: "The list, both side by side, or the map")
        case Self.scaleItem:
            return item(identifier, label: "Period", control: scaleControl,
                        help: "A day, week, month or year at a time")
        case Self.stepItem:
            return item(identifier, label: "Go", control: stepControl, help: "Move through time")
        case Self.searchItem:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.searchField.delegate = self
            item.searchField.placeholderString = "Company, app, country or address"
            item.preferredWidthForSearchField = 240
            searchField = item.searchField
            return item
        default:
            return nil
        }
    }

    private func item(_ identifier: NSToolbarItem.Identifier, label: String, control: NSControl,
                      help: String) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = control
        item.label = label
        item.toolTip = help
        return item
    }
}
