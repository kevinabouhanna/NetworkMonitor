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

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpPopover()
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
        popover.contentViewController = NSHostingController(rootView: root)
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
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // An LSUIElement app is not active by default, so without this the
        // popover renders unfocused and swallows the first click.
        NSApp.activate(ignoringOtherApps: true)

        // `.transient` dismisses on outside clicks but does not tell us, and the
        // model needs to know in order to stop rebuilding rows.
        popoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            DispatchQueue.main.async { self.closePopover() }
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        model.setPopoverOpen(false)
        if let monitor = popoverMonitor {
            NSEvent.removeMonitor(monitor)
            popoverMonitor = nil
        }
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
                rootView: SettingsView(model: model,
                                       onQuit: { NSApp.terminate(nil) }))
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
