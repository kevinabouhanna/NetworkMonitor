import AppKit
import ScreenCaptureKit
import FirewallPolicy
import NetworkMonitorCore
import ServerDirectory
import SwiftUI

// Pictures of every window the design work compares (#437), drawn from a
// made-up dataset rather than anyone's real connections, sites or rules.
//
// Each window is built in this process, as `AccessibilityTests` builds them,
// with its own history database, its own settings and a content filter that
// says it's on without asking macOS. Nothing is read from or written to the
// installed app's data, and the screen isn't used: windows are drawn out of
// sight and saved at 2x.
//
//   make design-shots OUT=docs/design-overhaul/before
//
// Arguments: `--out <dir>` (required), `--only <name,...>`, `--owners <ip,...>`
// to print who owns addresses (for choosing the dataset's).

let arguments = CommandLine.arguments
func argument(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
NSApp.finishLaunching()
guard CGPreflightScreenCaptureAccess() else {
    FileHandle.standardError.write("needs Screen Recording for the terminal it runs in\n".data(using: .utf8)!)
    exit(1)
}

if let owners = argument("--owners") {
    let directory = ServerDirectory.bundled() ?? (try? ServerDirectory(directory: GeoDataUpdater.downloadedDirectory))
    for address in owners.split(separator: ",").map(String.init) {
        let info = directory?.lookup(address)
        print(address, info?.country ?? "-", info?.owner?.company.name ?? "-", "|", info?.owner?.registeredName ?? "-")
    }
    exit(0)
}

guard let outPath = argument("--out") else {
    FileHandle.standardError.write("usage: DesignShots --out <dir> [--only name,...]\n".data(using: .utf8)!)
    exit(2)
}
let out = URL(fileURLWithPath: outPath)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let only = argument("--only").map { Set($0.split(separator: ",").map(String.init)) }

// MARK: The dataset

/// Settings of its own: this bundle's domain, never the app's.
guard Bundle.main.bundleIdentifier == "com.networkmonitor.designshots" else {
    FileHandle.standardError.write("run it from build/DesignShots.app (make design-shots)\n".data(using: .utf8)!)
    exit(2)
}
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("design-shots-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }

func app(_ name: String, _ path: String) -> AppIdentity {
    AppIdentity(key: path, displayName: name, bundlePath: FileManager.default.fileExists(atPath: path) ? path : nil,
                isSystem: false)
}

/// Who each app talks to: an address, the name it used, and a share of its bytes.
struct Server { let address: String; let name: String; let share: Double }
struct Talker { let app: AppIdentity; let megabytesPerHour: Double; let servers: [Server] }

let safari = app("Safari", "/Applications/Safari.app")
let chrome = app("Google Chrome", "/Applications/Google Chrome.app")
let slack = app("Slack", "/Applications/Slack.app")
let spotify = app("Spotify", "/Applications/Spotify.app")
let teams = app("Microsoft Teams", "/Applications/Microsoft Teams.app")
let mail = app("Mail", "/System/Applications/Mail.app")
/// A long name, to see how rows and headers hold it.
let longApp = app("Northwind Field Operations Companion", "/Applications/Northwind Field Operations Companion.app")

let talkers: [Talker] = [
    Talker(app: safari, megabytesPerHour: 46, servers: [
        Server(address: "17.253.144.10", name: "www.apple.com", share: 0.25),
        Server(address: "151.101.1.140", name: "www.theguardian.com", share: 0.3),
        Server(address: "104.16.132.229", name: "news.ycombinator.com", share: 0.15),
        Server(address: "142.250.181.238", name: "www.google.com", share: 0.2),
        Server(address: "157.240.22.35", name: "www.instagram.com", share: 0.1),
    ]),
    Talker(app: chrome, megabytesPerHour: 120, servers: [
        Server(address: "142.250.181.238", name: "www.youtube.com", share: 0.7),
        Server(address: "52.94.236.248", name: "www.amazon.com", share: 0.2),
        Server(address: "104.16.132.229", name: "github.com", share: 0.1),
    ]),
    Talker(app: slack, megabytesPerHour: 9, servers: [
        Server(address: "3.120.0.10", name: "app.slack.com", share: 1),
    ]),
    Talker(app: spotify, megabytesPerHour: 38, servers: [
        Server(address: "35.186.224.25", name: "audio-ak.spotifycdn.com", share: 0.8),
        Server(address: "23.32.0.1", name: "i.scdn.co", share: 0.2),
    ]),
    Talker(app: teams, megabytesPerHour: 22, servers: [
        Server(address: "52.112.0.1", name: "teams.microsoft.com", share: 1),
    ]),
    Talker(app: mail, megabytesPerHour: 3, servers: [
        Server(address: "17.42.251.41", name: "imap.mail.me.com", share: 1),
    ]),
    Talker(app: longApp, megabytesPerHour: 5, servers: [
        Server(address: "193.0.6.139", name: "sync.northwind-field-operations.example", share: 1),
    ]),
]

/// What the lists stopped, by app.
let listed: [(app: AppIdentity, name: String, list: String, perHour: Int)] = [
    (chrome, "pagead2.googlesyndication.com", "ads", 40),
    (chrome, "securepubads.g.doubleclick.net", "ads", 26),
    (safari, "connect.facebook.net", "ads", 12),
    (safari, "static.criteo.net", "ads", 9),
    (chrome, "bat.bing.com", "ads", 7),
    (spotify, "spclient.wg.spotify.com", "ads", 5),
    (safari, "analytics.tiktok.com", "ads", 4),
    (chrome, "login-verify-account.example", "malware", 1),
]

var calendar = Calendar.current
let now = Date()
let today = calendar.startOfDay(for: now)

/// The hour now reads as late afternoon, so today's chart has a working
/// day in it whenever this runs.
let shift = 17 - calendar.component(.hour, from: now)

/// Busier in the working day, quiet at night, the same every run.
func activity(_ hourOfDay: Int, _ day: Int) -> Double {
    let hour = ((hourOfDay + shift) % 24 + 24) % 24
    let curve: [Double] = [0.05, 0.03, 0.02, 0.02, 0.02, 0.04, 0.1, 0.3, 0.6, 0.9, 1, 0.95,
                           0.8, 0.9, 1, 0.95, 0.85, 0.7, 0.6, 0.65, 0.7, 0.55, 0.3, 0.1]
    let weekday = [1.0, 0.9, 1.1, 0.8, 1.0, 0.5, 0.4][(day % 7 + 7) % 7]
    return curve[hour] * weekday
}

enum Scenario { case full, empty }

/// What the lists stopped today, for the counter Settings shows.
var blockedToday = 0

func makeHistory(_ scenario: Scenario, at url: URL) -> UsageHistory {
    let history = UsageHistory(databaseURL: url, calendar: calendar)
    guard scenario == .full else { return history }
    let home = NetworkFingerprint(id: "design-home", kind: .wifi, gatewayMAC: "design-home",
                                  defaultLabel: "Home Wi-Fi", isExpensive: false, isConstrained: false)
    let phone = NetworkFingerprint(id: "design-phone", kind: .hotspot, gatewayMAC: "design-phone",
                                   defaultLabel: "iPhone", isExpensive: true, isConstrained: false)
    for day in (0..<14).reversed() {
        guard let start = calendar.date(byAdding: .day, value: -day, to: today) else { continue }
        // One afternoon a week on the phone's hotspot.
        let onHotspot = day % 7 == 3
        for hour in 0..<24 {
            guard let at = calendar.date(byAdding: .hour, value: hour, to: start)?.addingTimeInterval(600),
                  at < now else { continue }
            let network = onHotspot && (13...16).contains(hour) ? phone : home
            history.join(network, label: network.defaultLabel, switched: false, now: at)
            let level = activity(hour, day)
            var entries: [(identity: AppIdentity, bytesIn: Int64, bytesOut: Int64)] = []
            var servers: [String: [String: ByteCounts]] = [:]
            var sightings: [UsageHistory.NameSighting] = []
            for talker in talkers {
                let bytes = talker.megabytesPerHour * level * 1_000_000
                let down = Int64(bytes * 0.92), up = Int64(bytes * 0.08)
                guard down > 0 else { continue }
                entries.append((talker.app, down, up))
                for server in talker.servers {
                    servers[talker.app.key, default: [:]][server.address] =
                        ByteCounts(bytesIn: Int64(Double(down) * server.share), bytesOut: Int64(Double(up) * server.share))
                    sightings.append(UsageHistory.NameSighting(identity: talker.app, address: server.address,
                                                               name: server.name, blocked: false))
                }
            }
            let total = entries.reduce(Int64(0)) { $0 + $1.bytesIn + $1.bytesOut }
            history.recordInterface(bytesIn: Int64(Double(total) * 0.95), bytesOut: Int64(Double(total) * 0.08), now: at)
            history.recordApps(entries, servers: servers, now: at)
            history.recordServerNames(sightings, now: at)
            var blocks: [(identity: AppIdentity, name: String, list: String)] = []
            for item in listed {
                let count = Int((Double(item.perHour) * level).rounded())
                blocks += Array(repeating: (item.app, item.name, item.list), count: count)
            }
            history.recordListBlocks(blocks, now: at)
            if day == 0 { blockedToday += blocks.count }
            // Meta, blocked by a rule below.
            let metaTries = Int((6 * level).rounded())
            history.recordBlocked(Array(repeating: (safari, "157.240.22.36"), count: metaTries), now: at)
        }
    }
    history.flush(now: now)
    return history
}

// MARK: The windows

/// Windows drawn as the one in front: blue selection, coloured window
/// buttons. Out of sight, none of them is ever really key, and this process
/// never takes the focus from whatever is in front.
extension NSWindow {
    @objc var designShotsIsKey: Bool { true }
}
if let original = class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.isKeyWindow)),
   let replacement = class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.designShotsIsKey)) {
    method_exchangeImplementations(original, replacement)
}
if let original = class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.isMainWindow)),
   let replacement = class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.designShotsIsKey)) {
    method_setImplementation(original, method_getImplementation(replacement))
}
extension NSApplication {
    @objc var designShotsIsActive: Bool { true }
}
if let original = class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.isActive)),
   let replacement = class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.designShotsIsActive)) {
    method_setImplementation(original, method_getImplementation(replacement))
}

