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

        // Every window in every language the app has (#433): a name that fits
        // in English can still go missing from a translation.
        for code in Localization.shared.available {
            Localization.shared.showForThisRun(code)
            let language = code == Localization.source ? "" : " (\(code))"
            let settings = SettingsWindowController(model: model, history: HistoryViewModel(monitor: model),
                                                    connections: connections, onOpenConnections: {},
                                                    onUninstall: {}, defaults: defaults)
            for pane in SettingsPane.allCases {
                settings.select(pane)
                check(settings.window, "Settings › \(pane.title)\(language)")
            }

            // The popover styles are pictures to click (#398). Each reads as a
            // button named after its style; the sample card inside is left out.
            // The style names it looks for are English.
            if code == Localization.source { Check.test("Settings › Speed Test reads each style's picture as one button") {
                settings.select(.speedTest)
                settings.window.alphaValue = 0
                settings.window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
                settings.window.orderFrontRegardless()
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                let outline = AccessibilityAudit.outlineOwnWindow(titled: settings.window.title)
                for style in ["Card", "Compact"] {
                    Check.expectTrue(outline.contains { $0.hasPrefix("AXButton name=\(style) ") },
                                     "no \(style) button in \(outline)")
                }
                Check.expectTrue(!outline.contains { $0.contains("name=Back ") },
                                 "the picture's sample buttons reach VoiceOver: \(outline)")
                settings.window.orderOut(nil)
            } }

            // The main window (#436): each section, Ads and Trackers' two tabs,
            // and each section's settings shown in place.
            let main = MainWindowController(model: model, history: HistoryViewModel(monitor: model),
                                            connections: connections, ads: AdsViewModel(monitor: model))
            for section in MainSection.allCases {
                main.show(section)
                if section == .ads {
                    for tab in AdsViewModel.Tab.allCases {
                        main.ads.select(tab)
                        check(main.window, "Main window › \(section.rawValue) › \(tab.rawValue)\(language)")
                    }
                } else {
                    check(main.window, "Main window › \(section.rawValue)\(language)")
                }
                main.showSettings()
                check(main.window, "Main window › \(section.rawValue) › settings\(language)")
            }
            main.window.orderOut(nil)

            let popover = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
                                   styleMask: [.titled], backing: .buffered, defer: false)
            popover.title = "Popover"
            popover.contentView = NSHostingView(rootView: MenuBarPopoverView(
                model: model, onSettings: {}, onHistory: {}, onConnections: {}, onAds: {}))
            // Each of its four views (#436).
            for section in PopoverSection.allCases {
                model.popoverSection = section
                check(popover, "The popover › \(section.rawValue)\(language)")
            }
            model.popoverSection = .today
        }
        Localization.shared.showForThisRun(Localization.source)
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
