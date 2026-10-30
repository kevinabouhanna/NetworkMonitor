import AppKit
import SwiftUI

/// One area of Settings, shown as a button in the window's toolbar.
public enum SettingsPane: String, CaseIterable {
    case general, speedTest, history, connections, hotspot, about

    public var title: String {
        switch self {
        case .general:   return "General"
        case .speedTest: return "Speed Test"
        case .history:   return "History"
        case .connections: return "Connections"
        case .hotspot:   return "Hotspot"
        case .about:     return "About"
        }
    }

    public var symbol: String {
        switch self {
        case .general:   return "gearshape"
        case .speedTest: return "gauge.with.dots.needle.67percent"
        case .history:   return "chart.bar.xaxis"
        case .connections: return "globe"
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
/// - the window titled after the pane, and sized to it, up to the height of the
///   screen, past which the pane scrolls;
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
    /// Caps the content at the screen's height; see `keepOnScreen()`.
    private var heightCap: NSLayoutConstraint!
    private var screenObservers: [NSObjectProtocol] = []
    /// The frame at the last resize or move; see `windowDidResize()`.
    private var lastFrame: NSRect?

    /// How high the window's top may go on a screen. `AppDelegate` sets it to
    /// just under the menu bar, which it knows the real height of: an
    /// auto-hidden menu bar leaves `visibleFrame` running to the top of the
    /// screen, and covers the title bar there whenever it's revealed.
    public var highestTop: (NSScreen) -> CGFloat = { $0.visibleFrame.maxY }

    public init(model: MonitorViewModel, history: HistoryViewModel,
                connections: ConnectionsViewModel, onOpenConnections: @escaping () -> Void,
                onUninstall: @escaping () -> Void, defaults: UserDefaults = .standard) {
        self.history = history
        self.defaults = defaults
        let state = SettingsPaneState()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsMetrics.paneWidth, height: 400),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()

        tabs.tabStyle = .toolbar
        tabs.transitionOptions = Self.paneTransition
        for pane in SettingsPane.allCases {
            let host: NSViewController
            switch pane {
            case .general:   host = Self.paneHost(GeneralSettingsPane(model: model, state: state), width: SettingsMetrics.paneWidth)
            case .speedTest: host = Self.paneHost(SpeedTestSettingsPane(speedTest: model.speedTest), width: SettingsMetrics.paneWidth)
            case .history:   host = Self.paneHost(HistoryView(model: history), width: SettingsMetrics.paneWidth)
            case .connections:
                host = Self.paneHost(ConnectionsSettingsPane(model: connections,
                                                             glance: ConnectionsGlance(monitor: model),
                                                             filter: model.filter,
                                                             firewall: model.firewall,
                                                             geoData: model.geoData,
                                                             onOpen: onOpenConnections),
                                     width: SettingsMetrics.paneWidth)
            case .hotspot:   host = Self.paneHost(HotspotSettingsPane(metering: model.metering, state: state, filter: model.filter), width: SettingsMetrics.paneWidth)
            case .about:     host = Self.paneHost(AboutSettingsPane(updates: model.updates, onUninstall: onUninstall), width: SettingsMetrics.paneWidth)
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

        // Required, so it outranks every pane's own height. A pane taller than
        // this scrolls inside the window instead of stretching it.
        heightCap = tabs.view.heightAnchor.constraint(lessThanOrEqualToConstant: 10_000)
        heightCap.isActive = true
        let center = NotificationCenter.default
        screenObservers = [
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                self?.windowDidResize()
            },
            // Dragged by the user: that is where it stays centred from now on.
            center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                self?.lastFrame = self?.window.frame
            },
            // Moved to a smaller screen, it has to fit that one.
            center.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in
                self?.keepOnScreen()
            },
        ]
    }

    deinit {
        screenObservers.forEach(NotificationCenter.default.removeObserver)
    }

    /// How one pane gives way to the next: at once.
    ///
    /// No crossfade (#61). It ran about 0.7 s on every switch, after blocking
    /// the main thread 40–80 ms to set up, and that was the lag. While it ran,
    /// the outgoing pane stayed on screen in a window already resized for the
    /// next one, which is where a passing scroll bar came from.
    ///
    /// `.allowUserInteraction` keeps the toolbar answering (#55). Without it,
    /// AppKit ignores clicks until a transition ends: a second tab clicked
    /// within about 0.3 s of the first did nothing.
    public static let paneTransition: NSViewController.TransitionOptions = [.allowUserInteraction]

    /// A pane in a scroll view, which scrolls only once the pane is taller than
    /// the window can be (#46). The scroll view takes the pane's full height as
    /// its own, so the window still grows and shrinks with the pane up to then.
    ///
    /// The width is fixed here, not by the pane. With scroll bars set to show
    /// always, the scroll bar took its width from outside a fixed-width pane:
    /// the window grew 17 pt wider when the pane scrolled, and stayed that way.
    /// Panes fill the width they're given, up to this.
    public static func paneHost<Content: View>(_ view: Content, width: CGFloat) -> NSViewController {
        let host = PaneHostingController(view, width: width)
        host.sizingOptions = [.preferredContentSize]
        return host
    }

    /// Whether a pane scrolls: taller than the window can be on this screen.
    public static func scrolls(paneHeight: CGFloat, tallest: CGFloat) -> Bool {
        paneHeight > tallest + 0.5
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
        keepOnScreen()
        guard let child = tabs.tabView.selectedTabViewItem?.viewController else { return }
        child.view.layoutSubtreeIfNeeded()
        let size = child.preferredContentSize.height > 0 ? child.preferredContentSize
                                                         : child.view.fittingSize
        fit(size)
    }