struct World {
    let model: MonitorViewModel
    let connections: ConnectionsViewModel
    let historyModel: HistoryViewModel
    let ads: AdsViewModel
}

func makeWorld(_ scenario: Scenario, filter: FilterController.State) -> World {
    // Each world starts from no settings at all.
    if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
    let dir = scratch.appendingPathComponent("\(scenario)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let defaults = UserDefaults.standard
    let history = makeHistory(scenario, at: dir.appendingPathComponent("history.sqlite"))
    let store = UsageStore(storeURL: dir.appendingPathComponent("usage.json"), calendar: calendar, history: history)
    let metering = MeteringController(store: store,
                                      journal: SuppressionJournal(url: dir.appendingPathComponent("journal.json")),
                                      suppressors: [], defaults: defaults)
    let model = MonitorViewModel(store: store, metering: metering)
    model.filter.showForPictures(filter)
    if scenario == .full {
        // Stopping updates on hotspots is on, as for most people who set it up.
        metering.isEnabled = true
        // Today's apps, for the popover's list.
        let elapsed = max(1, Double(calendar.component(.hour, from: now)))
        let entries = talkers.map { talker -> (identity: AppIdentity, bytesIn: Int64, bytesOut: Int64) in
            let bytes = talker.megabytesPerHour * 0.6 * elapsed * 1_000_000
            return (talker.app, Int64(bytes * 0.92), Int64(bytes * 0.08))
        }
        store.recordApps(entries, now: now)
        let total = entries.reduce(Int64(0)) { $0 + $1.bytesIn + $1.bytesOut }
        store.recordInterface(bytesIn: Int64(Double(total) * 0.92), bytesOut: Int64(Double(total) * 0.08), now: now)
    }
    let connections = ConnectionsViewModel(monitor: model, defaults: defaults)

    if scenario == .full, filter == .on {
        model.listBlocks.seed(blockedToday)
        connections.setLists(Set(BlocklistTopic.allCases))
        model.firewall.add(FirewallRule(subject: .company, key: "Meta", title: "Meta", action: .block))
        model.firewall.add(FirewallRule(subject: .app, key: spotify.key, title: "Spotify", action: .blockOnHotspots))
        model.firewall.add(FirewallRule(subject: .company, key: "Apple", title: "Apple", action: .allow))
        model.firewall.add(AdRule(kind: .neverBlock, site: "theguardian.com"))
        model.firewall.add(AdRule(kind: .alwaysBlock, site: "tracker.example"))
        var log: [(time: Date, appKey: String?, appName: String, bundlePath: String?, address: String,
                   port: Int, name: String?, blockedBy: String?, lists: [String])] = []
        for (index, item) in listed.enumerated() {
            log.append((now.addingTimeInterval(Double(-90 * (listed.count - index))), item.app.key,
                        item.app.displayName, item.app.bundlePath, "203.0.113.\(index + 10)", 443,
                        item.name, item.list, [item.list]))
        }
        log.append((now.addingTimeInterval(-30), safari.key, "Safari", safari.bundlePath, "151.101.1.140", 443,
                    "www.theguardian.com", nil, []))
        model.adsLog.append(log)
    }
    model.glance.refresh()
    return World(model: model, connections: connections, historyModel: HistoryViewModel(monitor: model, calendar: calendar),
                 ads: AdsViewModel(monitor: model, calendar: calendar))
}

/// The whole window, title bar and toolbar included, at 2x, as the window
/// server composites it: drawing the views alone leaves the toolbar's glass
/// blank.
@available(macOS 14.0, *)
func save(_ window: NSWindow, _ name: String, appearance: NSAppearance.Name) {
    var image: CGImage?
    var failure: Error?
    var done = false
    let windowID = CGWindowID(window.windowNumber)
    Task {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let target = content.windows.first(where: { $0.windowID == windowID }) else {
                throw NSError(domain: "DesignShots", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "window \(windowID) isn't shareable"])
            }
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let config = SCStreamConfiguration()
            config.width = Int(target.frame.width * 2)
            config.height = Int(target.frame.height * 2)
            config.ignoreShadowsSingleWindow = true
            config.showsCursor = false
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch { failure = error }
        done = true
    }
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    guard let image else {
        FileHandle.standardError.write("\(name): \(failure?.localizedDescription ?? "no image")\n".data(using: .utf8)!)
        return
    }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = window.frame.size
    let suffix = appearance == .darkAqua ? "dark" : "light"
    let url = out.appendingPathComponent("\(name)-\(suffix).png")
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    print("\(url.path)  \(Int(window.frame.width))×\(Int(window.frame.height)) pt")
}

