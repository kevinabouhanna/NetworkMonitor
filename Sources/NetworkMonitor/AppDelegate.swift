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

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpPopover()
        model.start()
        observeTitle()
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
        applyTitle()
    }

    /// Title construction lives in `MenuBarTitle` so its width-stability
    /// invariant is covered by the test suite.
    private func applyTitle() {
        statusItem.button?.attributedTitle = model.menuBarTitle
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
            onRename: { [weak self] in self?.renameNetwork() },
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

        let header = NSMenuItem(title: model.networkLabel, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Reset \(model.networkLabel)",
                     action: #selector(resetCurrent), keyEquivalent: "")
        menu.addItem(withTitle: "Reset All Networks",
                     action: #selector(resetAll), keyEquivalent: "")
        menu.addItem(withTitle: "Rename This Network…",
                     action: #selector(renameNetwork), keyEquivalent: "")

        menu.addItem(.separator())
        let networks = NSMenuItem(title: "Networks", action: nil, keyEquivalent: "")
        networks.submenu = networksSubmenu()
        menu.addItem(networks)

        menu.addItem(.separator())
        let tracking = NSMenuItem(title: "Track Per-App Usage", action: nil, keyEquivalent: "")
        tracking.submenu = trackingSubmenu()
        menu.addItem(tracking)

        menu.addItem(.separator())
        let launch = NSMenuItem(title: "Launch at Login",
                                action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.state = isLaunchAtLoginEnabled ? .on : .off
        menu.addItem(launch)

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

    private func networksSubmenu() -> NSMenu {
        let submenu = NSMenu()
        let networks = model.store.allNetworks()
        if networks.isEmpty {
            let item = NSMenuItem(title: "None yet", action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
            return submenu
        }
        for network in networks {
            let total = ByteFormat.bytes(network.bucket.interfaceTotal)
            let item = NSMenuItem(title: "\(network.label) — \(total)",
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            if network.id == model.store.currentNetwork.id { item.state = .on }
            submenu.addItem(item)
        }
        return submenu
    }

    // MARK: Actions

    @objc private func resetCurrent() { model.resetCurrentNetwork() }

    @objc private func resetAll() {
        model.store.resetAllNetworks()
        model.refreshHeader()
    }

    @objc private func renameNetwork() {
        let alert = NSAlert()
        alert.messageText = "Rename Network"
        alert.informativeText = "This name is remembered for this network only."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = model.networkLabel
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            model.renameCurrentNetwork(field.stringValue)
        }
    }

    // MARK: Launch at login

    /// Backed by a per-user LaunchAgent, which needs no code signature and no
    /// Developer ID. See `LoginItem`.
    private var isLaunchAtLoginEnabled: Bool { LoginItem.isEnabled }

    @objc private func toggleLaunchAtLogin() {
        do {
            if isLaunchAtLoginEnabled {
                try LoginItem.disable()
            } else {
                try LoginItem.enable()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Could not change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}
