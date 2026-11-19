import FilterProtocol
import Foundation
import NetworkExtension
import os

/// Enhanced ad blocking's transparent proxy, the app's side (#702): its
/// configuration, which the system extension that carries the content filter
/// carries too. Configured and started only while the switch is on; with it
/// off, any configuration left from before is removed, so nothing runs.
///
/// Until Settings has its switch (#685), it's on only for a run started with
/// `-enhancedAdBlockingForTesting YES`, to check a signed test build in a VM.
public final class EnhancedBlockingProxy {

    static let log = Logger(subsystem: "com.kevinabouhanna.NetworkMonitor", category: "enhanced")

    public init() {}

    /// What to do with the configurations there are, for the switch.
    public enum Action: Equatable {
        case nothing
        /// Save (or keep) one configuration, enabled, and start it.
        case configure
        /// Remove every configuration there is.
        case remove
    }

    public static func action(isOn: Bool, configured: Int) -> Action {
        if isOn { return .configure }
        return configured > 0 ? .remove : .nothing
    }

    /// The proxy's provider: the filter's system extension.
    public static func providerProtocol() -> NETunnelProviderProtocol {
        let proxy = NETunnelProviderProtocol()
        proxy.providerBundleIdentifier = FilterIdentity.extensionIdentifier
        proxy.serverAddress = "NetworkMonitor"
        return proxy
    }

    public static let name = "NetworkMonitor Enhanced Ad Blocking"

    /// The testing switch: a launch argument, read for that run only.
    public static var isOnForTesting: Bool {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["enhancedAdBlockingForTesting"]
            .map { ($0 as? String).map { ["yes", "true", "1"].contains($0.lowercased()) } ?? false } ?? false
    }

    /// Configures it, or removes it, as `isOn` says.
    public func apply(isOn: Bool) {
        guard FilterController.isBundled else { return }
        NETransparentProxyManager.loadAllFromPreferences { managers, error in
            if let error {
                Self.log.error("couldn't read the proxy's configuration: \(error.localizedDescription, privacy: .public)")
                return
            }
            let managers = managers ?? []
            switch Self.action(isOn: isOn, configured: managers.count) {
            case .nothing:
                break
            case .remove:
                for manager in managers {
                    manager.removeFromPreferences { error in
                        Self.log.notice("proxy configuration removed\(error.map { ": \($0.localizedDescription)" } ?? "", privacy: .public)")
                    }
                }
            case .configure:
                // One configuration: any extra ones go.
                managers.dropFirst().forEach { $0.removeFromPreferences { _ in } }
                Self.configure(managers.first ?? NETransparentProxyManager())
            }
        }
    }

    private static func configure(_ manager: NETransparentProxyManager) {
        manager.protocolConfiguration = providerProtocol()
        manager.localizedDescription = name
        manager.isEnabled = true
        manager.saveToPreferences { error in
            if let error {
                log.error("couldn't configure the proxy: \(error.localizedDescription, privacy: .public)")
                return
            }
            // Saved, then loaded again before it can start.
            manager.loadFromPreferences { _ in
                do {
                    try manager.connection.startVPNTunnel()
                    log.notice("proxy started")
                } catch {
                    log.error("couldn't start the proxy: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