func show(_ window: NSWindow, appearance: NSAppearance.Name, settle: TimeInterval = 1.2) {
    window.appearance = NSAppearance(named: appearance)
    // Out of sight but for its top-left corner's single point, which is
    // rounded off and so transparent, just inside the sharpest screen's
    // bottom-right corner: a window wholly off every screen is drawn at 1x.
    if let screen = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }) {
        window.setFrameOrigin(NSPoint(x: screen.frame.maxX - 1, y: screen.frame.minY - window.frame.height + 1))
    }
    window.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(settle))
}

func wanted(_ name: String) -> Bool { only.map { $0.contains(name) } ?? true }

@available(macOS 14.0, *)
func capture(_ world: World, prefix: String, appearance: NSAppearance.Name) {
    // The popover, each of its four views (#436), in a plain window of its width.
    let popover = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
                           styleMask: [.borderless], backing: .buffered, defer: false)
    popover.backgroundColor = .windowBackgroundColor
    let host = NSHostingController(rootView: MenuBarPopoverView(model: world.model, onSettings: {}, onHistory: {},
                                                                onConnections: {}, onAds: {}))
    host.sizingOptions = [.preferredContentSize]
    popover.contentViewController = host
    world.model.setPopoverOpen(true)
    // On a home Wi-Fi network, named as the popover names it.
    let home = NetworkFingerprint(id: "design-home", kind: .wifi, gatewayMAC: "design-home",
                                  defaultLabel: "Home Wi-Fi", isExpensive: false, isConstrained: false)
    world.model.showConnectionForPictures(ConnectionStatus.make(network: home, verdict: .unmetered, name: "Home Wi-Fi"))
    for section in PopoverSection.allCases where wanted(prefix + "popover-\(section.rawValue)") {
        world.model.popoverSection = section
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        popover.setContentSize(host.view.fittingSize)
        show(popover, appearance: appearance, settle: 0.8)
        save(popover, prefix + "popover-\(section.rawValue)", appearance: appearance)
    }
    world.model.popoverSection = .today
    popover.orderOut(nil)

    let settings = SettingsWindowController(model: world.model, history: world.historyModel,
                                            connections: world.connections, ads: world.ads, onOpenConnections: {},
                                            onUninstall: {}, defaults: .standard)
    for (pane, name, setup) in [(SettingsPane.general, "settings-general", AdsViewModel.SetupTab.lists),
                                (.connections, "settings-connections", .lists),
                                (.ads, "settings-ads", .lists), (.ads, "settings-ads-rules", .rules),
                                (.history, "settings-history", .lists), (.hotspot, "settings-hotspot", .lists)]
    where wanted(prefix + name) {
        world.ads.setupTab = setup
        settings.select(pane)
        show(settings.window, appearance: appearance)
        settings.windowDidShow()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        save(settings.window, prefix + name, appearance: appearance)
    }
    settings.window.orderOut(nil)

    let connectionsWindow = ConnectionsWindowController(model: world.connections)
    for layout in ConnectionsViewModel.Layout.allCases where wanted(prefix + "connections-\(layout.rawValue)") {
        world.connections.layout = layout
        show(connectionsWindow.window, appearance: appearance)
        connectionsWindow.windowDidShow()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        save(connectionsWindow.window, prefix + "connections-\(layout.rawValue)", appearance: appearance)
    }
    connectionsWindow.windowWillClose()
    connectionsWindow.window.orderOut(nil)

    let adsWindow = AdsWindowController(model: world.ads)
    for tab in AdsViewModel.Tab.allCases where wanted(prefix + "ads-\(tab.rawValue)") {
        adsWindow.select(tab)
        show(adsWindow.window, appearance: appearance)
        adsWindow.windowDidShow()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        save(adsWindow.window, prefix + "ads-\(tab.rawValue)", appearance: appearance)
    }
    adsWindow.windowWillClose()
    adsWindow.window.orderOut(nil)

    // Usage History, a window of its own (#436).
    let historyWindow = HistoryWindowController(model: world.historyModel)
    if wanted(prefix + "history") {
        show(historyWindow.window, appearance: appearance)
        historyWindow.windowDidShow()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        save(historyWindow.window, prefix + "history", appearance: appearance)
    }
    historyWindow.windowWillClose()
    historyWindow.window.orderOut(nil)
}

if #available(macOS 14.0, *) {
    let full = makeWorld(.full, filter: .on)
    for appearance in [NSAppearance.Name.darkAqua, .aqua] { capture(full, prefix: "", appearance: appearance) }
    // No data yet, the filter on: every list's empty state.
    capture(makeWorld(.empty, filter: .on), prefix: "empty-", appearance: .darkAqua)
    // A first launch: no data, and the filter not set up.
    capture(makeWorld(.empty, filter: .off), prefix: "first-", appearance: .darkAqua)
    exit(0)
} else {
    FileHandle.standardError.write("needs macOS 14 or later, for ScreenCaptureKit's screenshots\n".data(using: .utf8)!)
    exit(1)
}
