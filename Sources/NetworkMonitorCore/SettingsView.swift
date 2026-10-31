import AppKit
import SwiftUI

// Settings' panes, each a grouped form in the shape of System Settings: labels on
// the left, controls on the right, sections with a line of explanation beneath.
// `SettingsWindowController` puts them behind a toolbar; History is `HistoryView`.
//
// Quit is deliberately not here. It is a menu bar app, and the menu bar is where
// a Mac user looks to quit one — it stays on the status item's right-click menu.

/// Width every pane shares, History included, so switching panes only ever
/// changes the window's height (#61). Between the 648 pt the forms had and the
/// 768 pt History had.
enum SettingsMetrics {
    static let paneWidth: CGFloat = 720
}

// MARK: - General

struct GeneralSettingsPane: View {
    @ObservedObject var model: MonitorViewModel
    @ObservedObject var speedTest: SpeedTestController
    @ObservedObject var colors: MenuBarColors
    @ObservedObject var wifiNames: WiFiNames
    @ObservedObject var state: SettingsPaneState

    init(model: MonitorViewModel, state: SettingsPaneState) {
        self.model = model
        self.speedTest = model.speedTest
        self.colors = model.menuBarColors
        self.wifiNames = model.wifiNames
        self.state = state
    }

    var body: some View {
        Form {
            // Each row's explanation is behind an ⓘ beside it (#189).
            Section {
                ExplainedRow("Start at login",
                             "Opens NetworkMonitor automatically when you log in. Quitting still quits "
                             + "it — it won't reopen until your next login.") {
                    Toggle("Start at login", isOn: $state.launchAtLogin)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: state.launchAtLogin) { enabled in apply(enabled) }
                }
            }

            // One choice for every speed, so the menu bar and the speed test never
            // show the same line in two different units.
            Section {
                // In LabeledContent, so the switch sits at the row's right edge
                // like every other control here. A segmented Picker sized to fit
                // keeps its label, and stopped short of the edge (#51).
                ExplainedRow("Show speeds in",
                             "In the menu bar and the speed test. Data you've used is always counted in "
                             + "MB and GB, the way data plans are sold.") {
                    Picker("Show speeds in", selection: $speedTest.unit) {
                        ForEach(SpeedUnit.allCases) { unit in
                            Text(unit.label).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            // Wi-Fi names (#85), for anyone who said "not now" in the welcome
            // window or was asked before it existed (#134). Once on, there's
            // nothing to show.
            if wifiNames.access != .allowed {
                Section {
                    WiFiNamesRow(wifiNames: wifiNames)
                }
            }

            // The live rates only (#45). A speed test's colours follow from
            // these, so the two never look alike; they're shown, not offered.
            Section {
                ColorPicker("Download", selection: binding(\.download), supportsOpacity: false)
                ColorPicker("Upload", selection: binding(\.upload), supportsOpacity: false)
                ExplainedRow("During a speed test",
                             "A speed test shows its figures in its own colors, kept clear of these, so "
                             + "they're never taken for live rates.") {
                    HStack(spacing: 6) {
                        Text("↓")
                        ColorSwatch(color: colors.test.down)
                        Text("↑").padding(.leading, 4)
                        ColorSwatch(color: colors.test.up)
                    }
                    .foregroundStyle(.secondary)
                }
                // Always there, dimmed at the defaults. A row that came and went
                // changed the pane's height from the colour panel, which has the
                // focus while a colour is picked, and the window only caught up
                // on the next click in Settings.
                HStack {
                    Spacer()
                    Button("Use Default Colors") { colors.reset() }
                        .disabled(colors.isDefault)
                }
            } header: {
                Text("Menu bar colors")
            }

            Section {
                ExplainedRow("Counting since",
                             "What this connection has used, per app, all the time. The totals start over "
                             + "when you join a different network, and at midnight. History keeps every "
                             + "hour of it.") {
                    Text(model.countingSince, format: .dateTime.hour().minute())
                        .monospacedDigit()
                }
                // Stated, not offered. There is nothing to choose here — the
                // point is that the app handles it — but a reader who notices the
                // list updating every 3 s instead of every 1 s deserves to know
                // that is deliberate and costs them no accuracy.
                LabeledContent("Sampling") {
                    switch model.profile {
                    case .performance:
                        Label("Every second, plugged in", systemImage: "bolt.fill")
                    case .balanced:
                        Label("Every 3 seconds on battery, same totals", systemImage: "battery.75")
                    case .saver:
                        Label("Every 10 seconds in Low Power Mode, same totals", systemImage: "leaf.fill")
                    }
                }
                // One button, not two. Usage is bucketed per network internally,
                // but the popover never names the network, so "this network" vs
                // "all networks" had no visible referent and only caused doubt.
                LabeledContent("Start the totals over") {
                    Button("Reset Now") { model.resetCurrentNetwork() }
                }
            } header: {
                Text("Popover totals")
            }

            if let error = state.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .settingsForm()
    }

    /// A colour well's binding. Whatever space the colour panel hands back, the
    /// menu bar gets the sRGB colour that is saved.
    private func binding(_ line: ReferenceWritableKeyPath<MenuBarColors, NSColor>) -> Binding<CGColor> {
        Binding(get: { colors[keyPath: line].cgColor },
                set: { picked in
                    guard let color = NSColor(cgColor: picked) else { return }
                    colors[keyPath: line] = MenuBarColors.normalized(color)
                })
    }

    private func apply(_ enabled: Bool) {
        do {
            if enabled { try LoginItem.enable() } else { try LoginItem.disable() }
            state.errorMessage = nil
        } catch {
            state.errorMessage = error.localizedDescription
            // Snap the switch back so it never claims a state that did not stick.
            state.launchAtLogin = LoginItem.isEnabled
        }
    }
}

/// A colour shown, not offered: shaped like a colour well, smaller, with
/// nothing to press.
private struct ColorSwatch: View {
    let color: NSColor

    var body: some View {
        Capsule()
            .fill(Color(nsColor: color))
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.35)))
            .frame(width: 30, height: 16)
    }
}

// MARK: - Speed Test

/// The speed test, runnable from Settings as well as from the popover's gauge,
/// with its one setting beside it.
struct SpeedTestSettingsPane: View {
    @ObservedObject var speedTest: SpeedTestController

