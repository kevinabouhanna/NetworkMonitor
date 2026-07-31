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
            onReset: { [weak self] in self?.model.resetCurrentNetwork() },
            onSettings: { [weak self] in self?.showSettings() },
            onQuit: { NSApp.terminate(nil) })
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

        menu.addItem(withTitle: "Reset Today's Usage",
                     action: #selector(resetCurrent), keyEquivalent: "")
        menu.addItem(withTitle: "Reset All Networks",
                     action: #selector(resetAll), keyEquivalent: "")

        menu.addItem(.separator())
        let tracking = NSMenuItem(title: "Track Per-App Usage", action: nil, keyEquivalent: "")
        tracking.submenu = trackingSubmenu()
        menu.addItem(tracking)

        menu.addItem(withTitle: "Settings…",
                     action: #selector(showSettings), keyEquivalent: ",")

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit NetworkMonitor",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        for item in menu.items where item.action != nil { item.target = self }
        // Quit stays wired to NSApp rather than to us.
        menu.items.last?.target = NSApp

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Detach immediately so the next left-click opens the popover, not the menu.
        statusItem.menu = nil
    }

    /// `nettop` costs a fixed ~1.36 cores whenever it runs, so this is exposed
    /// rather than hidden: it is a real battery-versus-completeness tradeoff.
    /// The live speed and day total never depend on it.
    private func trackingSubmenu() -> NSMenu {
        let submenu = NSMenu()
        for mode in PerAppTrackingMode.allCases {
            let item = NSMenuItem(title: mode.title,
                                  action: #selector(selectTrackingMode(_:)),
                                  keyEquivalent: "")
            item.representedObject = mode.rawValue
            item.state = (mode == model.trackingMode) ? .on : .off
            item.target = self
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let status = NSMenuItem(
            title: model.isTrackingPerApp ? "Currently tracking" : "Currently paused",
            action: nil, keyEquivalent: "")
        status.isEnabled = false
        submenu.addItem(status)
        return submenu
    }

    @objc private func selectTrackingMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = PerAppTrackingMode(rawValue: raw) else { return }
        model.setTrackingMode(mode)
    }

    // MARK: Actions

    @objc private func resetCurrent() { model.resetCurrentNetwork() }

    @objc private func resetAll() {
        model.store.resetAllNetworks()
        model.refreshHeader()
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
            window.center()
            settingsWindow = window
        }

        // An LSUIElement app is not active by default, so without this the
        // window opens behind whatever the user was using.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
