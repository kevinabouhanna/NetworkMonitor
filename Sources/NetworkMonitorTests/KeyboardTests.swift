import AppKit
import FirewallPolicy
import SwiftUI
import NetworkMonitorCore

/// Every window toured with Tab as with Keyboard navigation on, and with
/// VoiceOver's ears (#455): each stop named, each control one stop, every
/// control reached, Tab coming back round; and what the keys do in the
/// sidebar, a switch and search. Built here with empty data; `make
/// design-shots KEYBOARD=1` tours the same windows with rows in their lists.
func runKeyboardTests() {
    Check.suite("Keyboard and VoiceOver") {
        OutOfSight.startApp()
        KeyboardTour.start()
        defer { KeyboardTour.stop() }

        func place(_ window: NSWindow) {
            window.placeOutOfSight()
        }
        func settle(_ seconds: TimeInterval = 0.6) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func expectNoProblems(_ window: NSWindow, _ name: String) {
            var tour = KeyboardTour.walk(window)
            var problems = KeyboardTour.problems(in: window, tour)
            // A section still being laid out gives a short tour: with the Mac
            // busy (builds, VMs), Connections' was two stops, Tab ran out after
            // Settings, and 20 of its controls "can't be reached" (#567). So
            // look again, waiting longer each time, before calling it a
            // problem. A real one is still there 7 s later.
            for wait in [1.0, 2.0, 4.0] {
                guard !problems.isEmpty else { break }
                settle(wait)
                tour = KeyboardTour.walk(window)
                problems = KeyboardTour.problems(in: window, tour)
            }
            for problem in problems { Check.expectTrue(false, "\(name): \(problem)") }
            if !problems.isEmpty {
                print("      \(name), Tab by Tab:\n" + tour.description.split(separator: "\n").map { "        " + $0 }.joined(separator: "\n"))
                for stop in tour.stops where stop.role == nil {
                    print("      \(stop.responder) at \(stop.frame) has round it:")
                    KeyboardTour.surroundings(of: stop, in: window).forEach { print("        \($0)") }
                }
            }
        }

        // The check itself: a window with each problem in it must fail, or a
        // pass below means nothing.
        func faultyProblems(_ view: some View, _ title: String) -> [String] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.title = title
            window.contentView = NSHostingView(rootView: view)
            place(window)
            settle(0.4)
            defer { window.orderOut(nil) }
            return KeyboardTour.problems(in: window, KeyboardTour.walk(window))
        }
        Check.test("the tour finds a control that's two stops and a stop with no name") {
            let problems = faultyProblems(FaultyKeyboardView(), "Faulty keyboard")
            Check.expectTrue(problems.contains { $0.contains("one control, two stops") },
                             "missed the switch whose choices are stops too: \(problems)")
            Check.expectTrue(problems.contains { $0.contains("nothing VoiceOver can read out") },
                             "missed the stop with no name: \(problems)")
        }
        // A window of its own: beside other controls, Tab's order by where
        // they sit put one between the rows now and then.
        Check.test("the tour finds a list's rows that are each a stop (#546)") {
            let rows = VStack { ForEach(0..<3) { _ in Button("Expand") {}.buttonStyle(.plain) } }
            let problems = faultyProblems(rows, "Faulty list")
            Check.expectTrue(problems.contains { $0.contains("a list's rows each a stop") },
                             "missed the rows that are each a stop: \(problems)")
        }

        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("keyboard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Check.defaults("keyboard")
        let store = UsageStore(storeURL: dir.appendingPathComponent("usage.json"))
        let metering = MeteringController(store: store,
                                          journal: SuppressionJournal(url: dir.appendingPathComponent("journal.json")),
                                          suppressors: [], defaults: defaults)
        let model = MonitorViewModel(store: store, metering: metering)
        let connections = ConnectionsViewModel(monitor: model, defaults: defaults)
        let historyModel = HistoryViewModel(monitor: model, defaults: defaults)
        let adsModel = AdsViewModel(monitor: model, defaults: defaults)
        let main = MainWindowController(model: model, history: historyModel,
                                        connections: connections, ads: adsModel)
        let window = main.window
        place(window)
        main.windowDidShow()
        settle(0.8)

        // One window, each section shown in turn: Tab reaches what each
        // brings in, not only the first one's (#455).
        for section in MainSection.allCases {
            Check.test("the main window › \(section.rawValue): each stop named, once, every control reached") {
                main.show(section)
                settle(0.8)
                expectNoProblems(window, section.rawValue)
            }
            guard section != .settings else { continue }
            Check.test("the main window › \(section.rawValue) › settings: each stop named, once, every control reached") {
                main.showSettings()
                settle(0.8)
                expectNoProblems(window, "\(section.rawValue) settings")
            }
        }

        // Rules (#592), with rules in them: each rule's menu, Show and −
        // are stops of their own, named after the rule, and the bar above
        // and the line below are reached.
        Check.test("the main window › connections and ads › rules: each stop named, once, every control reached") {
            let rule = FirewallRule(subject: .company, key: "Meta", title: "Meta", action: .block)
            let adRule = AdRule(kind: .alwaysBlock, site: "tracker.example")
            model.firewall.add(rule)
            model.firewall.add(adRule)
            defer {
                model.firewall.remove(rule)
                model.firewall.remove(adRule)
                connections.showsRules = false
                main.ads.select(.overview)
            }
            main.show(.connections)
            connections.showsRules = true
            settle(0.8)
            expectNoProblems(window, "connections rules")
            main.show(.ads)
            main.ads.select(.rules)
            settle(0.8)
            expectNoProblems(window, "ads rules")
        }

        Check.test("the sidebar is one stop, named, that ↑ and ↓ move through") {
            main.show(.history)
            settle(0.8)
            window.makeFirstResponder(nil)
            KeyboardTour.press(.tab, in: window)
            let stop = KeyboardTour.focused(in: window)
            Check.expectEqual(stop?.name, L("Sections"), "Tab's first stop: \(String(describing: stop))")
            Check.expectEqual(stop?.value, MainSection.history.title, "the sidebar doesn't say which section")
            KeyboardTour.press(.down, in: window)
            Check.expectEqual(main.section, .connections, "↓ didn't move to Connections")
            Check.expectEqual(KeyboardTour.focused(in: window)?.value, MainSection.connections.title,
                              "the sidebar doesn't say the section ↓ chose")
            KeyboardTour.press(.up, in: window)
            Check.expectEqual(main.section, .history, "↑ didn't move back to Usage History")
            let stops = KeyboardTour.walk(window).stops
            Check.expectTrue(!stops.contains { $0.name == MainSection.connections.title },
                             "a section in the sidebar is a Tab stop of its own: \(stops)")
        }

        Check.test("a switch is one stop whose choice ← and → change") {
            main.show(.history)
            settle(0.8)
            let stops = KeyboardTour.walk(window).stops
            guard let index = stops.firstIndex(where: { $0.name == L("Show") && $0.role == "AXTabGroup" }) else {
                Check.expectTrue(false, "no Show switch among \(stops)")
                return
            }
            window.makeFirstResponder(nil)
            for _ in 0...index { KeyboardTour.press(.tab, in: window, settle: 0.05) }
            let before = historyModel.tab
            Check.expectEqual(KeyboardTour.focused(in: window)?.value, before.label, "VoiceOver doesn't hear the choice")
            KeyboardTour.press(.right, in: window)
            Check.expectTrue(historyModel.tab != before, "→ didn't change the choice")
            Check.expectEqual(KeyboardTour.focused(in: window)?.value, historyModel.tab.label,
                              "VoiceOver doesn't hear the new choice")
            KeyboardTour.press(.left, in: window)
            Check.expectEqual(historyModel.tab, before, "← didn't change it back")
        }

        // The toolbar's View in Usage History and Ads and Trackers, and Ads'
        // Sites · Apps (#524, checked for #525): one stop each, whose choice
        // ← and → change, and VoiceOver hears the new one.
        // Connections' View and each Period too, the same control.
        let switches: [(section: MainSection, name: String, role: String, choice: () -> String)] = [
            (.history, L("View"), "AXRadioGroup", { historyModel.layout.label }),
            (.ads, L("View"), "AXRadioGroup", { adsModel.layout.label }),
            (.ads, L("Group by"), "AXTabGroup", { adsModel.grouping.label }),
            (.connections, L("View"), "AXRadioGroup", { connections.layout.label }),
            (.history, L("Period"), "AXRadioGroup", { historyModel.scale.label }),
        ]
        for control in switches {
            Check.test("\(control.section.rawValue) › \(control.name) is one stop whose choice ← and → change") {
                historyModel.layout = .both
                adsModel.layout = .both
                connections.layout = .both
                historyModel.scale = .day
                main.show(control.section)
                settle(0.8)
                let stops = KeyboardTour.walk(window).stops
                let matching = stops.indices.filter { stops[$0].name == control.name && stops[$0].role == control.role }
                guard matching.count == 1, let index = matching.first else {
                    Check.expectTrue(false, "not one \(control.name) stop among \(stops)")
                    return
                }
                window.makeFirstResponder(nil)
                for _ in 0...index { KeyboardTour.press(.tab, in: window, settle: 0.05) }
                let before = control.choice()
                Check.expectEqual(KeyboardTour.focused(in: window)?.value, before, "VoiceOver doesn't hear the choice")
                KeyboardTour.press(.right, in: window)
                Check.expectTrue(control.choice() != before, "→ didn't change the choice")
                Check.expectEqual(KeyboardTour.focused(in: window)?.value, control.choice(),
                                  "VoiceOver doesn't hear the new choice")
                KeyboardTour.press(.left, in: window)
                Check.expectEqual(control.choice(), before, "← didn't change it back")
            }
        }

        Check.test("⌘F opens search, Escape clears it then closes it, and focus goes back where it was") {
            main.show(.history)
            settle(0.8)
            window.makeFirstResponder(nil)
            for _ in 0..<3 { KeyboardTour.press(.tab, in: window, settle: 0.05) }
            let before = KeyboardTour.focused(in: window)
            main.beginSearch()
            settle(0.8)
            let search = main.history.search
            Check.expectTrue(search.field.currentEditor() != nil, "⌘F didn't put the cursor in search")
            search.field.currentEditor()?.insertText("Sa")
            settle(0.3)
            KeyboardTour.press(.escape, in: window)
            Check.expectEqual(search.field.stringValue, "", "the first Escape didn't clear the search")
            Check.expectTrue(search.isOpen, "the first Escape closed search rather than clearing it")
            KeyboardTour.press(.escape, in: window)
            Check.expectTrue(!search.isOpen, "the second Escape didn't close search")
            let after = KeyboardTour.focused(in: window)
            Check.expectTrue(after != nil && after?.name == before?.name && after?.role == before?.role,
                             "focus went to \(String(describing: after)), not back to \(String(describing: before))")
        }
        main.windowWillClose()
        window.orderOut(nil)

        let popover = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
                               styleMask: [.titled], backing: .buffered, defer: false)
        popover.title = "Popover keyboard"
        popover.contentView = NSHostingView(rootView: MenuBarPopoverView(
            model: model, onSettings: {}, onHistory: {}, onConnections: {}, onAds: {}))
        place(popover)
        for section in PopoverSection.allCases {
            Check.test("the popover › \(section.rawValue): each stop named, once, every control reached") {
                model.popoverSection = section
                settle(0.6)
                expectNoProblems(popover, "popover \(section.rawValue)")
            }
        }
        model.popoverSection = .today
        popover.orderOut(nil)
    }
}

/// One of each problem the tour looks for: a switch whose choices are stops
/// as well as the switch, and a focusable picture with no name.
private struct FaultyKeyboardView: View {
    var body: some View {
        VStack {
            HStack {
                Button("One") {}.buttonStyle(.plain)
                Button("Two") {}.buttonStyle(.plain)
            }
            .padding(4)
            .focusable()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Switch")
            Button {} label: { Image(systemName: "gearshape.fill") }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
        }
    }
}
