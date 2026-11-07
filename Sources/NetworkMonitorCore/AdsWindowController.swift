import AppKit
import Combine
import SwiftUI

/// The Ads and Trackers window (#251): its own, like Connections, since what
/// the lists blocked is a job of its own and not every connection. On
/// Overview its toolbar has Connections' period and ‹ Today › (#311).
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
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        observation = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshControls() }
        }
        refreshControls()
    }

    public var isVisible: Bool { window.isVisible }

    public func select(_ tab: AdsViewModel.Tab) { model.tab = tab }

    public func windowDidShow() {
        model.windowDidOpen()
        refreshControls()
    }

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
        scaleControl.selectedSegment = HistoryScale.allCases.firstIndex(of: model.scale) ?? 0
        stepControl.setEnabled(model.canStepBack, forSegment: 0)
        stepControl.setEnabled(model.canStepForward, forSegment: 2)
        showPeriod(model.tab.hasPeriod)
    }

    /// The period and ‹ Today › are in the toolbar only on Overview (#311):
    /// the log is the present, rules have no period, and the lists count
    /// today's blocks, so elsewhere they'd only sit there doing nothing.
    /// The tabs come last, so they stay where they are when it goes.
    private func showPeriod(_ show: Bool) {
        guard let toolbar = window.toolbar else { return }
        for item in toolbar.items where [Self.scaleItem, Self.stepItem].contains(item.itemIdentifier) {
            if #available(macOS 15, *) {
                item.isHidden = !show
            } else {
                item.view?.isHidden = !show
            }
        }
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
        [Self.scaleItem, Self.stepItem, .flexibleSpace, Self.tabItem]
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
