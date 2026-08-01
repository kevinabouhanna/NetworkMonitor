import SwiftUI

/// App settings, opened from the gear icon in the popover.
///
/// Everything that is not "what is using my network right now" lives here, so the
/// popover stays a single glanceable list.
public struct SettingsView: View {
    @ObservedObject var model: MonitorViewModel
    var onQuit: () -> Void

    @State private var launchAtLogin: Bool
    @State private var errorMessage: String?

    public init(model: MonitorViewModel, onQuit: @escaping () -> Void) {
        self.model = model
        self.onQuit = onQuit
        _launchAtLogin = State(initialValue: LoginItem.isEnabled)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("General") {
                Toggle("Start at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in apply(enabled) }
                Text("Opens NetworkMonitor automatically when you log in. Quitting "
                     + "still quits it — it will not reopen until your next login.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Spacer()
                Button("Quit", action: onQuit)
            }
        }
        .padding(20)
        .frame(width: 400)
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
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            // Snap the toggle back so it never claims a state that did not stick.
            launchAtLogin = LoginItem.isEnabled
        }
    }
}
