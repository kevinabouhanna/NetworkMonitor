import AppKit
import Combine
import SwiftUI

/// The Ads and Trackers window (#251): its own, like Connections, since what
/// the lists blocked is a job of its own and not every connection. Its
/// toolbar is Connections' period and ‹ Today ›.
public final class AdsWindowController: NSObject, NSToolbarDelegate {

    public let window: NSWindow
    private let model: AdsViewModel
    private let tabControl = NSSegmentedControl()
    private let scaleControl = NSSegmentedControl()
    private let stepControl = NSSegmentedControl()
    private var observation: AnyCancellable?

    private static let tabItem = NSToolbarItem.Identifier("tab")
    private static let scaleItem = NSToolbarItem.Identifier("scale")
    private static let stepItem = NSToolbarItem.Identifier("step")

    public init(model: AdsViewModel) {
        self.model = model
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        let host = NSHostingController(rootView: AdsView(model: model))
        host.sizingOptions = []
        window.contentViewController = host
        window.title = "Ads and Trackers"
        window.setContentSize(NSSize(width: 900, height: 640))
        window.contentMinSize = NSSize(width: AdsMetrics.minWidth, height: AdsMetrics.minHeight)
        window.isReleasedWhenClosed = false

        configureControls()
        let toolbar = NSToolbar(identifier: "Ads")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Self.scaleItem]
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        observation = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshControls() }
        }
        refreshControls()
    }

    public var isVisible: Bool { window.isVisible }

    public func select(_ tab: AdsViewModel.Tab) { model.tab = tab }

    public func windowDidShow() { model.windowDidOpen() }

    public func windowWillClose() { model.windowDidClose() }

    private func configureControls() {
        let tabs = AdsViewModel.Tab.allCases
        tabControl.segmentCount = tabs.count
        tabControl.trackingMode = .selectOne
        for (index, tab) in tabs.enumerated() {
            tabControl.setLabel(tab.label, forSegment: index)
        }
        tabControl.target = self
        tabControl.action = #selector(tabChosen)

        let scales = HistoryScale.allCases
        scaleControl.segmentCount = scales.count
        scaleControl.trackingMode = .selectOne
        for (index, scale) in scales.enumerated() {
            scaleControl.setLabel(scale.label, forSegment: index)
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
        stepControl.setToolTip("Previous", forSegment: 0)
        stepControl.setToolTip("Back to the present", forSegment: 1)
        stepControl.setToolTip("Next", forSegment: 2)
        stepControl.target = self
        stepControl.action = #selector(stepped)
    }

    private func refreshControls() {
        tabControl.selectedSegment = AdsViewModel.Tab.allCases.firstIndex(of: model.tab) ?? 0
        // The log is the present, live, and rules have no period. The lists
        // count their blocks in it (#254).
        let overview = model.tab.hasPeriod
        scaleControl.isEnabled = overview
        // Nothing chosen while it doesn't apply, which a disabled control
        // alone doesn't show.
        scaleControl.selectedSegment = overview ? HistoryScale.allCases.firstIndex(of: model.scale) ?? 0 : -1
        stepControl.setEnabled(overview && model.canStepBack, forSegment: 0)
        stepControl.setEnabled(overview, forSegment: 1)
        stepControl.setEnabled(overview && model.canStepForward, forSegment: 2)
    }

    @objc private func tabChosen(_ sender: NSSegmentedControl) {
        model.tab = AdsViewModel.Tab.allCases[sender.selectedSegment]
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
        [Self.tabItem, .flexibleSpace, Self.scaleItem, .flexibleSpace, Self.stepItem]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                        willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case Self.tabItem:
            item.view = tabControl
            item.label = "View"
            item.menuFormRepresentation = SegmentMenu.item(for: tabControl, label: "View",
                                                           titles: AdsViewModel.Tab.allCases.map(\.label))
            item.toolTip = "What was blocked, or every connection as it's decided"
        case Self.scaleItem:
            item.view = scaleControl
            item.label = "Period"
            item.menuFormRepresentation = SegmentMenu.item(for: scaleControl, label: "Period",
                                                           titles: HistoryScale.allCases.map(\.label))
            item.toolTip = "A day, week, month or year at a time"
        case Self.stepItem:
            item.view = stepControl
            item.label = "Go"
            item.menuFormRepresentation = SegmentMenu.item(for: stepControl, label: "Go",
                                                           titles: ["Previous", "Today", "Next"])
            item.toolTip = "Move through time"
        default:
            return nil
        }
        return item
    }
}
