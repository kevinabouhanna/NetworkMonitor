import AppKit
import FirewallPolicy
import SwiftUI
import NetworkMonitorCore

/// Every window VoiceOver can reach, read through the Accessibility API and
/// checked for the problems a program can find (#346). Built here with empty
/// data; `make site-audit` checks the installed app with real rows in its lists.
func runAccessibilityTests() {
    // Every SF Symbol the app's code names, so a control named after one is
    // caught on any macOS (see `AccessibilityAudit.audit`).
    let sources = Check.repositoryRoot().appendingPathComponent("Sources/NetworkMonitorCore")
    var symbols: Set<String> = ["gearshape.fill"]   // FaultyView's
    let pattern = try! NSRegularExpression(pattern: #"(?:systemName|systemSymbolName): "([a-z0-9.]+)""#)
    for file in (try? FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)) ?? [] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
        for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            symbols.insert((text as NSString).substring(with: m.range(at: 1)))
        }
    }

    Check.windowSuite("Accessibility") {
        // What the audits lean on, read from the checkout, or in the VM from
        // the copy of it (#675): without them they'd pass, checking less.
        Check.test("the app's symbols and every language's table are there to check against") {
            Check.expectTrue(symbols.count > 20, "only \(symbols.count) symbols, from \(sources.path)")
            Check.expectTrue(Localization.shared.available.count > 1,
                             "only \(Localization.shared.available) to show the windows in")
        }

        OutOfSight.startApp()

        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("a11y-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Check.defaults("a11y")
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
            // The main window as people see it (#436, #527): one window, the
            // sidebar, the section's toolbar and the section together, each
            // section and each section's settings shown in turn. Read on the
            // main thread (#500), its split view reads through.
            let historyModel = HistoryViewModel(monitor: model, defaults: defaults)
            let adsModel = AdsViewModel(monitor: model, defaults: defaults)
            let main = MainWindowController(model: model, history: historyModel,
                                            connections: connections, ads: adsModel)
            let window = main.window
            window.placeOutOfSight()
            main.windowDidShow()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            /// Audits the main window as it is now, under the title it has now.
            func checkMain(_ name: String) {
                Check.test("The main window › \(name)\(language) names everything VoiceOver reads") {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                    guard let problems = AccessibilityAudit.auditOwnWindow(titled: window.title, symbols: symbols) else {
                        Check.expectTrue(false, "couldn't read the main window's accessibility tree, titled \(window.title)")
                        return
                    }
                    for problem in problems { Check.expectTrue(false, problem.description) }
                    // Nothing left in English (#621): a name that has a
                    // translation is read in it. AppKit's own buttons (the
                    // sidebar's, the search's glass) kept the language the
                    // app was launched in, as this test process always does.
                    guard code != Localization.source else { return }
                    for name in AccessibilityAudit.namesOwnWindow(titled: window.title) where L(name) != name {
                        Check.expectTrue(false, "reads “\(name)” in English, not “\(L(name))”")
                    }
                }
            }
            func namesNow() -> [String] { AccessibilityAudit.namesOwnWindow(titled: window.title) }
            func outlineNow() -> [String] { AccessibilityAudit.outlineOwnWindow(titled: window.title) }

            main.show(.connections)
            checkMain("Connections")
            // Rules, beside Traffic and Blocked (#592), with a rule of each
            // kind, and Ads and Trackers' own (checked with its tabs below).
            let made: [FirewallRule] = [
                FirewallRule(subject: .company, key: "Meta", title: "Meta", action: .block),
                FirewallRule(subject: .site, key: "example.com", title: "example.com", action: .allow,
                             network: "router-office", networkTitle: "Office"),
            ]
            let madeAds = [AdRule(kind: .alwaysBlock, site: "tracker.example"),
                           AdRule(kind: .neverBlock, site: nil, appKey: "/Applications/Bank.app", appTitle: "Bank")]
            for rule in made { model.firewall.add(rule) }
            model.firewall.add(madeAds)
            connections.showsRules = true
            checkMain("Connections › Rules")
            connections.showsRules = false
            // What makes the checks above mean something: one read reaches the
            // sidebar, the section's toolbar and the section's own controls,
            // through the split view the parts were once checked apart for.
            Check.test("The main window reads as one: sidebar, toolbar and section\(language)") {
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                let names = namesNow()
                for name in MainSection.allCases.map(\.title) + [L("View"), L("Period"), L("Group by")] {
                    Check.expectTrue(names.contains(name), "the main window has no \(name) in \(names)")
                }
            }
            // List is only the list; Both and Map have Map | Chart (#798), and
            // Chart is the period's chart in the map's place.
            let chartName = L("Chart of the period, bar by bar. Click a bar, or drag across bars, to show only that time.")
            let savedLayout = connections.layout
            connections.layout = .list
            Check.test("Connections › List shows no chart and no Map | Chart\(language)") {
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                let names = namesNow()
                Check.expectFalse(names.contains(L("Map or chart")), "List has the Map or chart switch")
                Check.expectFalse(names.contains(chartName), "List has a chart")
            }
            for layout in [ConnectionsViewModel.Layout.both, .map] {
                connections.layout = layout
                connections.pane = .chart
                checkMain("Connections › \(layout.label) › Chart")
                Check.test("Connections › \(layout.label) has Map | Chart, and Chart in the map's place\(language)") {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                    let names = namesNow()
                    Check.expectTrue(names.contains(L("Map or chart")), "no Map or chart switch in \(names)")
                    Check.expectTrue(names.contains(chartName), "no chart in \(names)")
                }
                connections.pane = .map
            }
            connections.layout = savedLayout
            // What the list is narrowed to, in words (#798): each part's ✕
            // says what it removes, and Show everything is named.
            connections.search = "zz"
            checkMain("Connections, narrowed")
            Check.test("Connections' Showing only line names its ✕ and Show everything\(language)") {
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                let names = namesNow()
                for name in [L("Remove %@", L("“%@”", "zz")), L("Show everything")] {
                    Check.expectTrue(names.contains(name), "no \(name) in \(names)")
                }
            }
            connections.search = ""
            // AppKit's own buttons, named by the app (#621): read in the
            // language shown.
            Check.test("The sidebar's button and the search's glass read in the language shown\(language)") {
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                let names = namesNow()
                for name in [L("Sidebar"), L("Search")] {
                    Check.expectTrue(names.contains(name), "the main window has no \(name) in \(names)")
                }
            }
            // Each of the View's layouts (#524), and Ads and Trackers' Sites and Apps.
            main.show(.history)
            for layout in ChartLayout.allCases {
                historyModel.layout = layout
                checkMain("Usage History › \(layout.label)")
            }
            main.show(.ads)
            for tab in AdsViewModel.Tab.allCases {
                main.ads.select(tab)
                checkMain("Ads and Trackers › \(tab.label)")
            }
            main.ads.select(.overview)
            for rule in made { model.firewall.remove(rule) }
            for rule in madeAds { model.firewall.remove(rule) }
            for layout in ChartLayout.allCases {
                adsModel.layout = layout
                for grouping in PopoverAdsGrouping.allCases where layout.showsList || grouping == .sites {
                    adsModel.grouping = grouping
                    checkMain("Ads and Trackers › \(layout.label) › \(grouping.label)")
                }
            }
            adsModel.grouping = .sites
            // A row chosen (#536): its chip's ✕ says what it does. The rows
            // themselves, open and chosen, are checked with real data by
            // `make design-shots ONLY=ads-audit`.
            adsModel.layout = .both
            adsModel.select(.init(grouping: .sites, parent: "doubleclick.net", title: "doubleclick.net"))
            checkMain("Ads and Trackers › a row chosen")
            adsModel.clearSelection()
            // VoiceOver on the total (#402, checked for #525): VO-→ reads the
            // total, then its ⓘ, "Blocked by each list" with each list's
            // count, which VO-Space opens.
            Check.test("Ads and Trackers reads its total, then each list's share, which VO-Space opens\(language)") {
                // On, so there's a total rather than "Ad blocking is off".
                let lists = model.firewall.lists
                model.firewall.lists = [.ads]
                defer {
                    model.firewall.lists = lists
                    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                }
                main.ads.select(.overview)
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                let order = AccessibilityAudit.readingOrderOwnWindow(titled: window.title)
                let total = "AXStaticText: " + L("%@ blocked", adsModel.report.total.formatted())
                guard let at = order.firstIndex(of: total) else {
                    Check.expectTrue(false, "no \(total) in \(order)")
                    return
                }
                let next = order.indices.contains(at + 1) ? order[at + 1] : "nothing"
                Check.expectTrue(next.hasPrefix("AXButton: " + L("Blocked by each list")),
                                 "after the total VoiceOver reads \(next)")
                func popoverShown() -> Bool {
                    NSApp.windows.contains { String(describing: type(of: $0)).contains("Popover") && $0.isVisible }
                }
                let name = L("Blocked by each list")
                Check.expectTrue(AccessibilityAudit.pressOwnWindow(titled: window.title, named: name),
                                 "VO-Space can't press \(name)")
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                Check.expectTrue(popoverShown(), "VO-Space didn't open each list's share")
                _ = AccessibilityAudit.pressOwnWindow(titled: window.title, named: name)
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            }
            // The same View as Connections' (#524): named View, each segment
            // by its layout, in the language shown.
            Check.test("Usage History's and Ads and Trackers' View reads as Connections'\(language)") {
                for section in [MainSection.history, .ads] {
                    main.show(section)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                    let names = namesNow()
                    for name in [L("View")] + ChartLayout.allCases.map(\.label) {
                        Check.expectTrue(names.contains(name), "\(section.title) has no \(name) in \(names)")
                    }
                }
            }
            // Both is the list and the chart side by side, as in Connections
            // (#534): the list's Show and the chart are both there to read.
            historyModel.layout = .both
            Check.test("Usage History's Both has the list and the chart\(language)") {
                main.show(.history)
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                let names = namesNow()
                let chart = [L("Usage by hour"), L("Usage by day"), L("Usage by month")]
                Check.expectTrue(names.contains(L("Show")) && names.contains { chart.contains($0) },
                                 "Both doesn't have the list's Show and the chart: \(names)")
            }
            main.show(.live)
            checkMain("Live")
            // Live across the whole width, and the speed test where it is
            // however many apps come and go (#825): in its own column at full
            // screen, under a list of fixed height at the narrowest.
            if code == Localization.source, SpeedTestRunner.isAvailable {
                Check.test("Live fills the window and its speed test stays put as apps come and go") {
                    let size = window.contentRect(forFrameRect: window.frame).size
                    defer { window.setContentSize(size) }
                    func testNow() -> CGRect? {
                        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                        return AccessibilityAudit.framesOwnWindow(titled: window.title)
                            .first { $0.name == L("Test Now") }?.frame
                    }
                    func apps(_ count: Int) {
                        let entries = (0..<count).map { (id: "app\($0)", name: "App \($0)", bundlePath: String?.none,
                                                          bytesIn: Int64(1_000 * ($0 + 1)), bytesOut: Int64(100)) }
                        let now = Date()
                        model.live.recordApps(entries.map { ($0.id, $0.name, $0.bundlePath, 0, 0) }, at: now - 1)
                        model.live.recordApps(entries, at: now)
                    }
                    for (width, columns) in [(CGFloat(1400), true), (window.contentMinSize.width, false)] {
                        window.setContentSize(NSSize(width: width, height: 880))
                        apps(2)
                        guard let few = testNow() else {
                            Check.expectTrue(false, "no Test Now at \(width) points wide")
                            continue
                        }
                        apps(20)
                        let many = testNow() ?? .zero
                        Check.expectEqual(Double(many.minY), Double(few.minY), accuracy: 0.5)
                        Check.expectEqual(Double(many.minX), Double(few.minX), accuracy: 0.5)
                        if columns {
                            // In the column at the right, not under a list
                            // capped at 900 points.
                            let column = window.frame.maxX - 20 - LivePageMetrics.testColumnWidth
                            Check.expectTrue(few.minX > column - 10,
                                             "Test Now starts at \(few.minX), the column at \(column)")
                        }
                    }
                    model.live.recordApps([], at: Date() + 120)
                }
            }
            main.show(.network)
            checkMain("Network")
            main.show(.settings)
            // With its Updates section (#710), as in a copy that updates itself.
            model.updates.previewsSettings = true
            checkMain("Settings")
            Check.test("Settings' update switches are named\(language)") {
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                let names = namesNow()
                for name in [L("Check Now"), L("Check for updates automatically"), L("Install updates automatically"),
                             L("Get beta versions")] {
                    Check.expectTrue(names.contains(name), "Settings has no \(name) in \(names)")
                }
            }
            // Settings across the whole width (#825): a row's control at the
            // window's right, not at 720 points.
            if code == Localization.source {
                Check.test("Settings fills the window's width") {
                    let size = window.contentRect(forFrameRect: window.frame).size
                    defer { window.setContentSize(size) }
                    window.setContentSize(NSSize(width: 1400, height: 880))
                    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                    let frames = AccessibilityAudit.framesOwnWindow(titled: window.title)
                    // macOS's grouped form stops near 700 points, centred;
                    // only from macOS 15 are the rows drawn edge to edge.
                    guard #available(macOS 15.0, *) else { return }
                    // A button, a switch and a menu alike.
                    for name in [L("Check Now"), L("Start at login"), L("Language")] {
                        let end = frames.filter { $0.name == name }.map(\.frame.maxX).max() ?? 0
                        Check.expectTrue(end > window.frame.maxX - 60,
                                         "\(name) ends at \(end), the window at \(window.frame.maxX)")
                    }
                }
            }
            // A new version waiting on its card in the sidebar, above Settings
            // (#520): the ✕ says what it does, and each button reads as it's
            // labelled.
            let height = window.frame.height
            model.updates.preview(.available("9.9.9"))
            checkMain("Settings, with an update waiting")
            Check.test("The update card's buttons are named\(language)") {
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                let names = namesNow()
                for name in [L("Install & Restart"), L("What's New"), L("Remind Me Later")] {
                    Check.expectTrue(names.contains(name), "the update card has no \(name) in \(names)")
                }
            }
            // Waiting to install by itself, and installed (#710).
            model.updates.preview(.ready("9.9.9"))
            checkMain("Settings, with an update about to install")
            Check.test("The card of an update about to install has its buttons\(language)") {
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                let names = namesNow()
                for name in [L("Restart Now"), L("What's New"), L("Hide")] {
                    Check.expectTrue(names.contains(name), "the card has no \(name) in \(names)")
                }
            }
            model.updates.preview(.updated("9.9.9"))
            checkMain("Settings, with an update that installed by itself")
            Check.test("The card of an update that installed has its buttons\(language)") {
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                let names = namesNow()
                for name in [L("What's New"), L("Hide this")] {
                    Check.expectTrue(names.contains(name), "the card has no \(name) in \(names)")
                }
                Check.expectFalse(names.contains(L("Restart Now")), "nothing left to restart for")
            }
            // It grew by the card's height and stayed that way (#710).
            Check.test("The update card leaves the window's height alone\(language)") {
                Check.expectEqual(window.frame.height, height)
            }
            model.updates.preview(nil)
            // The welcome window (#134), with its update switch (#710).
            Check.test("The welcome window names everything VoiceOver reads\(language)") {
                let welcome = WelcomeWindowController(filter: model.filter, wifiNames: model.wifiNames,
                                                      updates: model.updates)
                welcome.window.placeOutOfSight()
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                defer { welcome.window.orderOut(nil) }
                guard let problems = AccessibilityAudit.auditOwnWindow(titled: welcome.window.title, symbols: symbols) else {
                    Check.expectTrue(false, "couldn't read the welcome window's accessibility tree")
                    return
                }
                for problem in problems { Check.expectTrue(false, problem.description) }
                let names = AccessibilityAudit.namesOwnWindow(titled: welcome.window.title)
                Check.expectTrue(names.contains(L("Install updates automatically")), "no update switch in \(names)")
            }
            // With Dock chosen, and so its Dock icon choice showing (#523).
            let placement = AppPlacementSetting.shared.placement
            let iconInDock = AppPlacementSetting.shared.dockIconInDock
            AppPlacementSetting.shared.placement = .dock
            AppPlacementSetting.shared.dockIconInDock = .speeds
            checkMain("Settings, with Dock chosen")
            // Its Appearance (#807): only while the Dock icon is the speeds.
            if code == Localization.source { Check.test("Appearance is there only while the Dock icon is Speeds") {
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                func choices(_ outline: [String]) -> [String] {
                    outline.filter { line in
                        DockAppearance.allCases.contains { line.hasPrefix("AXRadioButton name=\($0.label) ") }
                    }
                }
                let shown = outlineNow()
                Check.expectEqual(choices(shown).count, 3, "no System · Light · Dark with Speeds: \(shown)")
                AppPlacementSetting.shared.dockIconInDock = .appIcon
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                Check.expectEqual(choices(outlineNow()), [], "an Appearance choice with App icon")
                AppPlacementSetting.shared.dockIconInDock = .speeds
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            } }
            if code == Localization.source { Check.test("Dock icon is there only while Dock or Both is chosen") {
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                // Its two choices, as the segments the outline lists.
                func choices(_ outline: [String]) -> [String] {
                    outline.filter { $0.hasPrefix("AXRadioButton name=Speeds ") || $0.hasPrefix("AXRadioButton name=App icon ") }
                }
                let shown = outlineNow()
                Check.expectEqual(choices(shown).count, 2, "no Dock icon choice with Dock chosen: \(shown)")
                AppPlacementSetting.shared.placement = .both
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                let both = outlineNow()
                Check.expectEqual(choices(both).count, 2, "no Dock icon choice with Both chosen: \(both)")
                AppPlacementSetting.shared.placement = .menuBar
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                Check.expectEqual(choices(outlineNow()), [], "a Dock icon choice with Menu bar chosen")
            } }
            AppPlacementSetting.shared.placement = placement
            AppPlacementSetting.shared.dockIconInDock = iconInDock
            for section in MainSection.features {
                main.show(section)
                main.showSettings()
                checkMain("\(section.title) › settings")
            }
            // Enhanced ad blocking on (#685): its apps, an app left alone,
            // waiting for approval with Try Again; then its two sheets.
            let enhancedBefore = model.firewall.enhancedBlocking
            model.firewall.enhancedBlocking.isOn = true
            model.firewall.enhancedBlocking.pinnedApps = ["com.example.pinning"]
            model.enhanced.preview(.needsApproval)
            main.show(.ads)
            main.showSettings()
            checkMain("Ads and Trackers › settings, Enhanced ad blocking waiting for approval")
            model.enhanced.preview(.on)
            checkMain("Ads and Trackers › settings, Enhanced ad blocking on")
            for (title, sheet) in [("Turn on Enhanced ad blocking", AnyView(EnhancedApprovalSheet(enhanced: model.enhanced))),
                                   ("Apps it reaches", AnyView(EnhancedAppsSheet(enhanced: model.enhanced,
                                                                                 firewall: model.firewall)))] {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520), styleMask: [.titled],
                                      backing: .buffered, defer: false)
                window.title = title + language
                window.contentView = NSHostingView(rootView: sheet.localizedRoot())
                check(window, title + language)
            }
            model.firewall.enhancedBlocking = enhancedBefore
            model.enhanced.preview(.off)
            // The speed test's styles are in Live's settings (#436, #812).
            if code == Localization.source { Check.test("Live's settings read each speed test style's picture as one button") {
                main.show(.live)
                main.showSettings()
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                let outline = outlineNow()
                for style in ["Card", "Compact"] {
                    Check.expectTrue(outline.contains { $0.hasPrefix("AXButton name=\(style) ") },
                                     "no \(style) button in \(outline)")
                }
                // The pictures' sample card has a Test Again button; the page
                // has none of its own, so finding one means the sample leaked.
                Check.expectTrue(!outline.contains { $0.contains("name=Test Again ") },
                                 "the picture's sample buttons reach VoiceOver: \(outline)")
            } }
            main.show(.history)
            main.windowWillClose()
            window.orderOut(nil)

            // Where the map's lines start, as hovering its ring shows (#231),
            // in a main window of its own with a Mac that knows its place.
            if code == Localization.source { Check.test("VoiceOver reads where the map's lines start, and why") {
                let located = ConnectionsViewModel(monitor: model, defaults: defaults, homeSources: .init(
                    location: { $0("LB") }, internetAddress: { $0(nil) }, region: { "US" }))
                located.layout = .map
                let locatedMain = MainWindowController(model: model, history: HistoryViewModel(monitor: model),
                                                       connections: located, ads: AdsViewModel(monitor: model))
                locatedMain.window.placeOutOfSight()
                locatedMain.windowDidShow()
                locatedMain.show(.connections)
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                let names = AccessibilityAudit.namesOwnWindow(titled: locatedMain.window.title)
                Check.expectTrue(names.contains { $0.hasPrefix("World map of") && $0.hasSuffix(" Your Mac, in Lebanon (from Location): the lines start there.") },
                                 "the map doesn't say where its lines start: \(names.filter { $0.contains("map") })")
                locatedMain.windowWillClose()
                locatedMain.window.orderOut(nil)
            } }
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
                // VO-→ into them (checked for #525): the description, then
                // the links, then the licence.
                let credits = AccessibilityAudit.readingOrderOwnWindow(titled: window.title)
                    .first { $0.hasPrefix("AXTextArea: \(AboutPanel.creditsName), ") } ?? ""
                let parts = [L("Live network speed in your menu bar, and which app used your data."), L("Website"),
                             L("What's new"), L("Source code"), L("Free and open source, under the Apache 2.0 licence.")]
                let places = parts.map { credits.range(of: $0)?.lowerBound }
                Check.expectTrue(!places.contains(nil) && places.map { $0! } == places.map { $0! }.sorted(),
                                 "the credits don't read description, links, licence: \(credits)")
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
            // The Live line has no caption on screen (#823), so its spoken
            // name is all that says it's Live: "Live, download …, upload …".
            // This guards that name only: the button's label hides its
            // texts from Accessibility, so a caption can't be seen from here.
            // The speeds change as it reads, so only the words before them
            // are compared.
            Check.test("the popover's Live line is named Live without a caption (#823)\(language)") {
                guard model.popoverLayout.showsLive else {
                    Check.expectTrue(false, "the popover's layout hides Live, so its line can't be checked")
                    return
                }
                popover.placeOutOfSight()
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                let names = [L("Live, no speeds yet"),
                             L("Live, download %@, upload %@", "\u{1}", "\u{1}").components(separatedBy: "\u{1}")[0]]
                let order = AccessibilityAudit.readingOrderOwnWindow(titled: popover.title)
                Check.expectTrue(order.contains { item in names.contains { item.hasPrefix("AXButton: \($0)") } },
                                 "the Live line isn't named \(names): \(order.prefix(6))")
                popover.orderOut(nil)
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
