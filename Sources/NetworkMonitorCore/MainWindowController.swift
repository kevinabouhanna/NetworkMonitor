import AppKit
import Combine
import SwiftUI

/// The main window's sections (#436), in the popover's order: Usage History
/// (Today), Connections (Companies), Ads and Trackers (Ads blocked) and
/// Network, which holds the connection, the hotspot switch and the speed test.
public enum MainSection: String, CaseIterable, Identifiable {
    case history, connections, ads, network

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .history:     return L("Usage History")
        case .connections: return L("Connections")
        case .ads:         return L("Ads and Trackers")
        case .network:     return L("Network")
        }
    }

    public var symbol: String {
        switch self {
        case .history:     return "chart.bar.xaxis"
        case .connections: return "globe"
        case .ads:         return "shield.lefthalf.filled"
        case .network:     return "wifi"
        }
    }

}

/// Which section is shown, and whether its settings are, for the sidebar.
final class MainNavigation: ObservableObject {
    @Published var section: MainSection = .history
    @Published var showsSettings = false
}

/// The main window (#436): one window with a sidebar, in place of the
/// Connections, Ads and Trackers and Usage History windows, so you can go
/// through them one by one. Each section brings its own toolbar. Its gear
/// shows that section's settings in place, with a back button, as System
/// Settings goes deeper, rather than a second window on top; the Settings
/// window stays for ⌘, and the popover's gear, with the same panes.
public final class MainWindowController: NSObject, NSToolbarDelegate {

    /// The sidebar's button and the line that keeps the toolbar's items over
    /// the content, first in every section's toolbar.
    public static let sidebarItems: [NSToolbarItem.Identifier] = [.toggleSidebar, .sidebarTrackingSeparator]
    private static let backItem = NSToolbarItem.Identifier("back")

    public let window: NSWindow
    let navigation = MainNavigation()
    public let history: HistoryWindowController
    public let connections: ConnectionsWindowController
    public let ads: AdsWindowController
    private let network: NSViewController
    private let networkToolbar = NSToolbar(identifier: "Main.network")
    private let settingsToolbar = NSToolbar(identifier: "Main.settings")
    private let container = MainContainerController()
    private let split = NSSplitViewController()
    private var settingsPages: [MainSection: NSViewController] = [:]
    private let makeSettingsPage: (MainSection) -> NSViewController
    private let historyModel: HistoryViewModel
    private let adsModel: AdsViewModel
    private let glance: TodayGlance
    private var openSection: MainSection?
    private var languageObservation: AnyCancellable?

