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
    /// Settings: toolbar panes for General, Speed Test, History, Hotspot and
    /// About. Created on first use.
    private var settingsController: SettingsWindowController?
    private var settings: SettingsWindowController {
        if let settingsController { return settingsController }
        let controller = SettingsWindowController(
            model: model, history: HistoryViewModel(monitor: model),
            connections: connectionsModel,
            onOpenConnections: { [weak self] in self?.showConnections() },
            onUninstall: { [weak self] in self?.uninstall() })
        controller.window.delegate = self
        controller.highestTop = { [weak self] screen in
            screen.frame.maxY - (self?.menuBarHeight(on: screen) ?? 0)
        }
        settingsController = controller
        return controller
    }
    /// Which companies, countries and servers the apps talk to. Created on
    /// first use.
    private var connectionsController: ConnectionsWindowController?
    /// One model for the window and Settings › Connections, so the layout
    /// chosen in one is the layout shown in the other.
    private lazy var connectionsModel = ConnectionsViewModel(monitor: model)
    private var connections: ConnectionsWindowController {
        if let connectionsController { return connectionsController }
        let controller = ConnectionsWindowController(model: connectionsModel)
        controller.window.delegate = self
        connectionsController = controller
        return controller
    }
    /// Ask Me's questions (#129), in a panel of their own.
    private var askController: AskController?
    /// The welcome window (#134), on first launch. Created when shown.
    private var welcomeController: WelcomeWindowController?
    private var welcomeCheck: AnyCancellable?
    /// Settings, Connections and the welcome window, whichever exist, without
    /// creating any to find out.
    private var ourWindows: [NSWindow] {
        [settingsController?.window, connectionsController?.window, welcomeController?.window].compactMap { $0 }
    }
    /// Those that are open, front to back.
    private var openWindows: [NSWindow] {
        let ours = ourWindows.filter(\.isVisible)
        return NSApp.orderedWindows.filter { window in ours.contains { $0 === window } }
    }
    /// Invisible stand-in for the status item that the popover anchors to.
    /// See `anchorView(under:)`.
    private var anchorWindow: NSWindow?
    /// The app the popover opened over while Settings was open behind it, to
    /// hand focus back to when the popover is dismissed; see `closePopover`.
    private var appUnderPopover: NSRunningApplication?
    /// Set while the app activates for the popover, so `appDidBecomeActive`
    /// can tell that apart from ⌘-Tab or the Dock.
    private var activatingForPopover = false
    /// Set while `closePopover` closes it, so `popoverShouldClose` can tell
    /// that apart from Esc.
    private var closingPopover = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpPopover()
        // Installs predating SMAppService still have a LaunchAgent plist; it
        // has to go before the first-launch check, or both would start a copy.
        LoginItem.migrateLegacyAgentIfNeeded()
        enableLoginItemOnFirstLaunch()
        model.start()
        askController = AskController(filter: model.filter, firewall: model.firewall)
        showUpdatesGently()
        observeTitle()
        offerHelperUpdateIfNeeded()
        showWelcomeIfNeeded()
        openWindowFromLaunchArgument()
    }

    /// Once, on first launch, or the first after updating to a version that
    /// has it, unless everything it offers is already on. Waits for the filter
    /// to say whether it was left on.
    private func showWelcomeIfNeeded() {
        welcomeCheck = model.filter.$hasResolved.first { $0 }.sink { [weak self] _ in
            guard let self else { return }
            let defaults = UserDefaults.standard
            let shown = defaults.bool(forKey: Welcome.shownKey)
            defaults.set(true, forKey: Welcome.shownKey)
            guard Welcome.shouldShow(shown: shown, filter: self.model.filter.state,
                                     wifi: self.model.wifiNames.access) else { return }
            self.showWelcome()
        }
    }

    private func showWelcome() {
        if popover.isShown { closePopover() }
        let controller = welcomeController ?? WelcomeWindowController(filter: model.filter,
                                                                       wifiNames: model.wifiNames)
        controller.window.delegate = self
        welcomeController = controller
        present(controller.window, reposition: !controller.window.isVisible)
    }

    /// `open NetworkMonitor.app --args -open connections`, `-open welcome`, or
    /// `-open settings` with `-pane history` (any pane), for a screenshot or a
    /// check of a development build without clicking the menu bar. Only the
    /// launch arguments are read, so it never outlives the run.
    private func openWindowFromLaunchArgument() {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        switch arguments["open"] as? String {
        case "connections": showConnections()
        case "welcome":     showWelcome()
        case "settings":    show(pane: (arguments["pane"] as? String).flatMap(SettingsPane.init))
        default:            break
        }
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
            onSettings: { [weak self] in self?.showSettings() },
            onHistory: { [weak self] in self?.showHistory() },
            onConnections: { [weak self] in self?.showConnections() })
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
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
            closePopover(returningFocus: true)
            return
        }
        guard let button = statusItem.button else { return }
        model.setPopoverOpen(true)
        if !NSApp.isActive, !openWindows.isEmpty {
            appUnderPopover = NSWorkspace.shared.frontmostApplication
        }
        if let anchor = anchorView(under: button) {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        // An LSUIElement app is not active by default, so without this the
        // popover renders unfocused and swallows the first click.
        activateForPopover()
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

    /// Activates the app for the popover, leaving its windows where they were.
    private func activateForPopover() {
        if !NSApp.isActive { activatingForPopover = true }
        keepingWindowsInPlace { NSApp.activate(ignoringOtherApps: true) }
    }

    /// Runs `change` without letting it bring Settings or Connections forward
    /// from behind another app's window (#71).
    ///
    /// Activating the app brings its main window forward, and Settings is made
    /// main for it whatever it says: AppKit ignored `canBecomeMain` returning
    /// false. The popover closing while the app is active makes Settings key,
    /// which brings it forward too. Off screen for that moment, a window is left
    /// alone, and it goes straight back below the window that was in front of
    /// it. Measured on macOS 27: Settings stayed behind Chrome, where without
    /// this it came forward over it when the popover opened.
    private func keepingWindowsInPlace(_ change: () -> Void) {
        let placed = openWindows.compactMap { window -> (window: NSWindow, inFront: Int)? in
            WindowStack.window(inFrontOf: window.windowNumber).map { (window, $0) }
        }
        guard !placed.isEmpty else {
            change()
            return
        }
        placed.forEach { $0.window.orderOut(nil) }
        change()
        // A window that was behind the other of ours goes back after it, so
        // there's something to go below.
        let ours = Set(placed.map { $0.window.windowNumber })
        for (window, inFront) in placed.filter({ !ours.contains($0.inFront) })
            + placed.filter({ ours.contains($0.inFront) }) {
            window.order(.below, relativeTo: inFront)
        }
    }

    /// `returningFocus` is for the popover being dismissed: Esc, or the status
    /// item clicked again. If it opened over another app with Settings open
    /// behind, focus goes back to that app. Left here, it would make Settings
    /// key from behind that app's window, and the keyboard would go to a
    /// window nobody can see.
    private func closePopover(returningFocus: Bool = false) {
        let returnTo = returningFocus && NSApp.isActive ? appUnderPopover : nil
        appUnderPopover = nil
        closingPopover = true
        if NSApp.isActive {
            keepingWindowsInPlace { popover.performClose(nil) }
        } else {
            popover.performClose(nil)
        }
        closingPopover = false
        returnTo?.activate(options: [])
    }

    /// Esc, which closes the popover without going through `closePopover`. It
    /// is sent back through it, a turn later rather than from inside AppKit's
    /// own close.
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        guard !closingPopover else { return true }
        DispatchQueue.main.async { [weak self] in self?.closePopover(returningFocus: true) }
        return false
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
                self.activateForPopover()
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

    /// Back to the app by ⌘-Tab, the Dock or a click on Settings while it's
    /// open: Settings alone (#71).
    ///
    /// The popover can still be up. ⌘-Tab away with the pointer in the menu
    /// bar reads as the menu bar appearing, so the popover rides it out, and
    /// coming back showed it over Settings. Settings is also made key here,
    /// since keeping it in place when the popover opened left it neither key
    /// nor main.
    @objc private func appDidBecomeActive() {
        guard !activatingForPopover else {
            activatingForPopover = false
            return
        }
        // Uninstall's alert activates the app too, and keeps the keyboard.
        guard let window = openWindows.first, NSApp.modalWindow == nil else { return }
        if popover.isShown { closePopover() }
        window.makeKeyAndOrderFront(nil)
    }

    /// The Dock icon, which is there only while a window is open. It can be
    /// clicked with the app already active, behind the popover, and then
    /// nothing else brings the window forward.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let frontmost = openWindows.first else { return true }
        if frontmost === connectionsController?.window { showConnections() } else { showSettings() }
        return false
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
        if popover.isShown { closePopover(returningFocus: true) }

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

        // A way out (#198): every app's new connections stop until it's
        // turned off again. Only where the content filter can enforce it.
        if model.filter.state != .unavailable {
            let item = menu.addItem(withTitle: "Block Everything",
                                    action: #selector(toggleBlockEverything), keyEquivalent: "")
            item.state = model.firewall.blocksEverything ? .on : .off
            item.toolTip = "Stops every app's new connections, apart from what's needed to turn this off"
            menu.addItem(.separator())
        }

        menu.addItem(withTitle: "Connections…",
                     action: #selector(showConnections), keyEquivalent: "k")
        menu.addItem(withTitle: "Usage History…",
                     action: #selector(showHistory), keyEquivalent: "y")
        menu.addItem(withTitle: "Settings…",
                     action: #selector(showSettings), keyEquivalent: ",")
        if model.updates.isAvailable {
            menu.addItem(withTitle: "Check for Updates…",
                         action: #selector(checkForUpdates), keyEquivalent: "")
        }

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
    /// While Sparkle shows an update (#132), a regular app with a Dock icon, so
    /// its window can't be lost behind another app's; badged when it found the
    /// update on its own; back in the menu bar once it's done, unless one of
    /// NetworkMonitor's own windows is still open.
    private func showUpdatesGently() {
        model.updates.onWillShowUpdate = { [weak self] userInitiated in
            guard let self else { return }
            NSApp.mainMenu = self.mainMenu
            NSApp.setActivationPolicy(.regular)
            if !userInitiated { NSApp.dockTile.badgeLabel = "1" }
        }
        model.updates.onUpdateAttended = { NSApp.dockTile.badgeLabel = nil }
        model.updates.onUpdateSessionEnded = { [weak self] in
            NSApp.dockTile.badgeLabel = nil
            guard let self, self.openWindows.isEmpty else { return }
            NSApp.setActivationPolicy(.accessory)
            NSApp.mainMenu = nil
        }
    }

    /// Sparkle's own window (#132), which says what's new and asks.
    @objc private func checkForUpdates() {
        if popover.isShown { closePopover() }
        NSApp.activate(ignoringOtherApps: true)
        model.updates.checkForUpdates()
    }

    @objc private func toggleBlockEverything() {
        model.setBlocksEverything(!model.firewall.blocksEverything)
    }

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

        // The content filter goes first: its extension is removed by the app
        // that installed it, which is about to be in the Trash.
        model.filter.remove { [weak self] in self?.finishUninstall() }
    }

    private func finishUninstall() {
        switch model.uninstall() {
        case .done:
            NSApp.terminate(nil)
        case .cancelled, .waitingForApproval:
            // Nothing has changed: the helper step comes first for this reason.
            // (Uninstalling never registers anything, so never waits.)
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

    /// Settings, on the pane last viewed — the HIG's "restore the most
    /// recently viewed pane".
    @objc private func showSettings() {
        show(pane: nil)
    }

    /// Settings, on History: from the popover's chart button, Usage History… in
    /// the right-click menu, and ⌘Y while a window is open.
    @objc private func showHistory() {
        show(pane: .history)
    }

    /// The Connections window: from the popover's globe, Connections… in the
    /// right-click menu, and ⌘K while a window is open.
    @objc private func showConnections() {
        if popover.isShown { closePopover() }
        let wasVisible = connections.isVisible
        present(connections.window, reposition: !wasVisible)
        guard !wasVisible else { return }
        connections.windowDidShow()
        // Nothing focused, as Settings opens: see `show(pane:)`.
        DispatchQueue.main.async { [weak self] in self?.connections.window.makeFirstResponder(nil) }
    }

    private func show(pane: SettingsPane?) {
        if popover.isShown { closePopover() }
        let wasVisible = settings.isVisible
        settings.select(pane)
        // Sized to the pane before it is placed, so it is centred at its real size.
        settings.fitSelectedPane()
        // Not re-centred if it is already up: it may have been moved, and the
        // request is only to bring it forward or change pane.
        present(settings.window, reposition: !wasVisible)
        settings.windowDidShow()
        // Opens with nothing focused, for the reason the popover does: the window
        // would otherwise hand first responder to its first control, which then
        // wears a focus ring nobody asked for. Tab still reaches it. Deferred,
        // since SwiftUI assigns focus after the window is shown.
        if !wasVisible {
            DispatchQueue.main.async { [weak self] in self?.settings.window.makeFirstResponder(nil) }
        }
    }

    /// Brings one of the app's windows forward.
    ///
    /// An ordinary app for as long as one is open — in the Dock and the app
    /// switcher, with a menu bar of its own — and an accessory app again once
    /// the last one closes; see `windowWillClose`.
    ///
    /// As an accessory app it had none of those, and with an auto-hidden menu
    /// bar that lost the window outright. Revealing the bar activates an app
    /// that owns one, and that app's windows came forward over Settings, with
    /// no Dock icon or ⌘-Tab entry left to bring it back. Measured on macOS 27
    /// with a stand-in window: covered by the terminal on the first reveal as
    /// an accessory app, frontmost and key through the same reveal as a
    /// regular one.
    private func present(_ window: NSWindow, reposition: Bool = true) {
        NSApp.mainMenu = mainMenu
        NSApp.setActivationPolicy(.regular)

        // Re-position on every open: the window may have been moved, or opened on
        // a different screen since last time.
        if reposition { position(window) }

        // An LSUIElement app is not active by default, so without this the
        // window opens behind whatever the user was using.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Back to a menu bar app when the last window closes. macOS hands focus
    /// back to whichever app had it before, unprompted — measured, also on
    /// macOS 27.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if closing === settingsController?.window { settingsController?.windowWillClose() }
        if closing === connectionsController?.window { connectionsController?.windowWillClose() }
        // Still a regular app while another window is open.
        let stillOpen = ourWindows.contains { $0 !== closing && $0.isVisible }
        guard !stillOpen else { return }
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = nil
    }

    /// The menu bar NetworkMonitor shows while one of its windows is open, and
    /// only then.
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
        if model.updates.isAvailable {
            appMenu.addItem(withTitle: "Check for Updates…",
                            action: #selector(checkForUpdates), keyEquivalent: "").target = self
        }
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
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Connections",
                           action: #selector(showConnections), keyEquivalent: "k").target = self
        windowMenu.addItem(withTitle: "Usage History",
                           action: #selector(showHistory), keyEquivalent: "y").target = self

        let menuBar = NSMenu()
        for submenu in [appMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            menuBar.addItem(item)
        }
        return menuBar
    }()

    /// Centres a window, keeping its title bar clear of the menu bar.
    ///
    /// With "Automatically hide and show the menu bar" enabled, the menu bar draws
    /// *over* whatever is beneath it rather than shrinking the usable area, so a
    /// window whose title bar sits in the top 30 pt has its close button covered
    /// whenever the menu bar appears. The top edge is therefore clamped to exactly
    /// one menu bar height below the top of the screen.
    private func position(_ window: NSWindow) {
        // Sizing is the settings controller's job (`fitSelectedPane`), done before
        // this runs, so the frame centred here is already the pane's.
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
