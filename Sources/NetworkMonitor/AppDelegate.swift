import AppKit
import Combine
import NetworkMonitorCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let model = MonitorViewModel()
    private var titleObserver: AnyCancellable?
    private var popoverMonitor: Any?
    /// Pointer watchers that exist only while a revealed menu bar holds focus
    /// the popover had. See `restoreFocusWhenMenuBarHides()`.
    private var menuBarMonitors: [Any] = []
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
        offerHelperUpdateIfNeeded()
    }

    /// The first launch of a new version whose helper is newer than the one
    /// installed asks, once, to update it — the same administrator dialog as
    /// switching the feature on. Only while the feature is on, never twice for
    /// the same build, and a few seconds in so the menu bar item is there to
    /// say whose dialog it is. Declined, Settings keeps an Allow button.
    private func offerHelperUpdateIfNeeded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.model.metering.ensureHelper(userAsked: false)
        }
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
        // One signal for the pair, raised only when the rendered title changes and
        // already on the main queue when it arrives. That removes the
        // `combineLatest` that re-paired two publishers which never moved
        // independently, and the `receive(on:)` hop that was load-bearing only
        // because `@Published` fires in `willSet`. See
        // `MonitorViewModel.downBytesPerSecond`.
        titleObserver = model.menuBarRateDidChange
            .sink { [weak self] _ in self?.applyTitle() }
    }

    // MARK: Popover

    private func setUpPopover() {
        popover = NSPopover()
        // Semi-transient, not transient, so that losing focus alone never closes
        // it: `appDidResignActive` makes that call instead, because an auto-hidden
        // menu bar takes focus just by appearing. Esc still closes it, and the
        // outside-click monitor in `togglePopover` handles clicks elsewhere.
        popover.behavior = .semitransient
        popover.animates = false
        popover.delegate = self
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
        // Assigning the controller is itself what measures it, and that is worth
        // knowing rather than assuming: the setter loads the view, so with
        // `sizingOptions` set first, `preferredContentSize` is already populated on
        // the line after this one. Probed directly on a six-row stand-in —
        // `isViewLoaded` true and (284, 160) reported before any layout was
        // requested, unchanged by a following `layoutSubtreeIfNeeded()`.
        //
        // The ordering therefore matters and the absence of a forced layout does
        // not. It also means the first show does not depend on anything having
        // invalidated this view tree beforehand — which it no longer does, now that
        // the rates are not `@Published` (see `MonitorViewModel.downBytesPerSecond`).
        popover.contentViewController = host

        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification, object: nil)
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

        // Clicks in other apps, the menu bar included. A click on the status item
        // itself is left to `statusItemClicked`, which toggles: with an auto-hidden
        // menu bar that click reaches this monitor too, and closing here as well
        // had the same click reopen the popover a moment later.
        popoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.popover.isShown, !self.pointerIsOnStatusItem else { return }
            DispatchQueue.main.async { self.closePopover() }
        }
    }

    private var pointerIsOnStatusItem: Bool {
        guard let frame = statusItem.button?.window?.frame else { return false }
        // `NSMouseInRect`, not `contains`: the top row of the item reports
        // y == maxY, which `contains` excludes.
        return NSMouseInRect(NSEvent.mouseLocation, frame, false)
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
    }

    /// Every way the popover closes ends here — the status item, an outside
    /// click, Esc, a switch to another app — so none of them can skip the
    /// bookkeeping. Esc and ⌘-Tab used to: `.transient` closed it on its own,
    /// leaving the model rebuilding rows for a list nobody could see until the
    /// next time the popover opened.
    ///
    /// Sent synchronously from within `performClose`, so this is done before any
    /// click that follows could reopen the popover.
    func popoverWillClose(_ notification: Notification) {
        model.setPopoverOpen(false)
        if let monitor = popoverMonitor {
            NSEvent.removeMonitor(monitor)
            popoverMonitor = nil
        }
        stopWatchingMenuBar()
        anchorWindow?.orderOut(nil)
    }

    // MARK: Auto-hidden menu bar

    /// Decides whether losing focus closes the popover — which `.transient`
    /// decided by always closing it, and with "Automatically hide and show the
    /// menu bar" on that was wrong.
    ///
    /// An accessory app has no menu bar of its own, so when the pointer reveals
    /// the hidden one, macOS activates an app that has one: whichever was
    /// frontmost before the popover opened. Moving down to read the popover and
    /// back up to the menu bar closed it with no click at all. Measured with a
    /// stand-in app and synthesised pointer moves on macOS 27: each reveal posted
    /// `didActivateApplication` for the terminal, then `didResignActive`, then the
    /// transient close (`_NSPopoverProcessResignKey`).
    ///
    /// So losing focus with the pointer up in the menu bar is the bar appearing,
    /// and the popover rides it out. Losing it anywhere else — ⌘-Tab, Spotlight,
    /// a notification — is a real switch and closes it as before. Clicks, menu
    /// bar clicks included, still close it through the outside-click monitor.
    @objc private func appDidResignActive() {
        guard popover.isShown else { return }
        if pointerIsInMenuBar {
            restoreFocusWhenMenuBarHides()
        } else {
            closePopover()
        }
    }

    /// Hands focus back to the popover once the pointer leaves the menu bar.
    ///
    /// Without it the popover stays up but inactive after every reveal, and its
    /// next click only activates the app — the swallowed click `togglePopover`
    /// activates to avoid. Unless the user has switched to another app in the
    /// meantime: then the popover closes, rather than taking focus back from it.
    private func restoreFocusWhenMenuBarHides() {
        guard menuBarMonitors.isEmpty else { return }
        // The app the reveal activated, already frontmost by the time
        // `didResignActive` arrives. If it reads as this app, nothing is known,
        // and focus comes back regardless.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let revealedFor = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let pointerMoved = { [weak self] in
            guard let self, !self.pointerIsInMenuBar else { return }
            self.stopWatchingMenuBar()
            guard self.popover.isShown else { return }
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let switchedAway = revealedFor.map { $0 != ownPID && frontmost != $0 } ?? false
            if switchedAway {
                self.closePopover()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        // Both are needed. Leaving over another app's window reaches only the
        // global monitor, and leaving straight down into the popover only the
        // local one; each happened in testing.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { _ in pointerMoved() }) {
            menuBarMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in
            pointerMoved()
            return event
        }) {
            menuBarMonitors.append(local)
        }
    }

    private func stopWatchingMenuBar() {
        menuBarMonitors.forEach(NSEvent.removeMonitor)
        menuBarMonitors.removeAll()
    }

    /// Whether the pointer is up in the menu bar, whether or not it is showing.
    private var pointerIsInMenuBar: Bool {
        MenuBarStrip.contains(NSEvent.mouseLocation,
                              screens: NSScreen.screens.map { ($0.frame, menuBarHeight(on: $0)) })
    }

    /// See `MenuBarStrip.height` for why it takes all three readings.
    private func menuBarHeight(on screen: NSScreen) -> CGFloat {
        MenuBarStrip.height(statusItemThickness: NSStatusBar.system.thickness,
                            statusItemWindowHeight: statusItem.button?.window?.frame.height,
                            safeAreaTop: screen.safeAreaInsets.top)
    }

    // MARK: Right-click menu

    private func showMenu() {
        // The outside-click monitor leaves status item clicks alone, so this one
        // would otherwise open the menu over the popover. `toggleSpeedTest` also
        // decides whether to open the popover by whether it is shut.
        if popover.isShown { closePopover() }

        let menu = NSMenu()

        if SpeedTestRunner.isAvailable {
            let running = model.speedTest.phase.isRunning
            menu.addItem(withTitle: running ? "Stop Speed Test" : "Test Internet Speed",
                         action: #selector(toggleSpeedTest), keyEquivalent: "")
            // The last result on this connection, as a line to read rather than
            // an item to choose. Gone after a network change; see
            // `SpeedTestController.lastResult`.
            if let result = model.speedTest.lastResult, !running {
                let time = result.finishedAt.formatted(date: .omitted, time: .shortened)
                let unit = model.speedTest.unit
                let summary = "↓ \(ByteFormat.speed(result.downloadBitsPerSecond, unit: unit))   "
                    + "↑ \(ByteFormat.speed(result.uploadBitsPerSecond, unit: unit))   at \(time)"
                let item = NSMenuItem(title: summary, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        menu.addItem(withTitle: "Settings…",
                     action: #selector(showSettings), keyEquivalent: ",")

        menu.addItem(.separator())
        menu.addItem(withTitle: "Uninstall NetworkMonitor…",
                     action: #selector(uninstall), keyEquivalent: "")
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

    /// From the right-click menu. The popover stays shut unless the test needs
    /// an answer first — a metered connection asks before spending the data, and
    /// that question lives in the popover.
    @objc private func toggleSpeedTest() {
        let speedTest = model.speedTest
        if speedTest.phase.isRunning {
            speedTest.dismiss()
            return
        }
        speedTest.run()
        if case .confirming = speedTest.phase, !popover.isShown {
            togglePopover()
        }
    }

    // MARK: Uninstall

    /// The whole of `Scripts/uninstall.sh`, from the menu. Dragging the app to
    /// the Trash cannot put back the settings that needed no password — their
    /// record is the app's own journal, gone with it — so this is the clean way
    /// out, and it should not take Terminal to find it.
    @objc private func uninstall() {
        if popover.isShown { closePopover() }
        NSApp.activate(ignoringOtherApps: true)

        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = "Uninstall NetworkMonitor?"
        confirm.informativeText = "Every setting it changed is put back, its helper is "
            + "removed, your usage history is deleted, and the app is moved to the Trash."
        confirm.addButton(withTitle: "Uninstall")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        switch model.uninstall() {
        case .done:
            NSApp.terminate(nil)
        case .cancelled:
            // Nothing has changed: the helper step comes first for this reason.
            return
        case .failed(let message):
            let failure = NSAlert()
            failure.alertStyle = .critical
            failure.messageText = "NetworkMonitor couldn't finish uninstalling"
            failure.informativeText = message + "\n\nNothing was removed, so every "
                + "setting it changed can still be put back. Try again later."
            failure.runModal()
        }
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
            window.delegate = self
            settingsWindow = window
        }

        // An ordinary app for as long as Settings is open — in the Dock and the
        // app switcher, with a menu bar of its own — and an accessory app again
        // once it closes; see `windowWillClose`.
        //
        // As an accessory app it had none of those, and with an auto-hidden menu
        // bar that lost the window outright. Revealing the bar activates an app
        // that owns one, and that app's windows came forward over Settings, with
        // no Dock icon or ⌘-Tab entry left to bring it back. Measured on macOS 27
        // with a stand-in window: covered by the terminal on the first reveal as
        // an accessory app, frontmost and key through the same reveal as a
        // regular one.
        NSApp.mainMenu = mainMenu
        NSApp.setActivationPolicy(.regular)

        // Re-position on every open: the window may have been moved, or opened on
        // a different screen since last time.
        if let window = settingsWindow { position(window) }

        // An LSUIElement app is not active by default, so without this the
        // window opens behind whatever the user was using.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Back to a menu bar app when Settings closes. macOS hands focus back to
    /// whichever app had it before, unprompted — measured, also on macOS 27.
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === settingsWindow else { return }
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = nil
    }

    /// The menu bar NetworkMonitor shows while Settings is open, and only then.
    ///
    /// A regular app owns the menu bar, so it needs one; this is also what gives
    /// the window ⌘W, which did nothing without a menu to carry it (checked with
    /// a stand-in window: open after ⌘W without the menu, closed with it). Kept
    /// out of the popover's way: ⌘Q there quitting the app would be a new
    /// behaviour nobody asked for.
    private lazy var mainMenu: NSMenu = {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About NetworkMonitor",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…",
                        action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide NetworkMonitor",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others",
                        action: #selector(NSApplication.hideOtherApplications(_:)),
                        keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit NetworkMonitor",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close",
                           action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let menuBar = NSMenu()
        for submenu in [appMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            menuBar.addItem(item)
        }
        return menuBar
    }()

    /// Centres the settings window, keeping its title bar clear of the menu bar.
    ///
    /// With "Automatically hide and show the menu bar" enabled, the menu bar draws
    /// *over* whatever is beneath it rather than shrinking the usable area, so a
    /// window whose title bar sits in the top 30 pt has its close button covered
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

        var frame = window.frame
        frame.origin.x = screen.frame.midX - frame.width / 2

        // 30 pt on macOS 27, not the status item's 22 pt that this used to take,
        // which left the top 8 pt of the title bar under a revealed menu bar.
        let highestAllowedTop = screen.frame.maxY - menuBarHeight(on: screen)
        let centredTop = screen.frame.midY + frame.height / 2
        frame.origin.y = min(centredTop, highestAllowedTop) - frame.height
        // Never push the window off the bottom of the screen to satisfy the clamp.
        frame.origin.y = max(frame.origin.y, screen.visibleFrame.minY)

        window.setFrame(frame, display: false)
    }
}
