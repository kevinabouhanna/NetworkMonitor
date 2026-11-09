import AppKit
import Combine
import SwiftUI

/// The Ads and Trackers window (#251): its own, like Connections, since what
/// the lists blocked is a job of its own and not every connection. On
/// Overview its toolbar has Connections' period and ‹ Today › (#311); the
/// tabs are in the window, at the top of its content (#358).
public final class AdsWindowController: NSObject, NSToolbarDelegate {

    public let window: NSWindow
    private let model: AdsViewModel
    private let scaleControl = NSSegmentedControl()
    private let stepControl = NSSegmentedControl()
    private var observation: AnyCancellable?
    private var languageObservation: AnyCancellable?

    private static let scaleItem = NSToolbarItem.Identifier("scale")
    private static let stepItem = NSToolbarItem.Identifier("step")

    public init(model: AdsViewModel) {
        self.model = model
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        let host = NSHostingController(rootView: AdsView(model: model).localizedRoot())
        host.sizingOptions = []
        window.contentViewController = host
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

    /// The toolbar's gear: Settings › Ads, where the lists and rules are (#436).
    public var onSettings: () -> Void = {}

    @objc private func openSettings() { onSettings() }

    public func windowDidShow() {
        model.windowDidOpen()
        refreshControls()
    }

    public func windowWillClose() { model.windowDidClose() }

    private func configureControls() {
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
    /// changes: the title, the segments' labels and tooltips, and the toolbar
    /// items' names.
    private func nameControls() {
        window.title = L("Ads and Trackers")

        for (index, scale) in HistoryScale.allCases.enumerated() {
            scaleControl.setLabel(scale.label, forSegment: index)
        }

        stepControl.setImage(NSImage(systemSymbolName: "chevron.left", accessibilityDescription: L("Previous")),
                             forSegment: 0)
        stepControl.setLabel(L("Today"), forSegment: 1)
        stepControl.setImage(NSImage(systemSymbolName: "chevron.right", accessibilityDescription: L("Next")),
                             forSegment: 2)
        stepControl.setToolTip(L("Previous"), forSegment: 0)
        stepControl.setToolTip(L("Back to the present"), forSegment: 1)
        stepControl.setToolTip(L("Next"), forSegment: 2)

        for item in window.toolbar?.items ?? [] {
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
        case SettingsGear.identifier: return (L("Settings"), L("Settings for ads and trackers: the lists and your rules"))
        default:        return nil
        }
    }

    private func refreshControls() {
        scaleControl.selectedSegment = HistoryScale.allCases.firstIndex(of: model.scale) ?? 0
        stepControl.setEnabled(model.canStepBack, forSegment: 0)
        stepControl.setEnabled(model.canStepForward, forSegment: 2)
        showPeriod(model.tab.hasPeriod)
    }

    /// The period and ‹ Today › are in the toolbar only on Overview (#311):
    /// the log is the present, rules have no period, and the lists count
    /// today's blocks, so elsewhere they'd only sit there doing nothing.
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
        // As Connections: the period centred, ‹ Today › trailing, and the gear
        // last, where it stays put when the period hides on Log.
        [.flexibleSpace, Self.scaleItem, .flexibleSpace, Self.stepItem, SettingsGear.identifier]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                        willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == SettingsGear.identifier {
            return SettingsGear.item(target: self, action: #selector(openSettings),
                                     help: L("Settings for ads and trackers: the lists and your rules"))
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
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
