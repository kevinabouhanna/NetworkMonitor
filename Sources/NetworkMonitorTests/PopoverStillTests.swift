import AppKit
import SwiftUI
import FirewallPolicy
import NetworkMonitorCore

/// Which clicks in the app's own windows close the popover, and the popover
/// standing still as it moves through its views (#728). A long list and a
/// scroll bar with a place of its own came to 333 points, and the popover, 320
/// wide, was centred on that: 6 points of its header off its left edge, and
/// everything sliding sideways to and from a list that didn't scroll.
func runPopoverStillTests() {
    Check.suite("A click outside the popover closes it (#728)") {
        Check.test("in the app's own windows, and not in the popover's or the menu bar's") {
            func window(_ level: NSWindow.Level = .normal) -> NSWindow {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                      styleMask: [.borderless], backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false
                window.level = level
                return window
            }
            let popover = window()
            let info = window()           // an ⓘ's popover, from the popover
            let inInfo = window()         // and one from that
            popover.addChildWindow(info, ordered: .above)
            info.addChildWindow(inInfo, ordered: .above)
            let main = window()
            let mainsChild = window()
            main.addChildWindow(mainsChild, ordered: .above)
            defer {
                info.removeChildWindow(inInfo)
                popover.removeChildWindow(info)
                main.removeChildWindow(mainsChild)
            }
            func closes(_ window: NSWindow?) -> Bool { PopoverClicks.closes(clickIn: window, popover: popover) }

            Check.expectTrue(closes(main), "the main window")
            Check.expectTrue(closes(mainsChild), "a popover in the main window")
            Check.expectTrue(closes(window(.floating)), "a question about a connection, which floats")
            Check.expectTrue(closes(window(.modalPanel)), "an alert")

            Check.expectFalse(closes(popover), "the popover itself")
            Check.expectFalse(closes(info), "an ⓘ opened from the popover")
            Check.expectFalse(closes(inInfo), "something opened from that")
            // It toggles the popover itself (#6), on any screen's menu bar; and
            // the window the popover is anchored to is at the same level.
            Check.expectFalse(closes(window(.statusBar)), "the menu bar item")
            Check.expectFalse(closes(window(.popUpMenu)), "a menu")
            Check.expectFalse(closes(nil), "no window")
            Check.expectFalse(PopoverClicks.closes(clickIn: main, popover: nil), "no popover")

            // Which come forward with the click, so aren't kept in place (#71).
            Check.expectTrue(PopoverClicks.isIn(main, anyOf: [window(), main]), "the main window")
            Check.expectTrue(PopoverClicks.isIn(mainsChild, anyOf: [main]), "a popover in the main window")
            Check.expectFalse(PopoverClicks.isIn(window(.floating), anyOf: [main]), "a question")
            Check.expectFalse(PopoverClicks.isIn(nil, anyOf: [main]), "no window")
        }
    }

    // Reads a window, so in a VM while the screen is locked (#675).
    Check.windowSuite("The popover stands still between its views (#728)") {
        OutOfSight.startApp()
        for style in [NSScroller.Style.legacy, .overlay] {
            let named = style == .legacy ? "scroll bars with a place of their own" : "scroll bars over the list"
            Check.test("the header stays put in every view and grouping, with \(named)") {
                // Whatever mouse this Mac has, and its setting, which AppKit
                // reads once: the method that answers it is answered here.
                guard let method = class_getClassMethod(NSScroller.self,
                                                        #selector(getter: NSScroller.preferredScrollerStyle)) else {
                    Check.expectTrue(false, "NSScroller has no preferredScrollerStyle to answer")
                    return
                }
                let answer: @convention(block) (AnyObject) -> Int = { _ in style.rawValue }
                let own = method_setImplementation(method, imp_implementationWithBlock(answer))
                NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
                defer {
                    method_setImplementation(method, own)
                    NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification,
                                                    object: nil)
                }
                expectStill(style)
            }
        }
    }
}

