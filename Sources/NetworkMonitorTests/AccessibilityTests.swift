import AppKit
import SwiftUI
import NetworkMonitorCore

/// Every window VoiceOver can reach, read through the Accessibility API and
/// checked for the problems a program can find (#346). Built here with empty
/// data; `make site-audit` checks the installed app with real rows in its lists.
func runAccessibilityTests() {
    // Every SF Symbol the app's code names, so a control named after one is
    // caught on any macOS (see `AccessibilityAudit.audit`).
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("NetworkMonitorCore")
    var symbols: Set<String> = ["gearshape.fill"]   // FaultyView's
    let pattern = try! NSRegularExpression(pattern: #"(?:systemName|systemSymbolName): "([a-z0-9.]+)""#)
    for file in (try? FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)) ?? [] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
        for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            symbols.insert((text as NSString).substring(with: m.range(at: 1)))
        }
    }

    Check.suite("Accessibility") {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        // The Accessibility API only answers a process that has finished
        // launching.
        NSApp.finishLaunching()

        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("a11y-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = UserDefaults(suiteName: "a11y-\(UUID().uuidString)")!
        let store = UsageStore(storeURL: dir.appendingPathComponent("usage.json"))
        let metering = MeteringController(store: store,
                                          journal: SuppressionJournal(url: dir.appendingPathComponent("journal.json")),
                                          suppressors: [], defaults: defaults)
        let model = MonitorViewModel(store: store, metering: metering)
        let connections = ConnectionsViewModel(monitor: model, defaults: defaults)

        /// Shows the window out of sight, lets SwiftUI lay it out, and audits it.
        func check(_ window: NSWindow, _ name: String) {
            Check.test("\(name) names everything VoiceOver reads") {
                window.alphaValue = 0
                window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
                window.orderFrontRegardless()
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                guard let problems = AccessibilityAudit.auditOwnWindow(titled: window.title, symbols: symbols) else {
                    Check.expectTrue(false, "couldn't read the \(window.title) window's accessibility tree")
                    return
                }
                for problem in problems { Check.expectTrue(false, problem.description) }
                window.orderOut(nil)
            }
        }

        // The check itself: a window with each problem in it must fail, or a
        // pass below means nothing.
        Check.test("the check finds an unnamed switch, a symbol's name and a bare image") {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Faulty"
            window.contentView = NSHostingView(rootView: FaultyView())
            window.alphaValue = 0
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let rules = AccessibilityAudit.auditOwnWindow(titled: "Faulty", symbols: symbols)?.map(\.rule) ?? []
            Check.expectTrue(rules.contains { $0.hasPrefix("has no name") }, "missed the unnamed switch: \(rules)")
            Check.expectTrue(rules.contains { $0.hasPrefix("is named only by its symbol") }, "missed the symbol's name: \(rules); saw \(AccessibilityAudit.outlineOwnWindow(titled: "Faulty"))")
            Check.expectTrue(rules.contains { $0.hasPrefix("is an image") }, "missed the bare image: \(rules)")
            window.orderOut(nil)
        }

        let settings = SettingsWindowController(model: model, history: HistoryViewModel(monitor: model),
                                                connections: connections, onOpenConnections: {},
                                                onUninstall: {}, defaults: defaults)
        for pane in SettingsPane.allCases {
            settings.select(pane)
            check(settings.window, "Settings › \(pane.title)")
        }

        check(ConnectionsWindowController(model: connections).window, "Connections")

        let adsController = AdsWindowController(model: AdsViewModel(monitor: model))
        for tab in AdsViewModel.Tab.allCases {
            adsController.select(tab)
            check(adsController.window, "Ads and Trackers › \(tab.label)")
        }

        let popover = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
                               styleMask: [.titled], backing: .buffered, defer: false)
        popover.title = "Popover"
        popover.contentView = NSHostingView(rootView: MenuBarPopoverView(
            model: model, onSettings: {}, onHistory: {}, onConnections: {}, onAds: {}))
        check(popover, "The popover")
    }
}

/// One of each problem the audit looks for.
private struct FaultyView: View {
    final class State: ObservableObject { @Published var on = true }
    @StateObject private var state = State()
    var body: some View {
        VStack {
            Toggle("", isOn: $state.on).labelsHidden()
            Button {} label: { Image(systemName: "gearshape.fill") }
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32)
        }
    }
}