    public func windowWillClose() {
        setHistoryOnScreen(false)
        // Opened by a colour well in General. Left up, it would outlive the
        // window it belongs to once the app is back in the menu bar.
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.close() }
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

    /// Resizes to a pane of `size`, at once, like the pane itself (#61). See
    /// `frame(for:current:usable:)`.
    private func fit(_ size: NSSize) {
        guard size.width > 0, size.height > 0 else { return }
        let wanted = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        let frame = Self.frame(for: wanted, current: window.frame, usable: usableFrame())
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true)
    }

    /// The part of the window's screen below the menu bar. Before the window is
    /// first shown it has no screen; it opens on the main one.
    private func usableFrame() -> NSRect? {
        (window.screen ?? NSScreen.main).map { screen in
            var usable = screen.visibleFrame
            usable.size.height = min(usable.maxY, highestTop(screen)) - usable.minY
            return usable
        }
    }

    private func windowDidResize() {
        if let lastFrame {
            let centred = Self.centred(window.frame, after: lastFrame)
            if centred != window.frame { window.setFrame(centred, display: true) }
        }
        lastFrame = window.frame
        keepOnScreen()
    }

    /// `frame` moved back to the centre of `last`, when it got there by a
    /// resize that kept the left edge (#57).
    ///
    /// Auto Layout resizes the window that way when it gets in before
    /// `fit(_:)`, which happens when a tab is clicked while the last pane is
    /// still changing. Between History and a narrower pane that moved the window
    /// 60 pt left each time, and `fit(_:)` then centred on where it had moved
    /// to. A resize that changes the width and moves the left edge is
    /// `fit(_:)`'s own, already centred.
    public static func centred(_ frame: NSRect, after last: NSRect) -> NSRect {
        guard frame.width != last.width, frame.minX == last.minX else { return frame }
        var centred = frame
        centred.origin.x = last.midX - frame.width / 2
        return centred
    }

    /// Keeps the window within its screen after it resizes (#46).
    ///
    /// Most resizes don't come from `fit(_:)`. A list opening or a test
    /// finishing changes the pane's height, and Auto Layout resizes the window
    /// to match, keeping its top edge where it is. That ran the window off the
    /// bottom of the screen. So the content is capped at the screen's height,
    /// and a window that grew past the bottom moves up.
    private func keepOnScreen() {
        guard let usable = usableFrame() else { return }
        let chrome = window.frame.height - window.contentLayoutRect.height
        let cap = usable.height - chrome
        if heightCap.constant != cap { heightCap.constant = cap }
        if let pane = tabs.tabView.selectedTabViewItem?.viewController,
           let scrolling = (pane as? ScrollingPane)?.scrolling {
            let scrolls = Self.scrolls(paneHeight: pane.preferredContentSize.height, tallest: cap)
            if scrolling.scrolls != scrolls { scrolling.scrolls = scrolls }
        }
        let frame = Self.frame(for: window.frame.size, current: window.frame, usable: usable)
        if frame != window.frame { window.setFrame(frame, display: true) }
    }

    /// Where the window goes for a pane that wants a frame of `size`: centred
    /// where it is, with its top edge kept, as settings windows do. Within
    /// `usable`, the part of the screen below the menu bar: never off its bottom
    /// or above its top, and never taller than it, which is where the pane
    /// starts to scroll instead.
    public static func frame(for size: NSSize, current: NSRect, usable: NSRect?) -> NSRect {
        var frame = NSRect(x: current.midX - size.width / 2, y: current.maxY - size.height,
                           width: size.width, height: size.height)
        guard let usable else { return frame }
        if frame.height > usable.height {
            frame.size.height = usable.height
            frame.origin.y = current.maxY - frame.height
        }
        frame.origin.y = min(max(frame.origin.y, usable.minY), usable.maxY - frame.height)
        return frame
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

/// Whether the pane on screen scrolls, which is when it gets a scroll bar (#65).
///
/// With scroll bars set to show always, a scroll bar takes 15 pt of the pane's
/// width while it's there. A Hotspot list that made the pane scroll then wrapped
/// a footnote onto a second line, and once the list closed the pane kept that
/// line's height: 14 pt of extra space until another pane was chosen. Kept out
/// of panes that fit, it can't change how they're laid out.
final class PaneScrolling: ObservableObject {
    @Published var scrolls = false
}

protocol ScrollingPane: AnyObject {
    var scrolling: PaneScrolling { get }
}

/// A pane in its scroll view, at the width every pane shares.
struct PaneScrollView<Content: View>: View {
    @ObservedObject var scrolling: PaneScrolling
    let width: CGFloat
    let content: Content

    var body: some View {
        ScrollView(.vertical) {
            // Scroll views inside the pane, History's lists, keep their own.
            content.scrollIndicators(.automatic)
        }
        .scrollIndicators(scrolling.scrolls ? .automatic : .never)
        .frame(width: width)
    }
}

private final class PaneHostingController<Content: View>: NSHostingController<PaneScrollView<Content>>,
                                                        ScrollingPane {
    let scrolling: PaneScrolling

    init(_ content: Content, width: CGFloat) {
        let scrolling = PaneScrolling()
        self.scrolling = scrolling
        super.init(rootView: PaneScrollView(scrolling: scrolling, width: width, content: content))
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("not used") }
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
