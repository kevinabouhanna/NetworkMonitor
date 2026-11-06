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
/// macOS asks only when the person turns names on, in the welcome window or
/// Settings › General (#134), never by itself at launch.
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
        // Right away, not in `start()`. The status read above is taken before
        // locationd has registered the app, so it says `.notDetermined` even
        // when Location was allowed long ago. The real answer arrives a few
        // milliseconds later as a delegate call, and only to a delegate that's
        // already set: set later, it never comes, and the app went on asking
        // for a permission it already had, with macOS ignoring the request.
        manager.delegate = self
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

    public func start() {
        refresh()
    }

    /// Reads the answer again, in case it changed without a delegate call.
    public func refresh() {
        let current = manager.authorizationStatus
        guard current != status else { return }
        status = current
        updateReadable()
        onChange?()
    }

    /// macOS's question, if it hasn't been answered. Once it has, only System
    /// Settings can change the answer: `ask()` returns false, and the caller
    /// opens it. Already allowed, there's nothing to ask, and it returns true.
    @discardableResult
    public func ask() -> Bool {
        refresh()
        switch access {
        case .allowed:
            return true
        case .asking:
            manager.requestAlwaysAuthorization()
            return true
        case .denied:
            return false
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
