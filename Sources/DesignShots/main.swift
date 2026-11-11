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

// `--dock-icons <dir>`: the Dock icon that is the speeds (#523), in light and
// in dark, one strip each, on a stand-in for the Dock. Drawn as the Dock gets
// it, one 256 px picture, and shrunk to the Dock's sizes as the Dock does.
// Drawn offscreen, so it needs neither the screen nor the bundle.
if let dockDirectory = argument("--dock-icons") {
    let readouts = [
        SpeedReadout(down: MenuBarTitle.downLine(12_340_000), up: MenuBarTitle.upLine(345_000), tints: .live),
        SpeedReadout(down: MenuBarTitle.downLine(0), up: MenuBarTitle.upLine(0), tints: .live),
        SpeedReadout(down: "↓ \(ByteFormat.menuBarSpeed(948_200_000, unit: .bits))",
                     up: "↑ \(ByteFormat.menuBarSpeed(41_070_000, unit: .bits))", tints: MenuBarTints.testChoices[0]),
        SpeedReadout(down: MenuBarTitle.downLine(2_100), up: MenuBarTitle.upLine(870), tints: .blockingEverything),
    ]
    let sides: [CGFloat] = [32, 48, 58, 64, 96, 128]
    let gap: CGFloat = 16
    let width = (sides.reduce(0, +) + gap * CGFloat(sides.count)) * CGFloat(readouts.count) + gap
    let height = sides.max()! + 2 * gap
    try? FileManager.default.createDirectory(atPath: dockDirectory, withIntermediateDirectories: true)
    for dark in [false, true] {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: dark ? 0.2 : 0.86, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.current?.imageInterpolation = .high
        var x = gap
        for readout in readouts {
            let tile = DockSpeedView.image(readout, side: 128, dark: dark)
            for side in sides {
                tile.draw(in: NSRect(x: x, y: gap, width: side, height: side))
                x += side + gap
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let file = URL(fileURLWithPath: dockDirectory).appendingPathComponent("dock-\(dark ? "dark" : "light").png")
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
        print(file.path)
    }
    exit(0)
}
guard arguments.contains("--keyboard") || CGPreflightScreenCaptureAccess() else {
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
        // One more hour's worth, so the store's own hour doesn't stand out
        // in History's chart.
        let level = activity(calendar.component(.hour, from: now), 0)
        let entries = talkers.map { talker -> (identity: AppIdentity, bytesIn: Int64, bytesOut: Int64) in
            let bytes = talker.megabytesPerHour * level * 1_000_000
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

/// Today, by apps, companies and sites: what the popover shows until someone
/// changes it, whatever the last run left remembered (#449).
func resetPopoverChoices(_ glance: TodayGlance) {
    glance.period = .today
    glance.dataGrouping = .apps
    glance.connectionsGrouping = .companies
    glance.adsGrouping = .sites
}

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
    resetPopoverChoices(world.model.glance)
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
    // Companies and Ads blocked with their first row open (#436).
    let glance = world.model.glance
    for (section, id) in [(PopoverSection.companies, glance.groups.first?.item.id),
                          (.blocked, glance.ads.sites.first.map { "site:" + $0.id })]
    where wanted(prefix + "popover-\(section.rawValue)-open") {
        guard let id else { continue }
        world.model.popoverSection = section
        glance.expanded = [id]
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        popover.setContentSize(host.view.fittingSize)
        show(popover, appearance: appearance, settle: 0.8)
        save(popover, prefix + "popover-\(section.rawValue)-open", appearance: appearance)
    }
    glance.expanded = []
    // The other periods and groupings (#449).
    for (name, section, period, set) in [
        ("popover-today-networks-week", PopoverSection.today, PopoverPeriod.week,
         { glance.dataGrouping = .networks } as () -> Void),
        ("popover-companies-countries-month", .companies, .month, { glance.connectionsGrouping = .countries }),
        ("popover-companies-apps", .companies, .today, { glance.connectionsGrouping = .apps }),
        ("popover-blocked-apps-week", .blocked, .week, { glance.adsGrouping = .apps }),
    ] where wanted(prefix + name) {
        world.model.popoverSection = section
        glance.period = period
        set()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        popover.setContentSize(host.view.fittingSize)
        show(popover, appearance: appearance, settle: 0.8)
        save(popover, prefix + name, appearance: appearance)
        resetPopoverChoices(glance)
    }
    world.model.popoverSection = .today
    popover.orderOut(nil)


    // The main window (#436): each section, and each section's settings in place.
    let main = MainWindowController(model: world.model, history: world.historyModel,
                                    connections: world.connections, ads: world.ads)
    // The size a first opening has, whatever an earlier run left remembered.
    main.window.setContentSize(NSSize(width: 1300, height: 800))
    func shoot(_ name: String, settle: TimeInterval = 1.2) {
        guard wanted(prefix + name) else { return }
        show(main.window, appearance: appearance)
        main.windowDidShow()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        save(main.window, prefix + name, appearance: appearance)
    }
    /// The same, at the narrowest and shortest the window can be for the
    /// section shown, then back to the size it had.
    func shootAtMinimum(_ name: String, settle: TimeInterval = 1.2) {
        guard wanted(prefix + name) else { return }
        let frame = main.window.frame
        main.window.setContentSize(main.window.contentMinSize)
        shoot(name, settle: settle)
        main.window.setFrame(frame, display: false)
    }
    main.show(.history)
    shoot("history", settle: 1.5)
    // The View's layouts (#524), at the window's default size and its least.
    for layout in ChartLayout.allCases {
        world.historyModel.layout = layout
        if layout != .both { shoot("history-\(layout.rawValue)") }
        shootAtMinimum("history-\(layout.rawValue)-min")
    }
    world.historyModel.layout = .both
    // Search open, holding a search (#436).
    world.historyModel.search = "Sa"
    shoot("history-search", settle: 1.0)
    world.historyModel.search = ""
    main.show(.connections)
    for layout in ConnectionsViewModel.Layout.allCases {
        world.connections.layout = layout
        shoot("connections-\(layout.rawValue)", settle: 1.5)
    }
    // Both at the window's least, beside Usage History's and Ads and
    // Trackers', which share its split (#534).
    world.connections.layout = .both
    shootAtMinimum("connections-both-min", settle: 1.5)
    main.show(.ads)
    for tab in AdsViewModel.Tab.allCases {
        main.ads.select(tab)
        shoot("ads-\(tab.rawValue)")
    }
    main.ads.select(.overview)
    // The View's layouts and Sites or Apps (#524), at the window's default
    // size and its least.
    for layout in ChartLayout.allCases {
        world.ads.layout = layout
        for grouping in PopoverAdsGrouping.allCases where layout.showsList || grouping == .sites {
            world.ads.grouping = grouping
            let name = "ads-\(layout.rawValue)" + (grouping == .apps ? "-apps" : "")
            if name != "ads-both" { shoot(name) }
            shootAtMinimum(name + "-min")
        }
    }
    world.ads.layout = .both
    world.ads.grouping = .sites
    // The list and the chart you can use (#536): the busiest site open and
    // chosen, its share on the chart; a bar hovered; then picked, with both
    // chips, at the window's least too; and an app's site chosen in Apps.
    if let site = world.ads.report.sites.first {
        world.ads.setExpanded(site.id, true)
        world.ads.select(.init(grouping: .sites, parent: site.id, title: site.title))
        shoot("ads-chosen")
        if let busiest = world.ads.bins.max(by: { $0.count < $1.count }) {
            world.ads.hover(busiest.interval.start)
            shoot("ads-hover")
            world.ads.hover(nil)
            world.ads.pick(binStarting: busiest.interval.start)
            shoot("ads-picked")
            shootAtMinimum("ads-picked-min")
            world.ads.clearSpan()
        }
        world.ads.clearSelection()
        world.ads.setExpanded(site.id, false)
    }
    // What VoiceOver reads off real rows, open and chosen (#536): the test
    // suite's Ads window has none. In a window of its own, as the suite
    // checks its sections, and printed rather than saved.
    if wanted(prefix + "ads-audit") { world.ads.reload() }
    if wanted(prefix + "ads-audit"), let site = world.ads.report.sites.first {
        world.ads.setExpanded(site.id, true)
        world.ads.select(.init(grouping: .sites, parent: site.id, title: site.title))
        let controller = AdsWindowController(model: world.ads)
        show(controller.window, appearance: appearance)
        let problems = AccessibilityAudit.auditOwnWindow(titled: controller.window.title)
        var report = "ads-audit: " + (problems.map { $0.isEmpty ? "no problems" : $0.map(\.description).joined(separator: "\n") }
                                          ?? "couldn't read the window") + "\n"
        for line in AccessibilityAudit.outlineOwnWindow(titled: controller.window.title) { report += "  " + line + "\n" }
        FileHandle.standardError.write(report.data(using: .utf8)!)
        controller.window.orderOut(nil)
        world.ads.clearSelection()
        world.ads.setExpanded(site.id, false)
    }
    world.ads.grouping = .apps
    if let app = world.ads.report.apps.first, let child = app.children.first {
        world.ads.setExpanded(app.id, true)
        world.ads.select(.init(grouping: .apps, parent: app.id, child: child.id,
                               title: "\(child.title) in \(app.title)"))
        shoot("ads-apps-chosen")
        world.ads.clearSelection()
        world.ads.setExpanded(app.id, false)
    }
    world.ads.grouping = .sites
    world.connections.search = "Goo"
    main.show(.connections)
    shoot("connections-search", settle: 1.5)
    world.connections.search = ""
    main.show(.network)
    shoot("network")
    main.show(.settings)
    shoot("settings-general")
    for section in MainSection.features {
        main.show(section)
        main.showSettings()
        world.ads.setupTab = .lists
        shoot("main-\(section.rawValue)-settings")
        if section == .ads {
            world.ads.setupTab = .rules
            shoot("main-ads-settings-rules")
            world.ads.setupTab = .lists
        }
    }
    main.windowWillClose()
    main.window.orderOut(nil)
}

/// The narrowest each window can be with every toolbar item showing (#315):
/// shrunk a point at a time until AppKit starts moving items into the »
/// overflow. `--measure` prints them; the windows' minimum widths must be
/// at least these.
func measureToolbars(_ world: World) {
    let main = MainWindowController(model: world.model, history: world.historyModel,
                                    connections: world.connections, ads: world.ads)
    let window = main.window
    // Measured with search open, as wide as it gets while it's used.
    for search in [main.history.search, main.connections.search, main.ads.search] { search.show("x") }
    for (pass, section) in ([MainSection.allCases[0]] + MainSection.allCases).enumerated() {
        main.show(section)
        window.contentMinSize = NSSize(width: 300, height: 300)
        show(window, appearance: .darkAqua, settle: 0.6)
        var width: CGFloat = 1600
        var fits = width
        var first = ""
        while width >= 300 {
            window.setContentSize(NSSize(width: width, height: 700))
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            let skip: Set<NSToolbarItem.Identifier> = [.flexibleSpace, .space, .sidebarTrackingSeparator]
            let items = window.toolbar?.items.filter { !skip.contains($0.itemIdentifier) } ?? []
            let visible = window.toolbar?.visibleItems?.filter { !skip.contains($0.itemIdentifier) } ?? []
            if visible.count < items.count {
                let shown = Set(visible.map(\.itemIdentifier))
                first = items.filter { !shown.contains($0.itemIdentifier) }.map(\.itemIdentifier.rawValue)
                    .joined(separator: ", ")
                break
            }
            fits = width
            width -= 2
        }
        // The first pass only warms the window up: measured first, a section
        // read 200 pt wider than it needs.
        if pass == 0 { continue }
        print("\(section.rawValue): toolbar fits from \(Int(fits)) pt" + (first.isEmpty ? "" : "; narrower, \(first) goes first"))
    }
    window.orderOut(nil)
}





/// Every window toured with Tab, as with Keyboard navigation on, with rows
/// in its lists (#455): each stop and what VoiceOver says there, and what
/// someone moving with the keyboard would trip on. `--keyboard`; the test
/// suite tours the same windows empty. Exits 1 on a problem.
func tourKeyboard(_ world: World) -> Int32 {
    KeyboardTour.start()
    defer { KeyboardTour.stop() }
    var failed = 0
    func tour(_ name: String, _ window: NSWindow) {
        guard wanted(name) else { return }
        let tour = KeyboardTour.walk(window)
        print("\n\(name)\n" + tour.description.split(separator: "\n").map { "  " + $0 }.joined(separator: "\n"))
        for problem in KeyboardTour.problems(in: window, tour) {
            print("  ✗ \(problem)")
            failed += 1
        }
    }
    func place(_ window: NSWindow) {
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
    }
    func settle(_ seconds: TimeInterval = 0.8) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    let popover = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
                           styleMask: [.titled], backing: .buffered, defer: false)
    popover.title = "Popover"
    let host = NSHostingController(rootView: MenuBarPopoverView(model: world.model, onSettings: {}, onHistory: {},
                                                                onConnections: {}, onAds: {}))
    host.sizingOptions = [.preferredContentSize]
    popover.contentViewController = host
    resetPopoverChoices(world.model.glance)
    world.model.setPopoverOpen(true)
    place(popover)
    for section in PopoverSection.allCases {
        world.model.popoverSection = section
        settle(0.4)
        popover.setContentSize(host.view.fittingSize)
        settle(0.4)
        tour("popover-\(section.rawValue)", popover)
    }
    world.model.popoverSection = .today
    popover.orderOut(nil)

    let main = MainWindowController(model: world.model, history: world.historyModel,
                                    connections: world.connections, ads: world.ads)
    main.window.setContentSize(NSSize(width: 1300, height: 800))
    place(main.window)
    main.windowDidShow()
    for section in MainSection.allCases {
        main.show(section)
        settle(1.2)
        tour(section.rawValue, main.window)
        guard section != .settings else { continue }
        main.showSettings()
        settle()
        tour("\(section.rawValue)-settings", main.window)
    }
    main.windowWillClose()
    main.window.orderOut(nil)
    print(failed == 0 ? "\nNo problems." : "\n\(failed) problem(s).")
    return failed == 0 ? 0 : 1
}

if arguments.contains("--keyboard") {
    exit(tourKeyboard(makeWorld(.full, filter: .on)))
}

if arguments.contains("--measure") {
    measureToolbars(makeWorld(.full, filter: .on))
    exit(0)
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