    public init(model: MonitorViewModel, history historyModel: HistoryViewModel,
                connections connectionsModel: ConnectionsViewModel, ads adsModel: AdsViewModel) {
        self.historyModel = historyModel
        self.adsModel = adsModel
        glance = model.glance
        history = HistoryWindowController(model: historyModel, standalone: false)
        connections = ConnectionsWindowController(model: connectionsModel, standalone: false)
        ads = AdsWindowController(model: adsModel, standalone: false)
        let networkHost = NSHostingController(rootView: NetworkView(model: model, metering: model.metering,
                                                                    speedTest: model.speedTest).localizedRoot())
        networkHost.sizingOptions = []
        network = networkHost
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        let state = SettingsPaneState()
        // Each section's settings, as the Settings window has them.
        var back: () -> Void = {}
        makeSettingsPage = { section in
            let width = SettingsMetrics.paneWidth
            let view: AnyView
            switch section {
            case .history:
                view = AnyView(HistorySettingsPane(model: historyModel, onOpen: { back() }))
            case .connections:
                view = AnyView(ConnectionsSettingsPane(model: connectionsModel, filter: model.filter,
                                                       firewall: model.firewall, geoData: model.geoData,
                                                       lookups: model.lookups, glance: model.glance,
                                                       onOpen: { back() }))
            case .ads:
                view = AnyView(AdsSettingsPane(ads: adsModel, connections: connectionsModel, filter: model.filter,
                                               firewall: model.firewall, blocklists: model.blocklists,
                                               listBlocks: model.listBlocks, onOpenAds: { back() }))
            case .network:
                view = AnyView(VStack(spacing: 0) {
                    HotspotSettingsPane(metering: model.metering, state: state, filter: model.filter)
                    SpeedTestStylePane(speedTest: model.speedTest)
                })
            }
            let host = NSHostingController(rootView: MainSettingsPage(content: view, width: width).localizedRoot())
            host.sizingOptions = []
            return host
        }
        super.init()
        back = { [weak self] in self?.closeSettings() }

        let sidebar = NSHostingController(rootView: MainSidebar(navigation: navigation,
                                                                onSelect: { [weak self] in self?.show($0) })
            .localizedRoot())
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = MainMetrics.sidebarWidth
        sidebarItem.maximumThickness = 260
        sidebarItem.canCollapse = true
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: container))
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1300, height: 800))
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.setFrameAutosaveName("Main")

        for toolbar in [networkToolbar, settingsToolbar] {
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
        }
        history.onSettings = { [weak self] in self?.showSettings() }
        connections.onSettings = { [weak self] in self?.showSettings() }
        ads.onSettings = { [weak self] in self?.showSettings() }

        languageObservation = NotificationCenter.default
            .publisher(for: Localization.didChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.nameWindow() }
        place(navigation.section)
    }

    public var isVisible: Bool { window.isVisible }

    // MARK: Showing

    /// Brings a section forward, out of its settings if they were showing.
    public func show(_ section: MainSection) {
        navigation.showsSettings = false
        place(section)
        if window.isVisible { open(section) }
    }

    /// The window was shown: the section on screen starts reading.
    public func windowDidShow() { open(navigation.section) }

    /// The window is closing: the section on screen stops.
    public func windowWillClose() {
        close(openSection)
        openSection = nil
    }

    /// The section's settings, in place of its content, with a back button.
    public func showSettings() {
        let section = navigation.section
        if settingsPages[section] == nil { settingsPages[section] = makeSettingsPage(section) }
        guard let page = settingsPages[section] else { return }
        navigation.showsSettings = true
        container.show(page)
        window.toolbar = settingsToolbar
        nameWindow()
        refreshSettings(for: section)
    }

    /// A section's settings page, built if it isn't yet: for the
    /// accessibility tests, which read each page in a window of its own (the
    /// split view can't be read from the app's own process).
    public func settingsPage(for section: MainSection) -> NSViewController {
        if settingsPages[section] == nil { settingsPages[section] = makeSettingsPage(section) }
        return settingsPages[section]!
    }

    /// The sidebar and Network's view, for the same tests.
    public var sidebarController: NSViewController { split.splitViewItems[0].viewController }
    public var networkController: NSViewController { network }

    /// Back from the settings to the section.
    public func closeSettings() {
        navigation.showsSettings = false
        place(navigation.section)
    }

    /// Opens straight on a section's settings: from Settings… in a menu, say.
    public func showSettings(for section: MainSection) {
        show(section)
        showSettings()
    }

    private func place(_ section: MainSection) {
        navigation.section = section
        switch section {
        case .history:
            container.show(history.content)
            window.toolbar = history.toolbar
        case .connections:
            container.show(connections.content)
            window.toolbar = connections.toolbar
        case .ads:
            container.show(ads.content)
            window.toolbar = ads.toolbar
        case .network:
            container.show(network)
            window.toolbar = networkToolbar
        }
        window.contentMinSize = NSSize(width: MainMetrics.minWidth(section), height: MainMetrics.minHeight)
        if window.frame.width < window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: MainMetrics.minWidth(section),
                                                                        height: 100)).width {
            var frame = window.frame
            frame.size.width = window.frameRect(forContentRect: NSRect(x: 0, y: 0,
                                                                       width: MainMetrics.minWidth(section),
                                                                       height: 100)).width
            window.setFrame(frame, display: true)
        }
        nameWindow()
    }

    /// One section reads at a time, while it's shown.
    private func open(_ section: MainSection) {
        guard openSection != section else { return }
        close(openSection)
        openSection = section
        switch section {
        case .history:     history.windowDidShow()
        case .connections: connections.windowDidShow()
        case .ads:         ads.windowDidShow()
        case .network:     break
        }
    }

    private func close(_ section: MainSection?) {
        switch section {
        case .history:     history.windowWillClose()
        case .connections: connections.windowWillClose()
        case .ads:         ads.windowWillClose()
        case .network, .none: break
        }
    }

    private func refreshSettings(for section: MainSection) {
        switch section {
        case .history:     historyModel.refreshToday()
        case .ads:         adsModel.reloadToday(); glance.refresh()
        case .connections: glance.refresh()
        case .network:     break
        }
    }

    private func nameWindow() {
        let section = navigation.section
        window.title = navigation.showsSettings ? L("%@ Settings", section.title) : section.title
        for item in settingsToolbar.items where item.itemIdentifier == Self.backItem {
            item.label = section.title
            item.toolTip = L("Back to %@", section.title)
        }
    }

    @objc private func goBack() { closeSettings() }
    @objc private func openSettings() { showSettings() }

    // MARK: NSToolbarDelegate (Network and the settings pages)

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        if toolbar === settingsToolbar { return Self.sidebarItems + [Self.backItem, .flexibleSpace] }
        return Self.sidebarItems + [.flexibleSpace, SettingsGear.identifier]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                        willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case Self.backItem:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: L("Back"))
            item.label = navigation.section.title
            item.toolTip = L("Back to %@", navigation.section.title)
            item.isBordered = true
            item.target = self
            item.action = #selector(goBack)
            // Before the title, where a Mac window's back button goes.
            if #available(macOS 14, *) { item.isNavigational = true }
            return item
        case SettingsGear.identifier:
            return SettingsGear.item(target: self, action: #selector(openSettings),
                                     help: L("Settings for the network and hotspots"))
        default:
            return nil
        }
    }
}

