import CoreLocation
import CoreWLAN
import Foundation

/// The Wi-Fi network's name, as the label for networks (#85). macOS hands it
/// out only with Location permission, so the app asks for that.
///
/// Checked on macOS 27 without it: CoreWLAN's `ssid()` is nil, configd's
/// `SSID_STR` is empty and `ipconfig getsummary` prints `<redacted>`. The
/// permission is used for the name and nothing else: no location is ever
/// requested.
///
/// Without a Developer ID every update is a different app to macOS, so it will
/// likely ask again after one. `start()` asks whenever the answer is unknown.
public final class WiFiNames: NSObject, ObservableObject, CLLocationManagerDelegate {

    /// What Settings says, which is nothing unless names can't be read.
    public enum Access: Equatable {
        /// The system's question is still open.
        case asking
        case allowed
        /// Location is off for NetworkMonitor, or off altogether.
        case denied
    }

    @Published public private(set) var status: CLAuthorizationStatus

    /// After every change of answer. `MonitorViewModel` evaluates the network
    /// again, so a name shows without waiting for the next one.
    public var onChange: (() -> Void)?

    private let manager: CLLocationManager
    /// Whether names may be read, for the path watcher's queue.
    private let lock = NSLock()
    private var readable = false

    public override init() {
        manager = CLLocationManager()
        status = manager.authorizationStatus
        super.init()
        updateReadable()
    }

    public var access: Access { Self.access(status) }

    public static func access(_ status: CLAuthorizationStatus) -> Access {
        switch status {
        case .notDetermined:    return .asking
        // macOS has no "while using": Allow is `.authorizedAlways`.
        case .authorizedAlways: return .allowed
        default:                return .denied
        }
    }

    /// Asks, if the answer is unknown, as it is on first launch and likely
    /// after an update. A few seconds in, as the helper's offer is, so the
    /// menu bar item is there to say whose question it is.
    public func start() {
        manager.delegate = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.status == .notDetermined else { return }
            self.manager.requestAlwaysAuthorization()
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        status = manager.authorizationStatus
        updateReadable()
        onChange?()
    }

    /// The name of the Wi-Fi network on `interface`, if it may be read. Safe to
    /// call from any queue.
    public func name(onInterface interface: String) -> String? {
        lock.lock(); let readable = readable; lock.unlock()
        guard readable else { return nil }
        return CWWiFiClient.shared().interface(withName: interface)?.ssid()
    }

    private func updateReadable() {
        let allowed = access == .allowed
        lock.lock(); readable = allowed; lock.unlock()
    }
}
