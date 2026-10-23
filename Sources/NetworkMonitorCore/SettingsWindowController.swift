import AppKit
import SwiftUI

/// One area of Settings, shown as a button in the window's toolbar.
public enum SettingsPane: String, CaseIterable {
    case general, speedTest, history, hotspot, about

    public var title: String {
        switch self {
        case .general:   return "General"
        case .speedTest: return "Speed Test"
        case .history:   return "History"
        case .hotspot:   return "Hotspot"
        case .about:     return "About"
        }
    }

    public var symbol: String {
        switch self {
        case .general:   return "gearshape"
        case .speedTest: return "gauge.with.dots.needle.67percent"
        case .history:   return "chart.bar.xaxis"
        case .hotspot:   return "personalhotspot"
        case .about:     return "info.circle"
        }
    }

    static let lastKey = "settingsPane"

    /// The pane Settings last showed, which it reopens on: the HIG's "restore the
    /// most recently viewed pane", since people often come back to adjust the
    /// same thing again.
    public static func last(in defaults: UserDefaults = .standard) -> SettingsPane {
        SettingsPane(rawValue: defaults.string(forKey: lastKey) ?? "") ?? .general
    }

    public func remember(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.lastKey)
    }
}

/// The Settings window: a toolbar of panes, in the shape Apple's guidelines give
/// a Mac app's settings.
///
/// - a toolbar that never changes and always shows which pane is open;
/// - the window titled after the pane, and sized to it;
/// - minimise and zoom dimmed, because Command-comma brings it straight back
///   and the window is always the size of what it shows;
/// - the last pane remembered.
///
/// It also carries the app's features, not only its settings: the speed test,
/// Usage History and uninstalling were each reachable only through an unlabelled
/// icon or the right-click menu, and anyone who missed those would look here.
/// Usage History lives here and nowhere else, so nothing exists twice.
///
/// `AppDelegate` owns the window's lifecycle (activation policy, menu bar,
/// positioning) and calls `windowWillClose()`.
public final class SettingsWindowController: NSObject {

    public let window: NSWindow
    private let tabs = PaneTabViewController()
    private let history: HistoryViewModel
    private let defaults: UserDefaults
    private var sizeObservation: NSKeyValueObservation?
    private var historyOnScreen = false

    public init(model: MonitorViewModel, history: HistoryViewModel,
                onUninstall: @escaping () -> Void, defaults: UserDefaults = .standard) {
        self.history = history
        self.defaults = defaults
        let state = SettingsPaneState()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 400),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()

        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade]
        for pane in SettingsPane.allCases {
            let host: NSViewController
            switch pane {
            case .general:   host = Self.host(GeneralSettingsPane(model: model, state: state))
            case .speedTest: host = Self.host(SpeedTestSettingsPane(speedTest: model.speedTest))
            case .history:   host = Self.host(HistoryView(model: history))
            case .hotspot:   host = Self.host(HotspotSettingsPane(metering: model.metering, state: state))
            case .about:     host = Self.host(AboutSettingsPane(onUninstall: onUninstall))
            }
            host.title = pane.title
            let item = NSTabViewItem(viewController: host)
            item.label = pane.title
            item.identifier = pane.rawValue
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        window.contentViewController = tabs
        // Only once the tabs are in the window: loading them selects the first
        // pane by itself, and that is not a choice to remember. Heard earlier, it
        // overwrote the last pane, so Settings opened on General after a relaunch.
        tabs.onSelect = { [weak self] pane in self?.didSelect(pane) }
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.toolbar?.allowsUserCustomization = false
    }

    private static func host<Content: View>(_ view: Content) -> NSHostingController<Content> {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        return host
    }

    /// Selects `pane`, or the last one viewed, ready for `AppDelegate` to show.
    public func select(_ pane: SettingsPane?) {
        let target = pane ?? SettingsPane.last(in: defaults)
        if let index = SettingsPane.allCases.firstIndex(of: target),
           tabs.selectedTabViewItemIndex != index {
            tabs.selectedTabViewItemIndex = index
        } else {
            didSelect(target)
        }
    }

    public var isVisible: Bool { window.isVisible }

    /// Sizes the window to the selected pane now, without animating, so it can be
    /// positioned at its real size before it is shown.
    public func fitSelectedPane() {
        guard let child = tabs.tabView.selectedTabViewItem?.viewController else { return }
        child.view.layoutSubtreeIfNeeded()
        let size = child.preferredContentSize.height > 0 ? child.preferredContentSize
                                                         : child.view.fittingSize
        fit(size, animate: false)
    }

    public func windowWillClose() {
        setHistoryOnScreen(false)
    }

    // MARK: Pane changes

    private func didSelect(_ pane: SettingsPane) {
        pane.remember(in: defaults)
        window.title = pane.title
        setHistoryOnScreen(pane == .history)
        guard let child = tabs.tabViewItems.first(where: { $0.identifier as? String == pane.rawValue })?
            .viewController else { return }
        // The window follows the pane's size as its content changes (a list
        // opened, a test finishing), not only when the pane is chosen.
        sizeObservation = child.observe(\.preferredContentSize, options: [.initial, .new]) { [weak self] child, _ in
            DispatchQueue.main.async { self?.fit(child.preferredContentSize) }
        }
    }

    /// Resizes to `size`, keeping the top edge where it is, as settings windows do.
    private func fit(_ size: NSSize, animate: Bool = true) {
        guard size.width > 0, size.height > 0 else { return }
        let content = NSRect(origin: .zero, size: size)
        var frame = window.frameRect(forContentRect: content)
        let current = window.frame
        frame.origin.x = current.midX - frame.width / 2
        frame.origin.y = current.maxY - frame.height
        // Never below the bottom of the screen it is on.
        if let visible = window.screen?.visibleFrame, frame.minY < visible.minY {
            frame.origin.y = visible.minY
        }
        guard frame != current else { return }
        window.setFrame(frame, display: true, animate: animate && window.isVisible)
    }

    private func setHistoryOnScreen(_ onScreen: Bool) {
        let shown = onScreen && window.isVisible
        guard shown != historyOnScreen else { return }
        historyOnScreen = shown
        if shown { history.windowDidOpen() } else { history.windowDidClose() }
    }

    /// Re-run after the window is shown, since `isVisible` was false when the
    /// pane was selected.
    public func windowDidShow() {
        if let id = tabs.tabView.selectedTabViewItem?.identifier as? String,
           let pane = SettingsPane(rawValue: id) {
            setHistoryOnScreen(pane == .history)
        }
    }
}

/// Reports which pane was chosen. `NSTabViewController` is the tab view's
/// delegate already, so the hook is an override rather than a delegate of our own.
private final class PaneTabViewController: NSTabViewController {
    var onSelect: ((SettingsPane) -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let id = tabViewItem?.identifier as? String, let pane = SettingsPane(rawValue: id) {
            onSelect?(pane)
        }
    }
}
