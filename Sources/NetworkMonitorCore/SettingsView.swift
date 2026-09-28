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

    /// What the pane owns itself. See `SettingsPaneState` for why this is not a
    /// handful of `@State` properties.
    @StateObject private var pane = SettingsPaneState()

    public init(model: MonitorViewModel) {
        self.model = model
        self.metering = model.metering
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
                Toggle("Stop apps updating on hotspots",
                       isOn: $metering.isEnabled)

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

                    if !metering.helperInstalled {
                        footnote("exclamationmark.triangle",
                                 "macOS, Claude, Slack, Canva: make helper-no-daemon",
                                 tint: .orange)
                    } else if !metering.failed.isEmpty {
                        // Never silently: a tier that refused every call must not
                        // keep its apps listed as paused.
                        footnote("exclamationmark.triangle",
                                 "Couldn't pause " + metering.failed.joined(separator: ", "),
                                 tint: .orange)
                    }

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
        }
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
}
