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

            section("Per-app usage") {
                // "Plugged in" on its own is ambiguous in a network app — it
                // reads as an Ethernet cable. This is about the power adapter.
                Toggle("Keep tracking when plugged into power", isOn: Binding(
                    get: { model.trackingMode == .pluggedIn },
                    set: { model.setTrackingMode($0 ? .pluggedIn : .whenOpen) }))
                Text("Off, app usage is only counted while this menu is open. "
                     + "On, it's counted all day too, but uses more battery.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 5) {
                    Circle()
                        .fill(model.isTrackingPerApp ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(model.isTrackingPerApp ? "Tracking now" : "Paused")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            section("Usage data") {
                HStack(spacing: 6) {
                    Text("Counting since")
                        .font(.system(size: 12))
                    Text(model.dayStart, format: .dateTime.hour().minute())
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                    Spacer()
                }
                Text("Totals reset automatically at midnight.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button("Reset This Network") { model.resetCurrentNetwork() }
                    Button("Reset All Networks") {
                        model.store.resetAllNetworks()
                        model.refreshHeader()
                    }
                }
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