/// Every view of the popover and every grouping, with a list that scrolls in
/// some and not in others: the header's frames, and each list's.
private func expectStill(_ style: NSScroller.Style) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("still-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let history = UsageHistory(databaseURL: dir.appendingPathComponent("history.sqlite"))
    let now = Date()
    func app(_ i: Int) -> AppIdentity {
        AppIdentity(key: "/Applications/App \(i).app", displayName: "App \(i)",
                    bundlePath: "/Applications/App \(i).app", isSystem: false)
    }
    // Twenty apps, on two networks: more apps and servers than fit, blocked
    // from many sites, but only three of them blocked from any. All but
    // nothing on the first network, so its bar is as long as a bar gets.
    for n in 0..<2 {
        history.join(NetworkFingerprint(id: "net\(n)", kind: .wifi, gatewayMAC: "net\(n)", defaultLabel: "Net \(n)",
                                        isExpensive: false, isConstrained: false),
                     label: "Net \(n)", switched: n > 0, now: now)
        var servers: [String: [String: ByteCounts]] = [:]
        var entries: [(identity: AppIdentity, bytesIn: Int64, bytesOut: Int64)] = []
        var blocks: [(identity: AppIdentity, name: String, list: String)] = []
        for i in 0..<20 {
            entries.append((app(i), n == 0 ? Int64(15_000_000 - i * 1_000) : 1_000, 0))
            servers[app(i).key] = ["198.51.100.\(i)": ByteCounts(bytesIn: 900_000_000, bytesOut: 0)]
            blocks.append((app(i % 3), "ads\(i).example\(i).com", "ads"))
        }
        history.recordInterface(bytesIn: n == 0 ? 312_400_000 : 1_000, bytesOut: 0, now: now)
        history.recordApps(entries, servers: servers, now: now)
        history.recordListBlocks(blocks, now: now)
        history.flush(now: now)
    }
    let store = UsageStore(storeURL: dir.appendingPathComponent("usage.json"), history: history)
    let metering = MeteringController(store: store,
                                      journal: SuppressionJournal(url: dir.appendingPathComponent("journal.json")),
                                      suppressors: [], defaults: Check.defaults("popover-still"))
    let model = MonitorViewModel(store: store, metering: metering)
    let glance = model.glance
    let saved = (model.firewall.lists, glance.period, glance.dataGrouping, glance.connectionsGrouping, glance.adsGrouping)
    model.firewall.lists = [.ads]
    glance.period = .today
    defer {
        model.firewall.lists = saved.0
        (glance.period, glance.dataGrouping, glance.connectionsGrouping, glance.adsGrouping) =
            (saved.1, saved.2, saved.3, saved.4)
    }
    glance.refresh()
    let deadline = Date() + 5
    while (!glance.hasLoaded || glance.report == nil || glance.ads.sites.isEmpty) && Date() < deadline {
        RunLoop.main.run(until: Date() + 0.05)
    }

    let hosting = NSHostingView(rootView: MenuBarPopoverView(
        model: model, onSettings: {}, onHistory: {}, onConnections: {}, onAds: {}))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "Popover still"
    window.contentView = hosting
    window.placeOutOfSight()
    defer { window.orderOut(nil) }

    func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }

    /// The header's controls, and where each is in the popover.
    func header() -> [(name: String, frame: CGRect)] {
        let origin = CGPoint(x: window.frame.minX, y: NSScreen.screens[0].frame.maxY - window.frame.maxY)
        let wanted = [L("Period"), L("Data"), L("Connections"), L("Ads blocked"), L("Network"), L("Settings")]
        let elements = AccessibilityAudit.framesOwnWindow(titled: window.title)
        var found: [(name: String, frame: CGRect)] = []
        for name in wanted {
            // "Data, Today, 18 GB": the button says its figure with its name.
            guard let element = elements.first(where: { $0.name == name || $0.name.hasPrefix(name + ", ") })
            else { continue }
            found.append((name, element.frame.offsetBy(dx: -origin.x, dy: -origin.y)))
        }
        return found
    }

    var first: [(name: String, frame: CGRect)] = []
    var scrolled: Set<Bool> = []
    func check(_ view: String) {
        RunLoop.main.run(until: Date() + 0.7)
        let now = header()
        Check.expectEqual(now.map(\.name).count, 6, "\(view): the header's controls found: \(now.map(\.name))")
        if first.isEmpty { first = now }
        for (was, is_) in zip(first, now) {
            let moved = max(abs(was.frame.minX - is_.frame.minX), abs(was.frame.minY - is_.frame.minY),
                            abs(was.frame.width - is_.frame.width), abs(was.frame.height - is_.frame.height))
            Check.expectTrue(moved <= 0.5, "\(view): \(is_.name) is at \(is_.frame), in Data \(was.frame)")
        }
        for scroll in scrollViews(in: hosting) {
            let frame = scroll.convert(scroll.bounds, to: hosting)
            Check.expectTrue(abs(frame.minX) <= 0.5 && abs(frame.width - hosting.bounds.width) <= 0.5,
                             "\(view): the list is at \(frame), in a popover \(hosting.bounds.width) wide")
            let scrolls = (scroll.documentView?.frame.height ?? 0) > frame.height
            scrolled.insert(scrolls)
            if scrolls {
                Check.expectEqual(scroll.scrollerStyle, style, "\(view): the scroll bar's style")
            }
            // The rows end at one place, whether or not there's a bar.
            let bar = style == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
            let rows = scroll.documentView?.frame.width ?? 0
            Check.expectTrue(abs(rows - (scrolls ? PopoverMetrics.width - bar : PopoverMetrics.width)) <= 0.5,
                             "\(view): the list's content is \(rows) wide")
        }
        Check.expectTrue(abs(hosting.fittingSize.width - PopoverMetrics.width) <= 0.5,
                         "\(view): the popover is \(hosting.fittingSize.width) wide")
    }

    for grouping in PopoverDataGrouping.allCases {
        model.popoverSection = .today
        glance.dataGrouping = grouping
        check("Data › \(grouping.label)")
        // A full bar leaves the figure after it whole.
        if grouping == .networks {
            let figure = ByteFormat.bytes(glance.report?.networks.first?.bytes ?? 0)
            let ideal = (figure as NSString).size(withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: PopoverMetrics.totalFontSize, weight: .medium)]).width
            let seen = AccessibilityAudit.framesOwnWindow(titled: window.title)
                .filter { $0.name == figure }.map(\.frame)
            Check.expectTrue(seen.contains { $0.width >= ideal - 1 && $0.height < 20 },
                             "\(figure) beside a full bar is at \(seen), \(ideal) wide whole")
        }
    }
    for grouping in ConnectionsGrouping.allCases {
        model.popoverSection = .companies
        glance.connectionsGrouping = grouping
        check("Connections › \(grouping.label)")
    }
    for grouping in PopoverAdsGrouping.allCases {
        model.popoverSection = .blocked
        glance.adsGrouping = grouping
        check("Ads blocked › \(grouping.label)")
    }
    model.popoverSection = .connection
    check("Network")
    // Without both, it would pass checking nothing.
    Check.expectEqual(scrolled, [true, false], "a list that scrolls, and one that doesn't")
}
