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
        OutOfSight.startApp()

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
                window.placeOutOfSight()
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
            window.placeOutOfSight()
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
            // They're in Network's settings now, in the main window (#436).
            if code == Localization.source { Check.test("Network's settings read each speed test style's picture as one button") {
                let main = MainWindowController(model: model, history: HistoryViewModel(monitor: model),
                                                connections: connections, ads: AdsViewModel(monitor: model))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.title = "Network settings"
                window.contentViewController = main.settingsPage(for: .network)
                window.setContentSize(NSSize(width: 760, height: 900))
                window.placeOutOfSight()
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                let outline = AccessibilityAudit.outlineOwnWindow(titled: window.title)
                for style in ["Card", "Compact"] {
                    Check.expectTrue(outline.contains { $0.hasPrefix("AXButton name=\(style) ") },
                                     "no \(style) button in \(outline)")
                }
                // The pictures' sample card has a Test Again button; the page
                // has none of its own, so finding one means the sample leaked.
                Check.expectTrue(!outline.contains { $0.contains("name=Test Again ") },
                                 "the picture's sample buttons reach VoiceOver: \(outline)")
                window.orderOut(nil)
            } }

            // Where the map's lines start, as hovering its ring shows (#231).
            if code == Localization.source { Check.test("VoiceOver reads where the map's lines start, and why") {
                let located = ConnectionsViewModel(monitor: model, defaults: defaults, homeSources: .init(
                    location: { $0("LB") }, internetAddress: { $0(nil) }, region: { "US" }))
                located.layout = .map
                let controller = ConnectionsWindowController(model: located)
                let window = controller.window
                window.title = "Connections, located"
                window.placeOutOfSight()
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                let names = AccessibilityAudit.namesOwnWindow(titled: window.title)
                Check.expectTrue(names.contains { $0.hasPrefix("World map of") && $0.hasSuffix(" Your Mac, in Lebanon (from Location): the lines start there.") },
                                 "the map doesn't say where its lines start: \(names.filter { $0.contains("map") })")
                window.orderOut(nil)
                withExtendedLifetime(controller) {}
            } }

            // The main window (#436). Its split view can't be read through from
            // this process (AppKit lays it out on the asking thread), so each
            // part is checked in a window of its own: the sections, with their
            // toolbars, as the windows they were; the sidebar; Network; and
            // each section's settings page.
            check(ConnectionsWindowController(model: connections).window, "Connections\(language)")
            // Each of the View's layouts (#524), and Ads and Trackers' Sites and Apps.
            let historyModel = HistoryViewModel(monitor: model, defaults: defaults)
            let historyController = HistoryWindowController(model: historyModel)
            for layout in ChartLayout.allCases {
                historyModel.layout = layout
                check(historyController.window, "Usage History › \(layout.label)\(language)")
            }
            let adsModel = AdsViewModel(monitor: model, defaults: defaults)
            let adsController = AdsWindowController(model: adsModel)
            for tab in AdsViewModel.Tab.allCases {
                adsController.select(tab)
                check(adsController.window, "Ads and Trackers › \(tab.label)\(language)")
            }
            adsController.select(.overview)
            for layout in ChartLayout.allCases {
                adsModel.layout = layout
                for grouping in PopoverAdsGrouping.allCases where layout.showsList || grouping == .sites {
                    adsModel.grouping = grouping
                    check(adsController.window,
                          "Ads and Trackers › \(layout.label) › \(grouping.label)\(language)")
                }
            }
            adsModel.grouping = .sites
            // A row chosen (#536): its chip's ✕ says what it does. The rows
            // themselves, open and chosen, are checked with real data by
            // `make design-shots ONLY=ads-audit`.
            adsModel.layout = .both
            adsModel.select(.init(grouping: .sites, parent: "doubleclick.net", title: "doubleclick.net"))
            check(adsController.window, "Ads and Trackers › a row chosen\(language)")
            adsModel.clearSelection()
            // The same View as Connections' (#524): named View, each segment
            // by its layout, in the language shown.
            Check.test("Usage History's and Ads and Trackers' View reads as Connections'\(language)") {
                for window in [historyController.window, adsController.window] {
                    window.placeOutOfSight()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                    let names = AccessibilityAudit.namesOwnWindow(titled: window.title)
                    for name in [L("View")] + ChartLayout.allCases.map(\.label) {
                        Check.expectTrue(names.contains(name), "\(window.title) has no \(name) in \(names)")
                    }
                    window.orderOut(nil)
                }
            }
            // Both is the list and the chart side by side, as in Connections
            // (#534): the list's Show and the chart are both there to read.
            historyModel.layout = .both
            Check.test("Usage History's Both has the list and the chart\(language)") {
                let window = historyController.window
                window.placeOutOfSight()
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                let names = AccessibilityAudit.namesOwnWindow(titled: window.title)
                let chart = [L("Usage by hour"), L("Usage by day"), L("Usage by month")]
                Check.expectTrue(names.contains(L("Show")) && names.contains { chart.contains($0) },
                                 "Both doesn't have the list's Show and the chart: \(names)")
                window.orderOut(nil)
            }
            adsModel.layout = .both
            let main = MainWindowController(model: model, history: HistoryViewModel(monitor: model),
                                            connections: connections, ads: AdsViewModel(monitor: model))
            func part(_ controller: NSViewController, _ title: String, width: CGFloat = 760, height: CGFloat = 640) -> NSWindow {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.title = title
                window.contentViewController = controller
                window.setContentSize(NSSize(width: width, height: height))
                return window
            }
            check(part(main.sidebarController, "Main window sidebar", width: 220), "The main window's sidebar\(language)")
            // A new version waiting on its card, above Settings (#520): the ✕
            // says what it does, and each button reads as it's labelled.
            model.updates.previewCard(version: "9.9.9")
            let updateSidebar = part(main.sidebarController, "Main window sidebar, update", width: 220)
            check(updateSidebar, "The main window's sidebar with an update waiting\(language)")
            Check.test("The update card's buttons are named\(language)") {
                updateSidebar.placeOutOfSight()
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                let names = AccessibilityAudit.namesOwnWindow(titled: updateSidebar.title)
                for name in [L("Install & Restart"), L("What's New"), L("Remind Me Later")] {
                    Check.expectTrue(names.contains(name), "the update card has no \(name) in \(names)")
                }
                updateSidebar.orderOut(nil)
            }
            model.updates.previewCard(version: nil)
            check(part(main.networkController, "Main window Network"), "The main window › Network\(language)")
            check(part(main.generalController, "Main window Settings"), "The main window › Settings\(language)")
            // With Dock chosen, and so its Dock icon choice showing (#523).
            let placement = AppPlacementSetting.shared.placement
            AppPlacementSetting.shared.placement = .dock
            let dockSettings = part(main.generalController, "Main window Settings, Dock")
            check(dockSettings, "The main window › Settings with Dock chosen\(language)")
            if code == Localization.source { Check.test("Dock icon is there only while Dock or Both is chosen") {
                dockSettings.orderFrontRegardless()
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                let shown = AccessibilityAudit.outlineOwnWindow(titled: dockSettings.title)
                // Its two choices, as the segments the outline lists.
                func choices(_ outline: [String]) -> [String] {
                    outline.filter { $0.hasPrefix("AXRadioButton name=Speeds ") || $0.hasPrefix("AXRadioButton name=App icon ") }
                }
                Check.expectEqual(choices(shown).count, 2, "no Dock icon choice with Dock chosen: \(shown)")
                AppPlacementSetting.shared.placement = .both
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                let both = AccessibilityAudit.outlineOwnWindow(titled: dockSettings.title)
                Check.expectEqual(choices(both).count, 2, "no Dock icon choice with Both chosen: \(both)")
                AppPlacementSetting.shared.placement = .menuBar
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                let hidden = AccessibilityAudit.outlineOwnWindow(titled: dockSettings.title)
                Check.expectEqual(choices(hidden), [], "a Dock icon choice with Menu bar chosen")
                dockSettings.orderOut(nil)
            } }
            AppPlacementSetting.shared.placement = placement
            for section in MainSection.features {
                check(part(main.settingsPage(for: section), "Main window \(section.rawValue) settings"),
                      "The main window › \(section.rawValue) › settings\(language)")
            }
            // The standard About panel (#494): AppKit leaves its credits text
            // unnamed, so the app names it once the panel is up.
            Check.test("About names everything VoiceOver reads\(language)") {
                AboutPanel.show()
                guard let window = AboutPanel.window() else {
                    Check.expectTrue(false, "no About panel showing the credits")
                    return
                }
                // Out of sight before the run loop draws it.
                window.placeOutOfSight(order: false)
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                guard let problems = AccessibilityAudit.auditOwnWindow(titled: window.title, symbols: symbols) else {
                    Check.expectTrue(false, "couldn't read the About panel's accessibility tree")
                    return
                }
                for problem in problems { Check.expectTrue(false, problem.description) }
                let outline = AccessibilityAudit.outlineOwnWindow(titled: window.title)
                Check.expectTrue(outline.contains { $0.hasPrefix("AXTextArea name=\(AboutPanel.creditsName) ") },
                                 "the credits aren't named \(AboutPanel.creditsName): \(outline)")
                window.orderOut(nil)
            }

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
            // Each view's other groupings, over a week (#449).
            let glance = model.glance
            let saved = (glance.period, glance.dataGrouping, glance.connectionsGrouping, glance.adsGrouping)
            glance.period = .week
            model.popoverSection = .today
            glance.dataGrouping = .networks
            check(popover, "The popover › today by networks, this week\(language)")
            model.popoverSection = .companies
            for grouping in [ConnectionsGrouping.countries, .apps] {
                glance.connectionsGrouping = grouping
                check(popover, "The popover › companies by \(grouping.rawValue), this week\(language)")
            }
            model.popoverSection = .blocked
            glance.adsGrouping = .apps
            check(popover, "The popover › blocked by apps, this week\(language)")
            (glance.period, glance.dataGrouping, glance.connectionsGrouping, glance.adsGrouping) = saved
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
