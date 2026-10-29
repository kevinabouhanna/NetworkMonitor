import Combine
import FilterProtocol
import Foundation
import NetworkExtension
import SystemExtensions

/// The app's side of the content filter (#128): installing the system
/// extension, switching the filter on and off, removing it, and receiving
/// what it saw.
///
/// Nothing happens until someone turns it on in Settings › Connections. Then
/// macOS asks twice: once to allow the system extension (in System Settings),
/// once to allow the filter. Turned off, the extension stays installed but
/// filters nothing; uninstalling NetworkMonitor removes it.
public final class FilterController: NSObject, ObservableObject, OSSystemExtensionRequestDelegate,
                                     FilterAppInterface {

    public enum State: Equatable {
        /// Not built in: a build without the Developer ID.
        case unavailable
        case off
        /// Waiting for the person to allow the extension in System Settings.
        case waitingForApproval
        case starting
        case on
        case failed(String)
    }

    @Published public private(set) var state: State

    /// Each batch the filter reports, on the main queue.
    public let flows = PassthroughSubject<[FlowReport], Never>()

    private var connection: NSXPCConnection?
    private var removing = false

    /// The filter is in the app only when it was signed with the Developer ID
    /// and its profiles; see `Scripts/bundle.sh`.
    public static var isBundled: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundlePath
            + "/Contents/Library/SystemExtensions/\(FilterIdentity.extensionIdentifier).systemextension")
    }

    public override init() {
        state = Self.isBundled ? .off : .unavailable
        super.init()
    }

    /// At launch: if the filter was left on, reconnect to it.
    public func resume() {
        guard Self.isBundled else { return }
        NEFilterManager.shared().loadFromPreferences { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if NEFilterManager.shared().isEnabled {
                    self.state = .on
                    self.connect()
                }
            }
        }
    }

    // MARK: Switching

    public func turnOn() {
        guard Self.isBundled else { return }
        state = .starting
        removing = false
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: FilterIdentity.extensionIdentifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Filters nothing from now on. The extension stays installed, so turning
    /// it back on asks nothing.
    public func turnOff() {
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { [weak self] _ in
            manager.isEnabled = false
            manager.saveToPreferences { _ in
                DispatchQueue.main.async {
                    self?.disconnect()
                    self?.state = Self.isBundled ? .off : .unavailable
                }
            }
        }
    }

    /// For Uninstall: the filter's configuration and the extension both go.
    public func remove(completion: @escaping () -> Void) {
        guard Self.isBundled else { completion(); return }
        disconnect()
        removing = true
        NEFilterManager.shared().loadFromPreferences { _ in
            NEFilterManager.shared().removeFromPreferences { _ in
                DispatchQueue.main.async {
                    let request = OSSystemExtensionRequest.deactivationRequest(
                        forExtensionWithIdentifier: FilterIdentity.extensionIdentifier, queue: .main)
                    request.delegate = self
                    OSSystemExtensionManager.shared.submitRequest(request)
                    // Deactivation can wait for a restart; the uninstall needn't.
                    completion()
                }
            }
        }
    }

    /// Once the extension is active, the filter's own configuration, which is
    /// what makes macOS ask to allow it.
    private func enableFilter() {
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { [weak self] _ in
            if manager.providerConfiguration == nil {
                let configuration = NEFilterProviderConfiguration()
                configuration.filterSockets = true
                configuration.filterPackets = false
                manager.providerConfiguration = configuration
            }
            manager.localizedDescription = "NetworkMonitor"
            manager.isEnabled = true
            manager.saveToPreferences { error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error {
                        self.state = .failed(error.localizedDescription)
                    } else {
                        self.state = .on
                        self.connect()
                    }
                }
            }
        }
    }

    // MARK: OSSystemExtensionRequestDelegate

    public func request(_ request: OSSystemExtensionRequest,
                        actionForReplacingExtension existing: OSSystemExtensionProperties,
                        withExtension replacement: OSSystemExtensionProperties)
        -> OSSystemExtensionRequest.ReplacementAction {
        // A new version of the app brings a new filter.
        .replace
    }

    public func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        state = .waitingForApproval
    }

    public func request(_ request: OSSystemExtensionRequest,
                        didFinishWithResult result: OSSystemExtensionRequest.Result) {
        if removing {
            removing = false
            state = .off
        } else {
            enableFilter()
        }
    }

    public func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        removing = false
        state = .failed(error.localizedDescription)
    }

    // MARK: The connection

    private func connect() {
        guard connection == nil else { return }
        let connection = NSXPCConnection(machServiceName: FilterIdentity.machServiceName, options: [])
        connection.setCodeSigningRequirement(FilterIdentity.extensionRequirement)
        connection.remoteObjectInterface = NSXPCInterface(with: FilterExtensionInterface.self)
        connection.exportedInterface = NSXPCInterface(with: FilterAppInterface.self)
        connection.exportedObject = self
        // The filter restarts with each new version, and when macOS stops it.
        // While it's meant to be on, keep trying to reach it.
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.connection = nil
                guard self.state == .on else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    if self?.state == .on { self?.connect() }
                }
            }
        }
        connection.interruptionHandler = { [weak connection] in
            (connection?.remoteObjectProxyWithErrorHandler { _ in } as? FilterExtensionInterface)?.register { _ in }
        }
        connection.resume()
        self.connection = connection
        // The first message opens the connection the filter reports over.
        (connection.remoteObjectProxyWithErrorHandler { _ in } as? FilterExtensionInterface)?.register { _ in }
    }

    private func disconnect() {
        connection?.invalidate()
        connection = nil
    }

    public func flowsSeen(_ reports: Data) {
        let flows = FlowReport.decode(reports)
        guard !flows.isEmpty else { return }
        DispatchQueue.main.async { self.flows.send(flows) }
    }
}
