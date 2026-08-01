import AppKit
import Combine
import NetworkMonitorCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let model = MonitorViewModel()
    private var titleObserver: AnyCancellable?
    private var popoverMonitor: Any?
    private var settingsWindow: NSWindow?
    /// Invisible stand-in for the status item that the popover anchors to.
    /// See `anchorView(under:)`.
    private var anchorWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpPopover()
        // Installs predating SMAppService still have a LaunchAgent plist; it
        // has to go before the first-launch check, or both would start a copy.
        LoginItem.migrateLegacyAgentIfNeeded()
        enableLoginItemOnFirstLaunch()
        model.start()
        observeTitle()
    }

    /// "Start at login" ships on. Applied exactly once, tracked by a flag, so
    /// switching it off in Settings sticks and is never silently re-enabled.
    private func enableLoginItemOnFirstLaunch() {
        let key = "hasConfiguredLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        // The installer may already have set it up; rewriting is pointless.
        guard !LoginItem.isEnabled else { return }
        // Only meaningful from an installed bundle. Enabling it while running out
        // of .build would pin the agent to a path `swift package clean` deletes.
        guard Bundle.main.executableURL?.path.contains(".app/Contents/MacOS/") == true
        else { return }
        try? LoginItem.enable()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    // MARK: Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageOnly
        applyTitle()
    }

    /// Title construction lives in `MenuBarTitle` so its width-stability and
    /// menu-bar-fit invariants are covered by the test suite.
    private func applyTitle() {
        statusItem.button?.image = model.menuBarImage
    }

    private func observeTitle() {
        // Republish on either rate changing; the model already throttles to the
        // 0.5 s sampler so this cannot outpace the display.
        titleObserver = model.$downBytesPerSecond
            .combineLatest(model.$upBytesPerSecond)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyTitle() }
    }

    // MARK: Popover

    private func setUpPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        let root = MenuBarPopoverView(
            model: model,
            onSettings: { [weak self] in self?.showSettings() })
        let host = NSHostingController(rootView: root)
        // Keeps `preferredContentSize` in step with what SwiftUI lays out.
        //
        // Without it the controller reports (0, 0) until after the first show, and
        // `NSPopover` falls back to its own 320×320 default to place the window —
        // then shrinks to the real content height keeping the *bottom* edge put, so
        // the popover lands roughly one default-height below the menu bar. The same
        // gap also froze the height at whatever the content measured on the first
        // frame: opening on the empty state and having the app rows arrive a moment
        // later left the list clipped to the empty state's height.
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            closePopover()
            return
        }
        guard let button = statusItem.button else { return }
        model.setPopoverOpen(true)
        if let anchor = anchorView(under: button) {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        // An LSUIElement app is not active by default, so without this the
        // popover renders unfocused and swallows the first click.
        NSApp.activate(ignoringOtherApps: true)
        clearInitialFocus()

        // `.transient` dismisses on outside clicks but does not tell us, and the
        // model needs to know in order to stop rebuilding rows.
        popoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            DispatchQueue.main.async { self.closePopover() }
        }
    }

    /// Opens the popover with nothing focused.
    ///
    /// The gear is the only focusable control in there, so on becoming key the
    /// window hands it first responder and it opens wearing a focus ring the
    /// user never asked for. Dropping first responder is deliberately not the
    /// same as making the button unfocusable: the key view loop still reaches
    /// it, so Tab focuses it — ring and all — for anyone navigating by keyboard.
    ///
    /// Deferred a turn because SwiftUI assigns focus after the window is shown;
    /// clearing it inline would be undone immediately.
    private func clearInitialFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.popover.contentViewController?.view.window else { return }
            window.makeFirstResponder(nil)
        }
    }

    /// An invisible window parked exactly where the status item is, for the
    /// popover to anchor to instead of the item itself.
    ///
    /// `NSPopover` re-anchors against its positioning view every time the
    /// content size changes. Anchoring to the status item is fine while the menu
    /// bar is on screen — but with "Automatically hide and show the menu bar"
    /// enabled (confirmed as the trigger here: `_HIHideMenuBar = 1`), the menu
    /// bar is gone by the time the user expands a row. The hidden item resolves
    /// to an off-screen rect and the popover jumps to the far left of the
    /// display. Measured, anchored to the status item: placed at x=657, and
    /// x=0 after expanding. Anchored to this window: x=644 both before and after.
    ///
    /// A fixed content height used to hide this by never resizing at all, which
    /// is why removing it looked like the cause. It was not — it only removed
    /// the thing suppressing the re-anchor.
    ///
    /// The item's position is read at click time, which is the one moment it is
    /// guaranteed to be on screen: the user just clicked it. The stand-in then
    /// stays put for as long as the popover is open, so every later re-anchor
    /// resolves to the same rect.
    private func anchorView(under button: NSStatusBarButton) -> NSView? {
        guard let itemWindow = button.window else { return nil }
        let rect = itemWindow.convertToScreen(button.convert(button.bounds, to: nil))
        // A menu bar that is already hidden gives a rect off every screen; with
        // nothing trustworthy to anchor to, let AppKit place it as before.
        guard NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) else { return nil }

        let window = anchorWindow ?? {
            let w = NSWindow(contentRect: rect, styleMask: [.borderless],
                             backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            // Above normal windows so the popover's arrow is not clipped, and
            // excluded from window lists so it cannot be cycled to.
            w.level = .statusBar
            w.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .stationary]
            anchorWindow = w
            return w
        }()

        window.setFrame(rect, display: false)
        window.contentView = NSView(frame: NSRect(origin: .zero, size: rect.size))
        window.orderFrontRegardless()
        return window.contentView
    }

    private func closePopover() {
        popover.performClose(nil)
        model.setPopoverOpen(false)
        if let monitor = popoverMonitor {
            NSEvent.removeMonitor(monitor)
            popoverMonitor = nil
        }
        anchorWindow?.orderOut(nil)
    }

    // MARK: Right-click menu

    private func showMenu() {
        let menu = NSMenu()

        menu.addItem(withTitle: "Settings…",
                     action: #selector(showSettings), keyEquivalent: ",")

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        for item in menu.items where item.action != nil { item.target = self }
        // Quit stays wired to NSApp rather than to us.
        menu.items.last?.target = NSApp

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Detach immediately so the next left-click opens the popover, not the menu.
        statusItem.menu = nil
    }

    // MARK: Settings window

    @objc private func showSettings() {
        if popover.isShown { closePopover() }

        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false)
            window.title = "NetworkMonitor Settings"
            window.contentViewController = NSHostingController(
                rootView: SettingsView(model: model))
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }

        // Re-position on every open: the window may have been moved, or opened on
        // a different screen since last time.
        if let window = settingsWindow { position(window) }

        // An LSUIElement app is not active by default, so without this the
        // window opens behind whatever the user was using.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Centres the settings window, keeping its title bar clear of the menu bar.
    ///
    /// With "Automatically hide and show the menu bar" enabled, the menu bar draws
    /// *over* whatever is beneath it rather than shrinking the usable area, so a
    /// window whose title bar sits in the top ~22 pt has its close button covered
    /// whenever the menu bar appears. The top edge is therefore clamped to exactly
    /// one menu bar height below the top of the screen.
    private func position(_ window: NSWindow) {
        // SwiftUI sizing is not final until the content has laid out; positioning
        // before that would centre a stale frame.
        if let content = window.contentViewController?.view {
            content.layoutSubtreeIfNeeded()
            window.setContentSize(content.fittingSize)
        }

        guard let screen = window.screen ?? NSScreen.main else { return }
        // `safeAreaInsets.top` covers notched displays, where the menu bar is
        // taller than the classic status bar thickness.
        let menuBarHeight = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top)

        var frame = window.frame
        frame.origin.x = screen.frame.midX - frame.width / 2

        let highestAllowedTop = screen.frame.maxY - menuBarHeight
        let centredTop = screen.frame.midY + frame.height / 2
        frame.origin.y = min(centredTop, highestAllowedTop) - frame.height
        // Never push the window off the bottom of the screen to satisfy the clamp.
        frame.origin.y = max(frame.origin.y, screen.visibleFrame.minY)

        window.setFrame(frame, display: false)
    }
}