/// The content area: shows one section's view, or its settings.
final class MainContainerController: NSViewController {
    private var current: NSViewController?

    override func loadView() { view = NSView() }

    func show(_ controller: NSViewController) {
        guard controller !== current else { return }
        current?.view.removeFromSuperview()
        current?.removeFromParent()
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        current = controller
    }
}

/// The sidebar: the four sections, as the popover's four buttons.
struct MainSidebar: View {
    @ObservedObject var navigation: MainNavigation
    let onSelect: (MainSection) -> Void

    var body: some View {
        List(selection: Binding<MainSection?>(get: { navigation.section },
                                              set: { if let section = $0 { onSelect(section) } })) {
            ForEach(MainSection.allCases) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
        }
        .listStyle(.sidebar)
    }
}

/// A section's settings in the main window: the Settings pane itself,
/// centred at the width it has in Settings, scrolling when it's taller.
struct MainSettingsPage: View {
    let content: AnyView
    let width: CGFloat

    var body: some View {
        ScrollView(.vertical) {
            content
                .frame(maxWidth: width)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
    }
}

enum MainMetrics {
    static let sidebarWidth: CGFloat = 190
    static let minHeight: CGFloat = 560
    /// The narrowest the window can be on a section: the sidebar and what the
    /// section's toolbar needs (#315), measured with `make design-shots`
    /// and `--measure`.
    static func minWidth(_ section: MainSection) -> CGFloat {
        switch section {
        case .connections: return sidebarWidth + ConnectionsMetrics.minWidth
        case .ads:         return sidebarWidth + AdsMetrics.minWidth
        case .history:     return sidebarWidth + HistoryMetrics.windowMinWidth
        case .network:     return sidebarWidth + 560
        }
    }
}

// MARK: - Network

/// Network (#436): the connection the Mac is on, a switch to say it's a
/// hotspot (detection can miss a phone), what's paused on hotspots, and the
/// speed test for this connection.
struct NetworkView: View {
    @ObservedObject var model: MonitorViewModel
    @ObservedObject var metering: MeteringController
    @ObservedObject var speedTest: SpeedTestController

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                header
                Form {
                    Section {
                        if model.connection.kind != .offline {
                            ExplainedRow(L("This is a hotspot"), hotspotExplanation) {
                                Toggle(L("This is a hotspot"),
                                       isOn: Binding(get: { metering.verdict.isMetered }, set: metering.setHotspot))
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                            }
                        }
                        // The verdict, always shown: the commonest confusion is not
                        // knowing whether it decided the connection counts.
                        if let standby = metering.standbyHotspot {
                            // A hotspot's connected, so "doesn't look like one"
                            // would read as the app having missed it (#355).
                            ExplainedRow(L("Right now"), standby.explanation(inUse: metering.connection)) {
                                Label(standby.rightNow(inUse: metering.connection),
                                      systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        } else {
                            LabeledContent(L("Right now")) {
                                Label(metering.verdict.explanation,
                                      systemImage: metering.verdict.isMetered
                                          ? "antenna.radiowaves.left.and.right" : "wifi")
                                    .foregroundStyle(metering.verdict.isMetered
                                                     ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                            }
                        }
                    } header: {
                        Text(L("This network"))
                    } footer: {
                        SettingsFootnote(hotspotFootnote)
                    }
                    if SpeedTestRunner.isAvailable {
                        Section {
                            SpeedTestPanel(speedTest: speedTest)
                        } header: {
                            Text(L("Speed test"))
                        } footer: {
                            SettingsFootnote(L("Runs macOS's built-in networkQuality, only when you start it: download first, then upload. Every run measures afresh, so it uses data each time — typically 50–500 MB, more on a very fast line. Speeds use the unit chosen in General."))
                        }
                    }
                }
                .settingsForm()
            }
            .padding(.vertical, 20)
            .frame(maxWidth: SettingsMetrics.paneWidth)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(metering.verdict.isMetered ? Color.white : Color.primary)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 11)
                    .fill(metering.verdict.isMetered ? PopoverPalette.hotspot : Color.primary.opacity(0.08)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.connection.name ?? model.connection.medium ?? L("No connection"))
                    .font(.system(size: 20, weight: .semibold))
                Text(L("%@ · %@ today", PopoverConnection.word(model.connection, metering: metering),
                       ByteFormat.bytes(model.totalBytes)))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 20)
    }