    var body: some View {
        Form {
            Section {
                if SpeedTestRunner.isAvailable {
                    SpeedTestPanel(speedTest: speedTest)
                } else {
                    Label("This Mac has no networkQuality, which the test runs on.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                SettingsFootnote("Runs macOS's built-in networkQuality, only when you start it: "
                                 + "download first, then upload. Every run measures afresh, so it "
                                 + "uses data each time — typically 50–500 MB, more on a very "
                                 + "fast line. Speeds use the unit chosen in General.")
            }

            Section {
                // At the row's right edge; see General's speed unit.
                LabeledContent("Show the test in the popover as") {
                    Picker("Show the test in the popover as", selection: $speedTest.style) {
                        ForEach(SpeedTestStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            } footer: {
                SettingsFootnote(speedTest.style == .card
                                 ? "A card with a dial and every figure, in place of your apps."
                                 : "Two lines above your apps, which stay in view.")
            }
        }
        .settingsForm()
    }
}

/// The test inside Settings: a button to start it, then the same dial and figures
/// the popover's card shows.
private struct SpeedTestPanel: View {
    @ObservedObject var speedTest: SpeedTestController

    var body: some View {
        VStack(spacing: 10) {
            switch speedTest.phase {
            case .idle:
                HStack(spacing: 12) {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 26))
                        .foregroundStyle(SpeedTestPalette.download)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Test your internet speed").font(.system(size: 13, weight: .semibold))
                        Text("Download, upload, ping and jitter, measured now.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Test Now") { speedTest.run() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.vertical, 4)
            case .confirming(let estimate):
                HStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(.orange)
                    Text(SpeedTestPalette.meteredNote(estimate))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Cancel") { speedTest.dismiss() }
                    Button("Run Anyway") { speedTest.confirm() }.keyboardShortcut(.defaultAction)
                }
            case .running(let startedAt):
                CardBody(live: speedTest.live, result: nil, startedAt: startedAt, unit: speedTest.unit)
                    .frame(width: 320)
                HStack { Spacer(); Button("Stop") { speedTest.dismiss() } }
            case .finished(let result):
                CardBody(live: speedTest.live, result: result, startedAt: nil, unit: speedTest.unit)
                    .frame(width: 320)
                HStack {
                    Spacer()
                    Button("Done") { speedTest.dismiss() }
                    Button("Test Again") { speedTest.run() }.keyboardShortcut(.defaultAction)
                }
            case .failed(let message):
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Speed test didn't finish").font(.system(size: 12, weight: .semibold))
                        Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Spacer()
                    Button("Done") { speedTest.dismiss() }
                    Button("Try Again") { speedTest.run() }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Hotspot

struct HotspotSettingsPane: View {
    /// Observed directly: the controller publishes its own state, and reaching it
    /// through a `let` on the view model would neither give a writable binding
    /// for the switch nor redraw when the verdict changes.
    @ObservedObject var metering: MeteringController
    @ObservedObject var state: SettingsPaneState
    /// What stops any app's updater on a hotspot, at the network (#98).
    @ObservedObject var filter: FilterController

    var body: some View {
        Form {
            Section {
                // One switch for the whole feature, Low Data Mode included: it
                // serves the same purpose, and a second switch would only ask the
                // user to make the same decision twice.
                Toggle("Stop apps updating on hotspots", isOn: $metering.isEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: metering.isEnabled) { enabled in
                        // Switching it on is the moment to ask for the helper —
                        // the one thing here that needs a password. Deferred a
                        // turn so the switch has finished drawing before the
                        // administrator dialog takes over.
                        guard enabled else { return }
                        DispatchQueue.main.async { askForHelper() }
                    }
                // The verdict, always shown: the commonest confusion with a
                // feature like this is not knowing whether it decided the
                // connection counts, and the answer is one line long. Green when
                // it has decided the connection costs money.
                LabeledContent("Right now") {
                    Label(metering.verdict.explanation,
                          systemImage: metering.verdict.isMetered
                              ? "antenna.radiowaves.left.and.right" : "wifi")
                        .foregroundStyle(metering.verdict.isMetered
                                         ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                }
                // Right under the verdict, so a wrong one is settled where
                // it's read: a phone that isn't recognised (#109), or a hotel
                // that charges by the gigabyte. Remembered for this network.
                Picker("This network", selection: Binding(get: { metering.override },
                                                          set: { metering.setOverride($0) })) {
                    Text("Detect automatically").tag(Bool?.none)
                    Text("Is a hotspot").tag(Bool?.some(true))
                    Text("Isn't a hotspot").tag(Bool?.some(false))
                }
            } footer: {
                // Said once, plainly, because Low Data Mode does a little more
                // than the switch's name: iCloud Photos waits too.
                SettingsFootnote("Also puts the hotspot in Low Data Mode, so iCloud and other "
                                 + "background downloads wait until you're off it.")
            }

            if metering.isEnabled {
                Section {
                    // Collapsed by default. "Which apps?" is a question asked
                    // occasionally; it is not worth a dozen permanent rows.
                    DisclosureGroup(isExpanded: $state.appsExpanded) {
                        // A line between rows, so each switch sits with its own (#185).
                        ForEach(Array(state.coveredItems.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider() }
                            PausedAppRow(item: item, metering: metering)
                        }
                        if state.coveredItems.isEmpty && state.listLoaded {
                            Text("Nothing on this Mac to pause.").foregroundStyle(.secondary)
                        }
                    } label: {
                        Text(coverageSummary).togglesDisclosure($state.appsExpanded)
                    }
                } footer: {
                    // Where the list comes from and when it acts, said under it
                    // because both are the first things someone new asks.
                    SettingsFootnote("Found by looking inside the apps on this Mac. They're "
                                     + "paused only while you're on a hotspot, and put back "
                                     + "when you leave.")
                }

                // The other half of the honesty the list above owes: what it does
                // not reach on this Mac, found by how each app updates rather than
                // by a list of names, each with the reason behind its ⓘ (#185).
                if !state.uncovered.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $state.uncoveredExpanded) {
                            ForEach(Array(state.uncovered.enumerated()), id: \.element.id) { index, finding in
                                if index > 0 { Divider() }
                                UncoveredAppRow(name: finding.displayName, reason: uncoveredReason(finding),
                                                isActionable: helperWouldPause(finding))
                            }
                        } label: {
                            Text("Can't be paused (\(state.uncovered.count))")
                                .togglesDisclosure($state.uncoveredExpanded)
                        }
                    } footer: {
                        SettingsFootnote("Quit these while you're on a hotspot to be sure they "
                                         + "don't update. Low Data Mode slows the ones that "
                                         + "respect it.")
                    }
                }

                // Every app's updater, stopped at the network: what the lists
                // above can't promise (#98).
                if filter.state == .on {
                    Section {
                        LabeledContent("Every app's updater") {
                            Text("Stopped on hotspots").foregroundStyle(.secondary)
                        }
                    } footer: {
                        SettingsFootnote(SetupCopy.hotspotUpdatesOn)
                    }
                } else if filter.state.isOffered {
                    Section {
                        WebsiteNamesRow(filter: filter, symbol: "arrow.down.circle",
                                        title: SetupCopy.hotspotUpdatesTitle,
                                        summary: SetupCopy.hotspotUpdatesSummary)
                    }
                }

                if hasStatus {
                    Section {
                        lowDataModeStatus
                        if !metering.updatesGotThrough.isEmpty { gotThrough }
                        helperNotice
                    }
                }
            }
        }
        .settingsForm()
        // Refreshed on each appearance rather than held, because apps get
        // installed. Off the main thread (#65): the pane shows at once with what
        // was found last time, and the re-check and the lists arrive after.
        .onAppear {
            metering.refreshInBackground { listing in
                state.coveredItems = listing.items
                state.uncovered = listing.uncovered
                state.listLoaded = true
            }
        }
    }

    private var hasStatus: Bool {
        if case .off = metering.lowDataMode {} else { return true }
        return !metering.updatesGotThrough.isEmpty || metering.helperState != .current
            || !metering.failed.isEmpty
    }

    // MARK: Low Data Mode

    /// A status line, not a control: Low Data Mode is part of the one switch
    /// above. Shown only while metered, where there is something to report.
    @ViewBuilder
    private var lowDataModeStatus: some View {
        switch metering.lowDataMode {
        case .on:
            // "macOS confirms it" is macOS's own network path agreeing, not just
            // the flag reading back — the difference between claiming it and it
            // being so.
            Label(metering.lowDataModeConfirmed
                  ? "Low Data Mode is on — macOS confirms it" : "Low Data Mode is on",
                  systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .alreadyOn:
            Label("This connection was already in Low Data Mode", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .off:
            EmptyView()
        }
    }

    // MARK: The helper

    /// What the helper still needs, with the one button that does it.
    ///
    /// This replaces "run `make helper` in Terminal". The button shows macOS's
    /// administrator dialog; nothing else about installing it is the user's job.
    @ViewBuilder
    private var helperNotice: some View {
        if metering.helperState == .waitingForApproval {
            // The daemon (#131): macOS lists it in Login Items for the person
            // to switch on. Said as what to do there, not what it is.
            LabeledContent {
                Button("Open System Settings") { HelperService.openSystemSettings() }
            } label: {
                Label("To finish, switch on NetworkMonitor in System Settings, under Allow in the Background.",
                      systemImage: "lock.shield")
            }
            .onAppear { metering.watchForApproval() }
        } else if metering.helperState != .current {
            if HelperInstaller.canInstall {
                LabeledContent {
                    Button("Allow…") { askForHelper() }
                } label: {
                    Label(metering.helperState == .outdated
                          ? "macOS updates, Chrome, Claude, Slack and Low Data Mode need a quick "
                            + "update to NetworkMonitor's helper."
                          : "macOS updates, Chrome, Claude, Slack and Low Data Mode need your "
                            + "permission once.",
                          systemImage: "lock.shield")
                }
            } else {
                // The helper's self-heal looks for the app in /Applications and
                // would remove itself within the hour for a copy anywhere else.
                Label("Move NetworkMonitor to your Applications folder to pause macOS updates "
                      + "and use Low Data Mode too.", systemImage: "folder")
                    .foregroundStyle(.orange)
            }
            if let message = state.helperMessage {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        } else if !metering.failed.isEmpty {
            // Never silently: a tier that refused every call must not keep its
            // apps listed as paused.
            Label("Couldn't pause " + metering.failed.joined(separator: ", "),
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private func askForHelper() {
        guard let outcome = metering.ensureHelper(userAsked: true) else { return }
        switch outcome {
        case .done:
            state.helperMessage = nil
            // The helper adds a row: macOS, the App Store, and the apps it reaches.
            state.coveredItems = metering.toggleItems()
            state.uncovered = metering.uncoveredUpdaters()
        case .cancelled:
            state.helperMessage = nil
        case .waitingForApproval:
            // macOS has listed it; the notice above says where to switch it on.
            state.helperMessage = nil
            HelperService.openSystemSettings()
        case .failed(let message):
            state.helperMessage = message
        }
    }

    // MARK: What got through

    /// Updates that downloaded on a metered connection anyway, with what they
    /// cost. The report this feature owes for the updates it could not prevent.
    @ViewBuilder
    private var gotThrough: some View {
        Text(metering.isSuppressing
             ? "Got through on this connection"
             : "Got through on your last metered connection")
            .font(.system(size: 12, weight: .medium))
        let paused = pausedNames
        ForEach(metering.updatesGotThrough) { sighting in
            LabeledContent {
                Text(Self.amount(for: sighting)).monospacedDigit()
                    .help(Self.amountHelp(for: sighting))
            } label: {
                Label(Self.label(for: sighting, wasPaused: paused.contains(sighting.appName)),
                      systemImage: sighting.source == .traffic
                          ? "arrow.triangle.2.circlepath" : "arrow.down.circle")
                    .foregroundStyle(paused.contains(sighting.appName) ? AnyShapeStyle(.orange)
                                                                       : AnyShapeStyle(.primary))
                    .help(sighting.app == nil ? "" : "Through its updater, \(sighting.name).")
            }
        }
    }

    /// Every app on the paused list, group members included: one that got
    /// through anyway is a pause that didn't hold, and says so (#94).
    private var pausedNames: Set<String> {
        Set(state.coveredItems.filter { metering.isSuppressionEnabled(for: $0.id) }
                .flatMap { item in item.isGroup ? item.members.map(\.name) : [item.label] })
    }

    /// "120 MB", or "up to 272 MB" when only the most it could be is known.
    static func amount(for sighting: UpdateWatch.Sighting) -> String {
        guard sighting.bytes > 0 else { return "—" }
        return (sighting.isUpperBound ? "up to " : "") + ByteFormat.bytes(sighting.bytes)
    }

    static func amountHelp(for sighting: UpdateWatch.Sighting) -> String {
        if sighting.includesOtherUse == true {
            return "All \(sighting.appName) used on this connection, so its update used no more than this."
        }
        if sighting.isSizeOnDisk == true {
            return "The update's size on your Mac. It used no more than this to download."
        }
        return sighting.source == .download
            ? "What \(sighting.appName) used while the update downloaded."
            : "What its updater used on this connection."
    }

    /// The app, not its updater's process, and the version once it changed:
    /// "Slack updated to 4.41". "Anyway" when it was on the paused list.
    static func label(for sighting: UpdateWatch.Sighting, wasPaused: Bool = false) -> String {
        let what = sighting.version.map { "\(sighting.appName) updated to \($0)" }
            ?? "\(sighting.appName) downloaded an update"
        return wasPaused ? what + " anyway" : what
    }

    // MARK: Can't be paused

    /// Why it can't be paused, or — for an app only the helper reaches — what
    /// would pause it, which is the more useful thing to know.
    private func uncoveredReason(_ finding: UpdaterScan.Finding) -> String {
        helperWouldPause(finding) ? "Paused once you allow the helper below" : finding.mechanism.whyNotPaused
    }

    private func helperWouldPause(_ finding: UpdaterScan.Finding) -> Bool {
        !metering.helperInstalled && PrivilegedSuppressor.coveredApplications.contains {
            ($0.bundleID != nil && $0.bundleID == finding.bundleIdentifier)
                || $0.app == finding.displayName
        }
    }

    /// "Paused on a hotspot (7)" when everything is on, "(6 of 7)" once one is
    /// switched off. Named for when, because "Apps paused" read as happening
    /// already, on home Wi-Fi too.
    private var coverageSummary: String {
        // No count until the apps have been looked at, rather than "(0)".
        guard state.listLoaded else { return "Paused on a hotspot" }
        let total = state.coveredItems.count
        let on = state.coveredItems.filter { metering.isSuppressionEnabled(for: $0.id) }.count
        return on == total ? "Paused on a hotspot (\(total))"
                           : "Paused on a hotspot (\(on) of \(total))"
    }
}

/// One row of *Paused on a hotspot*: an app, or a tier of apps that one switch
/// moves together.
///
/// The name and the switch on one line, so it's plain which switch is whose,
/// and what pausing it does behind an ⓘ that shows while the pointer is over
/// the row (#185). What needs attention stays in view.
///
/// On by default and on for every app the moment the parent switch goes on —
/// the opt-out set starts empty, so there is no state to seed and nothing to
/// migrate for anyone upgrading.
struct PausedAppRow: View {
    let item: MeteringController.ToggleItem
    @ObservedObject var metering: MeteringController
    /// Not `@State`; see `SettingsPaneState`.
    @StateObject private var info = RowInfoState()

    var body: some View {
        Toggle(isOn: Binding(
            get: { metering.isSuppressionEnabled(for: item.id) },
            set: { metering.setSuppressionEnabled($0, for: item.id) })) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(item.label)
                    RowInfoButton(help: Self.effect(of: item), state: info) {
                        if item.isGroup {
                            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                                ForEach(item.members) { member in
                                    GridRow {
                                        Text(member.name)
                                        Text(member.effect).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } else {
                            Text(item.effect)
                        }
                    }
                    // Only while a change is really waiting: on a hotspot, for an
                    // app that was open when it was due. Its settings can't be
                    // changed safely while it runs, so the change is made the
                    // moment it quits, and the note goes (#65). It used to show
                    // whenever the app was open, on any network, so quitting and
                    // reopening changed nothing.
                    if metering.deferred.contains(item.label) {
                        Text("paused once you quit it")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .help("NetworkMonitor can't change \(item.label)'s settings while it's "
                                  + "open. It pauses its updates as soon as you quit it.")
                    }
                    if !item.isGroup { updatedAnyway([item.label]) }
                }
                if item.isGroup {
                    // Who the one switch moves, by name.
                    SettingsRowDetail(ListFormatter.localizedString(byJoining: item.members.map(\.name)))
                    updatedAnyway(item.members.map(\.name))
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .accessibilityHint(Self.effect(of: item))
        .contentShape(Rectangle())
        .onHover { info.isHovering = $0 }
    }

    /// What pausing it does: for a tier, each app's, a line each.
    static func effect(of item: MeteringController.ToggleItem) -> String {
        item.isGroup ? item.members.map { "\($0.name): \($0.effect)" }.joined(separator: "\n") : item.effect
    }

    /// Beside a paused app that updated on the last metered connection, or
    /// under a tier's apps, naming those that did: the one place it's learned
    /// that a pause didn't hold. Goes when the next metered connection starts
    /// a new report (#94).
    @ViewBuilder
    private func updatedAnyway(_ names: [String]) -> some View {
        let updated = names.filter { name in metering.updatesGotThrough.contains { $0.appName == name } }
        if !updated.isEmpty {
            Text(item.isGroup ? ListFormatter.localizedString(byJoining: updated) + " updated anyway"
                              : "updated anyway")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .help(updated.count == 1
                      ? "\(updated[0]) updated on your last metered connection although it was paused. "
                        + "Its row under Got through says how much it used."
                      : "These updated on your last metered connection although they were paused. "
                        + "Their rows under Got through say how much each used.")
        }
    }
}

/// One row of *Can't be paused*: the app, and why behind an ⓘ (#185). What
/// would pause it, the helper, is something to do, so it stays in view.
struct UncoveredAppRow: View {
    let name: String
    let reason: String
    let isActionable: Bool
    /// Not `@State`; see `SettingsPaneState`.
    @StateObject private var info = RowInfoState()

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text(name)
                if !isActionable {
                    RowInfoButton(help: reason, state: info) { Text(reason) }
                }
            }
            if isActionable { SettingsRowDetail(reason) }
        }
        // Full width, or each row centres itself on its own text's width.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { info.isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityHint(isActionable ? "" : reason)
    }
}

/// An ⓘ beside a row's name, there only while the pointer is over the row:
/// what it says is a tooltip, or a popover when clicked (#185). VoiceOver
/// gets it from the row instead.
struct RowInfoButton<Content: View>: View {
    let help: String
    @ObservedObject var state: RowInfoState
    @ViewBuilder let content: Content

    var body: some View {
        Button { state.showsInfo.toggle() } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(help)
        .opacity(state.isHovering || state.showsInfo ? 1 : 0)
        .accessibilityHidden(true)
        .popover(isPresented: $state.showsInfo, arrowEdge: .bottom) {
            content
                .font(.system(size: 12))
                .frame(maxWidth: 420, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
    }
}

/// A row whose explanation is behind an ⓘ beside its label, rather than a
/// paragraph under the section (#189).
struct ExplainedRow<Control: View>: View {
    let title: String
    let explanation: String
    @ViewBuilder let control: Control
    /// Not `@State`; see `SettingsPaneState`.
    @StateObject private var info = RowInfoState()

    init(_ title: String, _ explanation: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.explanation = explanation
        self.control = control()
    }

    var body: some View {
        LabeledContent {
            control
        } label: {
            HStack(spacing: 5) {
                Text(title)
                RowInfoButton(help: explanation, state: info) { Text(explanation) }
            }
        }
        .contentShape(Rectangle())
        .onHover { info.isHovering = $0 }
        .accessibilityHint(explanation)
    }
}

/// Whether the pointer is over a row, and whether its ⓘ is open.
final class RowInfoState: ObservableObject {
    @Published var isHovering = false
    @Published var showsInfo = false
}

// MARK: - About

/// Who made it, which version this is, where to read more, and the way out —
/// uninstalling, which lived only on the right-click menu before.
struct AboutSettingsPane: View {
    @ObservedObject var updates: UpdateController
    let onUninstall: () -> Void

    private var version: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else {
            return "Development build"
        }
        let build = info?["CFBundleVersion"] as? String
        return "Version \(short)" + (build.map { " (\($0))" } ?? "")
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 88, height: 88)
                    Text("NetworkMonitor").font(.system(size: 20, weight: .semibold))
                    Text(version).font(.system(size: 12)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("Live network speed in your menu bar, and which app used your data.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section {
                link("Website", "kevinabouhanna.github.io",
                     "https://kevinabouhanna.github.io/NetworkMonitor/")
                link("What's new", "Release notes",
                     "https://github.com/kevinabouhanna/NetworkMonitor/releases/latest")
                link("Source code", "On GitHub",
                     "https://github.com/kevinabouhanna/NetworkMonitor")
            } footer: {
                SettingsFootnote("Free and open source, under the MIT licence.")
            }

            // Updating itself (#132): its one network access besides the
            // monthly data, said as plainly, with its switch.
            if updates.isAvailable {
                Section {
                    Toggle("Check for updates automatically", isOn: $updates.checksAutomatically)
                        .toggleStyle(.switch)
                    LabeledContent("Updates") {
                        Button("Check Now") { updates.checkForUpdates() }
                    }
                } footer: {
                    SettingsFootnote("Once a day, NetworkMonitor asks GitHub whether there's a newer version, "
                                     + "never on a hotspot. An update installs only when you say so, and only "
                                     + "if it's signed by NetworkMonitor.")
                }
            }

            Section {
                LabeledContent("Remove NetworkMonitor") {
                    Button("Uninstall…", role: .destructive) { onUninstall() }
                }
            } footer: {
                SettingsFootnote("Puts back every setting it changed, removes its helper and your "
                                 + "usage history, and moves the app to the Trash.")
            }
        }
        .settingsForm()
    }

    private func link(_ title: String, _ text: String, _ address: String) -> some View {
        LabeledContent(title) {
            Link(destination: URL(string: address)!) {
                Label(text, systemImage: "arrow.up.right.square").labelStyle(.titleAndIcon)
            }
        }
    }
}

// MARK: - Shared

/// The plain-words line under a row's name: how an app is paused, or why it
/// can't be.
struct SettingsRowDetail: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The line of explanation under a section, as System Settings sets it.
struct SettingsFootnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// The grouped form every pane uses, at the shared width, as tall as its
    /// content so the window can size itself to the pane.
    func settingsForm() -> some View {
        formStyle(.grouped)
            .scrollDisabled(true)
            // Up to the pane's width, not exactly it: a scroll bar shown always
            // takes its width from here when the pane scrolls.
            .frame(maxWidth: SettingsMetrics.paneWidth)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Lets a disclosure group's label open and close it from anywhere on the
    /// row, as System Settings does. On its own, only the chevron responds.
    func togglesDisclosure(_ isExpanded: Binding<Bool>) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation { isExpanded.wrappedValue.toggle() } }
    }
}

/// What the panes own themselves, held in an `ObservableObject` rather than in
/// `@State` properties, and shared by General and Hotspot so it survives
/// switching between panes.
///
/// From the macOS 27 SDK on, `@State` is a macro, and its implementation ships
/// only with Xcode. With Command Line Tools alone — the only toolchain this
/// project assumes — every `@State` fails to compile with "plugin for module
/// 'SwiftUIMacros' not found". `@Published` is a Combine property wrapper, not a
/// macro, so it builds with either toolchain.
final class SettingsPaneState: ObservableObject {
    @Published var launchAtLogin = LoginItem.isEnabled
    @Published var errorMessage: String?
    @Published var appsExpanded = false
    /// Loaded off the main thread when the pane appears, never from `body`.
    ///
    /// Finding them walks `/Applications` reading Info.plists to find Sparkle
    /// frameworks; see `MeteringController.refreshInBackground(_:)`.
    @Published var coveredItems: [MeteringController.ToggleItem] = []
    /// Loaded alongside `coveredItems`, and for the same reason never from
    /// `body`: it walks the same bundles.
    @Published var uncovered: [UpdaterScan.Finding] = []
    @Published var uncoveredExpanded = false
    /// Whether the lists above have been loaded at least once.
    @Published var listLoaded = false
    /// Why the last helper install failed, if it did. Cleared by a success or a
    /// deliberate cancel, which is an answer rather than a failure.
    @Published var helperMessage: String?
}
