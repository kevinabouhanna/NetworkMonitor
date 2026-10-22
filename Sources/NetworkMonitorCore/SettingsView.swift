import SwiftUI

/// App settings, opened from the gear icon in the popover.
///
/// Everything that is not "what is using my network right now" lives here, so the
/// popover stays a single glanceable list.
///
/// Quit is deliberately not here. It is a menu bar app, and the menu bar is where
/// a Mac user looks to quit one — it stays on the status item's right-click menu
/// rather than being duplicated inside a preferences pane.
public struct SettingsView: View {
    @ObservedObject var model: MonitorViewModel
    /// Observed separately from `model`: the controller publishes its own state,
    /// and reaching it through a `let` on the view model would neither give a
    /// writable binding for the toggle nor redraw when the verdict changes.
    @ObservedObject var metering: MeteringController
    @ObservedObject var speedTest: SpeedTestController

    /// What the pane owns itself. See `SettingsPaneState` for why this is not a
    /// handful of `@State` properties.
    @StateObject private var pane = SettingsPaneState()

    public init(model: MonitorViewModel) {
        self.model = model
        self.metering = model.metering
        self.speedTest = model.speedTest
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("General") {
                Toggle("Start at login", isOn: $pane.launchAtLogin)
                    .onChange(of: pane.launchAtLogin) { enabled in apply(enabled) }
                Text("Opens NetworkMonitor automatically when you log in. Quitting "
                     + "still quits it — it will not reopen until your next login.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            section("Hotspot") {
                // One switch for the whole feature, Low Data Mode included: it
                // serves the same purpose, and a second switch would only ask
                // the user to make the same decision twice.
                Toggle("Stop apps updating on hotspots",
                       isOn: $metering.isEnabled)
                    .onChange(of: metering.isEnabled) { enabled in
                        // Switching it on is the moment to ask for the helper —
                        // the one thing here that needs a password. Deferred a
                        // turn so the switch has finished drawing before the
                        // administrator dialog takes over.
                        guard enabled else { return }
                        DispatchQueue.main.async { askForHelper() }
                    }

                // Said once, plainly, because Low Data Mode does a little more
                // than the switch's name: iCloud Photos waits too.
                Text("Also puts the hotspot in Low Data Mode, so iCloud and other "
                     + "background downloads wait until you're off it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // The verdict, always shown: the commonest confusion with a
                // feature like this is not knowing whether it decided the
                // connection counts, and the answer is one line long.
                footnote(metering.verdict.isMetered
                         ? "antenna.radiowaves.left.and.right" : "wifi",
                         metering.verdict.explanation,
                         // Green when it has decided the connection costs money:
                         // this line is the answer to "is it doing anything right
                         // now", and colour makes that readable at a glance.
                         tint: metering.verdict.isMetered ? .green : .secondary,
                         alignment: .center)

                if metering.isEnabled {
                    // Collapsed by default. "Which apps?" is a question the user
                    // asks occasionally; it is not worth eight permanent lines of
                    // a pane this size, and the previous version spent them.
                    DisclosureGroup(isExpanded: $pane.appsExpanded) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(pane.coveredItems) { appToggle($0) }
                            if pane.coveredItems.isEmpty {
                                Text("Nothing on this Mac to pause.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 5)
                    } label: {
                        Text(coverageSummary).font(.system(size: 12))
                    }

                    // The other half of the honesty the list above owes: what
                    // it does not reach on this Mac, found by how each app
                    // updates rather than by a list of names.
                    if !pane.uncovered.isEmpty {
                        DisclosureGroup(isExpanded: $pane.uncoveredExpanded) {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(pane.uncovered) { uncoveredRow($0) }
                                Text("These update themselves in a way NetworkMonitor "
                                     + "can't switch off. Low Data Mode slows the ones "
                                     + "that respect it; quitting them while you're on "
                                     + "a hotspot is the only sure way.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.top, 2)
                            }
                            .padding(.top, 5)
                        } label: {
                            Text("Not covered (\(pane.uncovered.count))")
                                .font(.system(size: 12))
                        }
                    }

                    lowDataModeStatus

                    if !metering.updatesGotThrough.isEmpty { gotThrough }

                    helperNotice
                }

            }

            if SpeedTestRunner.isAvailable {
                Divider()

                section("Speed test") {
                    // Label and control laid out by hand. A labelled segmented
                    // Picker given a fixed frame centres itself inside it, which
                    // left the row indented from everything else in the pane.
                    HStack(spacing: 8) {
                        Text("Show speeds in").font(.system(size: 12))
                        Picker("Show speeds in", selection: $speedTest.unit) {
                            ForEach(SpeedUnit.allCases) { unit in
                                Text(unit.label).tag(unit)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        Spacer()
                    }

                    Toggle("Show the test in the menu bar", isOn: $speedTest.showsInMenuBar)

                    Text("Runs macOS's built-in networkQuality, only when you start it: "
                         + "download first, then upload. Every run measures afresh, so it "
                         + "uses data each time — typically 50–500 MB, more on a very fast line.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            section("Usage data") {
                HStack(spacing: 6) {
                    Text("Counting since")
                        .font(.system(size: 12))
                    Text(model.countingSince, format: .dateTime.hour().minute())
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                    Spacer()
                }
                Text("Totals count what this connection has used, per app, all the "
                     + "time. They start over when you join a different network, "
                     + "and at midnight.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                // Stated, not offered. There is nothing to choose here — the point
                // is that the app handles it — but a reader who notices the app
                // list updating every 3 s instead of every 1 s deserves to know
                // that is deliberate and costs them no accuracy.
                HStack(spacing: 5) {
                    Image(systemName: model.profile == .performance
                          ? "bolt.fill" : "battery.75")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(model.profile == .performance
                         ? "Plugged in — sampling every second"
                         : "On battery — sampling every 3 seconds, same totals")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                // One button, not two. Usage is bucketed per network internally,
                // but the popover never names the network, so "this network" vs
                // "all networks" had no visible referent and only caused doubt.
                Button("Reset Now") { model.resetCurrentNetwork() }
            }

            if let errorMessage = pane.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 400)
        // Refreshed on each open rather than held: apps get installed, and
        // `isDeferred` depends on what is running right now.
        .onAppear {
            // Re-assert first, so the list below describes what is actually in
            // force rather than what is merely installed.
            metering.refresh()
            pane.coveredItems = metering.toggleItems()
            pane.uncovered = metering.uncoveredUpdaters()
        }
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
            footnote("checkmark.circle",
                     metering.lowDataModeConfirmed
                        ? "Low Data Mode is on — macOS confirms it"
                        : "Low Data Mode is on",
                     tint: .green, alignment: .center)
        case .alreadyOn:
            footnote("checkmark.circle", "This connection was already in Low Data Mode",
                     alignment: .center)
        case .failed(let reason):
            footnote("exclamationmark.triangle", reason, tint: .orange)
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
        if metering.helperState != .current {
            if HelperInstaller.canInstall {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(metering.helperState == .outdated
                         ? "macOS updates, Claude, Slack, Canva and Low Data Mode need "
                           + "a quick update to NetworkMonitor's helper."
                         : "macOS updates, Claude, Slack, Canva and Low Data Mode need "
                           + "your permission once.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Allow…") { askForHelper() }
                        .controlSize(.small)
                }
            } else {
                // The helper's self-heal looks for the app in /Applications and
                // would remove itself within the hour for a copy anywhere else.
                footnote("folder",
                         "Move NetworkMonitor to your Applications folder to pause "
                         + "macOS updates and use Low Data Mode too.",
                         tint: .orange)
            }
            if let message = pane.helperMessage {
                footnote("exclamationmark.triangle", message, tint: .orange)
            }
        } else if !metering.failed.isEmpty {
            // Never silently: a tier that refused every call must not keep its
            // apps listed as paused.
            footnote("exclamationmark.triangle",
                     "Couldn't pause " + metering.failed.joined(separator: ", "),
                     tint: .orange)
        }
    }

    private func askForHelper() {
        guard let outcome = metering.ensureHelper(userAsked: true) else { return }
        switch outcome {
        case .done:
            pane.helperMessage = nil
            // The helper adds rows: macOS, Claude, Slack, Canva.
            pane.coveredItems = metering.toggleItems()
            pane.uncovered = metering.uncoveredUpdaters()
        case .cancelled:
            pane.helperMessage = nil
        case .failed(let message):
            pane.helperMessage = message
        }
    }

    // MARK: What got through

    /// Updates that downloaded on a metered connection anyway, with what they
    /// cost. The report this feature owes for the updates it could not prevent.
    private var gotThrough: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(metering.isSuppressing
                 ? "Got through on this connection"
                 : "Got through on your last metered connection")
                .font(.system(size: 12))
            ForEach(metering.updatesGotThrough) { sighting in
                HStack(spacing: 5) {
                    Image(systemName: sighting.source == .download
                          ? "arrow.down.circle" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(Self.label(for: sighting))
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Spacer()
                    Text(ByteFormat.bytes(sighting.bytes))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    static func label(for sighting: UpdateWatch.Sighting) -> String {
        switch sighting.source {
        case .download:
            return "\(sighting.name) downloaded an update"
        case .traffic:
            return sighting.app.map { "\(sighting.name) (\($0))" } ?? sighting.name
        }
    }

    // MARK: Not covered

    private func uncoveredRow(_ finding: UpdaterScan.Finding) -> some View {
        HStack(spacing: 5) {
            Text(finding.displayName).font(.system(size: 12))
            Text(uncoveredDetail(finding))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    /// How it updates, or — for an app only the helper reaches — what would
    /// cover it, which is the more useful thing to know.
    private func uncoveredDetail(_ finding: UpdaterScan.Finding) -> String {
        let helperWouldCover = PrivilegedSuppressor.coveredApplications.contains {
            ($0.bundleID != nil && $0.bundleID == finding.bundleIdentifier)
                || $0.app == finding.displayName
        }
        if helperWouldCover && !metering.helperInstalled { return "needs your permission" }
        if finding.mechanism == .sparkle { return "Sparkle, sandboxed" }
        return finding.mechanism.rawValue
    }

    /// "Apps paused (7)" when everything is on, "(6 of 7)" once one is switched off.
    private var coverageSummary: String {
        let total = pane.coveredItems.count
        let on = pane.coveredItems.filter { metering.isSuppressionEnabled(for: $0.id) }.count
        return on == total ? "Apps paused (\(total))" : "Apps paused (\(on) of \(total))"
    }

    /// One row of the accordion.
    ///
    /// On by default and on for every app the moment the parent switch goes on —
    /// the opt-out set starts empty, so there is no state to seed and nothing to
    /// migrate for anyone upgrading.
    private func appToggle(_ item: MeteringController.ToggleItem) -> some View {
        Toggle(isOn: Binding(
            get: { metering.isSuppressionEnabled(for: item.id) },
            set: { metering.setSuppressionEnabled($0, for: item.id) })) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(item.label).font(.system(size: 12))
                    if item.isDeferred {
                        Text("quit it to apply")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                // Only for a row standing in for a whole tier, where the label
                // alone would not say what is covered.
                if item.isGroup {
                    Text(item.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// `alignment` defaults to the first text baseline, which is what keeps the
    /// icon level with line one of a footnote that wraps. Single-line rows pass
    /// `.center`, where baseline alignment reads as the icon sitting slightly high.
    private func footnote(_ icon: String, _ text: String,
                          tint: Color = .secondary,
                          alignment: VerticalAlignment = .firstTextBaseline) -> some View {
        HStack(alignment: alignment, spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    private func apply(_ enabled: Bool) {
        do {
            if enabled { try LoginItem.enable() } else { try LoginItem.disable() }
            pane.errorMessage = nil
        } catch {
            pane.errorMessage = error.localizedDescription
            // Snap the toggle back so it never claims a state that did not stick.
            pane.launchAtLogin = LoginItem.isEnabled
        }
    }
}

/// The Settings pane's own state, held in an `ObservableObject` rather than in
/// `@State` properties.
///
/// From the macOS 27 SDK on, `@State` is a macro, and its implementation ships
/// only with Xcode. With Command Line Tools alone — the only toolchain this
/// project assumes — every `@State` fails to compile with "plugin for module
/// 'SwiftUIMacros' not found". `@Published` is a Combine property wrapper, not a
/// macro, so it builds with either toolchain.
private final class SettingsPaneState: ObservableObject {
    @Published var launchAtLogin = LoginItem.isEnabled
    @Published var errorMessage: String?
    @Published var appsExpanded = false
    /// Loaded when the pane appears, never from `body`.
    ///
    /// `toggleItems()` reaches `discover()`, which walks `/Applications` reading
    /// Info.plists to find Sparkle frameworks. Recomputing that on every layout
    /// pass would make a checkbox feel slow for no reason.
    @Published var coveredItems: [MeteringController.ToggleItem] = []
    /// Loaded alongside `coveredItems`, and for the same reason never from
    /// `body`: it walks the same bundles.
    @Published var uncovered: [UpdaterScan.Finding] = []
    @Published var uncoveredExpanded = false
    /// Why the last helper install failed, if it did. Cleared by a success or a
    /// deliberate cancel, which is an answer rather than a failure.
    @Published var helperMessage: String?
}