    private var symbol: String {
        if metering.verdict.isMetered { return "personalhotspot" }
        switch model.connection.kind {
        case .ethernet: return "cable.connector"
        case .offline:  return "wifi.slash"
        default:        return "wifi"
        }
    }

    private var hotspotExplanation: String {
        L("Pauses app updates and iCloud downloads while you're on this network. NetworkMonitor recognises an iPhone's hotspot by itself, but some phones look like ordinary Wi-Fi, or like Ethernet over USB: switch this on for those. It's remembered for this network.")
    }

    private var hotspotFootnote: String {
        var parts: [String] = []
        if metering.override != nil { parts.append(L("Marked by you for this network.")) }
        if !metering.isEnabled { parts.append(L("Stopping app updates on hotspots is off: switch it on with the gear.")) }
        else if metering.isSuppressing { parts.append(L("App updates are paused until you leave this network.")) }
        return parts.isEmpty ? L("App updates pause on any network marked as a hotspot.") : parts.joined(separator: " ")
    }
}

extension MeteringController {
    /// The hotspot switch, in the popover and in Network (#436). On: a hotspot,
    /// by your say. Off: back to detecting it, unless detection takes it for
    /// one, which needs your say that it isn't.
    public func setHotspot(_ on: Bool) {
        if on {
            setOverride(true)
        } else if override == true, !detectsHotspot {
            setOverride(nil)
        } else {
            setOverride(false)
        }
    }
}
