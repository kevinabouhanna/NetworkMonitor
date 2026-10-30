import Combine
import FilterProtocol
import FirewallPolicy
import Foundation
import NetworkExtension
import SystemExtensions

/// The app's side of the content filter (#128): installing the system
/// extension, switching the filter on and off, removing it, and receiving
/// what it saw.
///
/// Nothing happens until someone turns it on, in the welcome window or
/// Settings › Connections (#134). Then macOS asks twice: once to allow the
/// system extension (in System Settings), once to allow the filter. From then
/// on it runs in the background. Turned off, the extension stays installed but
/// filters nothing; uninstalling NetworkMonitor removes it.
public final class FilterController: NSObject, ObservableObject, OSSystemExtensionRequestDelegate,
                                     FilterAppInterface {

    public enum State: Equatable {
        /// Not built in: a build without the Developer ID.
        case unavailable
        case off
        /// macOS only installs system extensions from the Applications folder.
        case needsApplicationsFolder
        /// Turned on, before macOS says what it needs.
        case starting
        /// Waiting for the person to allow the extension in System Settings.
        case waitingForApproval
        /// Allowed there; now the filter itself, which macOS asks about too.
        case confirming
        case on
        case failed(String)
    }

    @Published public private(set) var state: State
    /// False until `resume()` has found out whether the filter was left on,
    /// so the welcome window doesn't offer what's already there.
    @Published public private(set) var hasResolved: Bool

    /// Each batch the filter reports, on the main queue.
    public let flows = PassthroughSubject<[FlowReport], Never>()
    /// Ask Me's questions (#129), and those nobody answered in time, on the
    /// main queue.
    public let questions = PassthroughSubject<FlowQuestion, Never>()
    public let expiredQuestions = PassthroughSubject<String, Never>()

    private var connection: NSXPCConnection?
    /// What the filter should enforce (#114), sent each time it connects.
    private var policy = FirewallPolicy()
    private var removing = false
    /// Set while the launch's request brings the running filter up to this
    /// build's (#136).
    private var updating = false

    /// The filter is in the app only when it was signed with the Developer ID
    /// and its profiles; see `Scripts/bundle.sh`.
    public static var isBundled: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundlePath
            + "/Contents/Library/SystemExtensions/\(FilterIdentity.extensionIdentifier).systemextension")
    }

    /// Whether the app runs from the Applications folder, the only place
    /// macOS installs a system extension from.
    public static var isInApplications: Bool {
        Bundle.main.bundleURL.standardizedFileURL.deletingLastPathComponent().path == "/Applications"
    }

    /// Off, or why it can't be turned on yet.
    private static var offState: State {
        guard isBundled else { return .unavailable }
        return isInApplications ? .off : .needsApplicationsFolder
    }

    public override init() {
        state = Self.offState
        hasResolved = !Self.isBundled
        super.init()
    }

    /// At launch: if the filter was left on, reconnect to it, and bring it up
    /// to this build's. And from then on, follow it being switched off or on
    /// in System Settings.
    public func resume() {
        guard Self.isBundled else { return }
        NotificationCenter.default.addObserver(forName: .NEFilterConfigurationDidChange,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.followConfiguration()
        }
        NEFilterManager.shared().loadFromPreferences { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if NEFilterManager.shared().isEnabled {
                    // Connected only once the update is through: held open
                    // across the swap, the old filter kept its service name,
                    // and the new one came up without it (#114).
                    self.state = .on
                    self.update()
                }
                self.hasResolved = true
            }
        }
    }

    /// Only between on and off: while it's being turned on, the change is
    /// the app's own.
    private func followConfiguration() {
        guard state == .on || state == .off else { return }
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.state == .on || self.state == .off else { return }
                if manager.isEnabled, self.state == .off {
                    self.state = .on
                    self.connect()
                } else if !manager.isEnabled, self.state == .on {
                    self.disconnect()
                    self.state = Self.offState
                }
            }
        }
    }

    /// macOS keeps running the extension it last activated until the app
    /// asks for another (#136). The same version is a no-op; another is
    /// replaced, and the person is asked nothing.
    private func update() {
        updating = true
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: FilterIdentity.extensionIdentifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    // MARK: Switching

    public func turnOn() {
        guard Self.isBundled, Self.isInApplications else { return }
        state = .starting
        removing = false
        updating = false
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
                    self?.state = Self.offState
                }
            }
        }
    }

    /// For Uninstall: the filter's configuration and the extension both go.
    public func remove(completion: @escaping () -> Void) {
        guard Self.isBundled else { completion(); return }
        disconnect()
        removing = true
        updating = false
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
            // macOS asks only about a filter it hasn't been told about.
            let asks = manager.providerConfiguration == nil
            DispatchQueue.main.async { self?.state = asks ? .confirming : .starting }
            if asks {
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
                        self.state = Self.state(after: error) ?? Self.offState
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
            state = Self.offState
        } else if updating {
            // Still on. A replaced filter dropped its connection, which
            // reconnects by itself; one that was asked to approve is back.
            updating = false
            state = .on
            connect()
        } else {
            enableFilter()
        }
    }

    public func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        if removing {
            removing = false
            state = Self.offState
        } else if updating {
            // The filter already running carries on.
            updating = false
            if state == .waitingForApproval { state = .on }
            connect()
        } else if let next = Self.state(after: error) {
            state = next
        }
    }

    /// Where a failed request leaves things, in the person's terms. Nil keeps
    /// the state as it is: a request replaced by a newer one isn't a failure.
    public static func state(after error: Error) -> State? {
        let error = error as NSError
        switch (error.domain, error.code) {
        case (OSSystemExtensionErrorDomain, OSSystemExtensionError.requestSuperseded.rawValue):
            return nil
        case (OSSystemExtensionErrorDomain, OSSystemExtensionError.unsupportedParentBundleLocation.rawValue):
            return .needsApplicationsFolder
        // Cancelled, or Don't Allow: an answer, not an error.
        case (OSSystemExtensionErrorDomain, OSSystemExtensionError.requestCanceled.rawValue),
             (NEFilterErrorDomain, NEFilterManagerError.configurationPermissionDenied.rawValue):
            return offState
        default:
            return .failed(error.localizedDescription)
        }
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
        // The filter restarted under the same connection: open it again, and
        // hand over the rules.
        connection.interruptionHandler = { [weak self, weak connection] in
            (connection?.remoteObjectProxyWithErrorHandler { _ in } as? FilterExtensionInterface)?.register { _ in }
            DispatchQueue.main.async { self?.sendPolicy() }
        }
        connection.resume()
        self.connection = connection
        // The first message opens the connection the filter reports over.
        (connection.remoteObjectProxyWithErrorHandler { _ in } as? FilterExtensionInterface)?.register { _ in }
        sendPolicy()
    }

    // MARK: The rules

    /// The rules, the mode and the hotspot state, for the filter to enforce
    /// (#114). It keeps its own copy, so they apply even before the app
    /// connects after a restart.
    public func apply(_ policy: FirewallPolicy) {
        guard policy != self.policy else { return }
        self.policy = policy
        sendPolicy()
    }

    private func sendPolicy() {
        (connection?.remoteObjectProxyWithErrorHandler { _ in } as? FilterExtensionInterface)?
            .applyPolicy(policy.encoded())
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

    public func ask(_ question: Data) {
        guard let question = FlowQuestion.decode(question) else { return }
        DispatchQueue.main.async { self.questions.send(question) }
    }

    public func questionExpired(_ id: String) {
        DispatchQueue.main.async { self.expiredQuestions.send(id) }
    }

    /// The person's answer, for the filter to resume what it's holding.
    public func answer(_ id: String, _ answer: FlowAnswer) {
        (connection?.remoteObjectProxyWithErrorHandler { _ in } as? FilterExtensionInterface)?
            .answer(id, answer.rawValue)
    }
}
