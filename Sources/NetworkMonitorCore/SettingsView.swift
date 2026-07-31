import SwiftUI

/// App settings, opened from the gear icon in the popover.
public struct SettingsView: View {
    @ObservedObject var model: MonitorViewModel

    @State private var launchAtLogin: Bool
    @State private var errorMessage: String?

    public init(model: MonitorViewModel) {
        self.model = model
        _launchAtLogin = State(initialValue: LoginItem.isEnabled)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("General") {
                Toggle("Start at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in apply(enabled) }
                Text("Opens NetworkMonitor automatically when you log in. "
                     + "Quitting the app still quits it — it will not reopen until "
                     + "your next login.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            section("Per-app usage") {
                Picker("Track", selection: Binding(
                    get: { model.trackingMode },
                    set: { model.setTrackingMode($0) })) {
                    ForEach(PerAppTrackingMode.allCases, id: \.self) { mode in
                        Text(mode.settingsTitle).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                Text("Per-app data comes from macOS's nettop, which uses about "
                     + "1.4 CPU cores while running. Your live speed and daily "
                     + "total never use it and are always accurate.")
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

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 380)
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
