import Combine
import FilterProtocol
import FirewallPolicy
import Foundation
import NetworkExtension
import os
import SystemExtensions

/// The app's side of the content filter (#128): installing the system
/// extension, switching the filter on and off, removing it, and receiving
/// what it saw.
///
/// Nothing happens until someone turns it on, in the welcome window or
/// Settings › Connections (#134). Then macOS asks twice: once to allow the
/// system extension (in System Settings), once to allow the filter. From then
/// on it runs in the background. Turned off, which is done in System Settings
/// (#181), the extension stays installed but filters nothing; uninstalling
/// NetworkMonitor removes it.
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

        /// Whether it's offered, in the welcome window and where it's used:
        /// until it's on, when there's nothing left to manage (#181), and
        /// never in a build that can't have it.
        public var isOffered: Bool { self != .unavailable && self != .on }
    }

    @Published public private(set) var state: State {
        didSet {
            guard state != oldValue else { return }
            Self.log.notice("filter \(String(describing: oldValue), privacy: .public) → \(String(describing: self.state), privacy: .public)")
            state == .on ? startWatching() : stopWatching()
        }
    }
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
    /// A month of data newer than the filter shipped with (#121), sent each
    /// time it connects; the filter ignores one it already has.
    private var geoData: (directory: URL, month: String)?
    /// The newest lists (#176), for the filter to keep its own copy of.
    private var blocklists: (directory: URL, version: String)?
    /// The downloaded lists in use (#254), in one file.
    private var downloadedLists: (file: URL, version: String)?
    private var removing = false
    /// Set while the launch's request brings the running filter up to this
    /// build's (#136).
    private var updating = false
    /// Set while the watchdog switches the filter off and on (#272), so that
    /// isn't taken for the person doing it in System Settings.
    private var restarting = false
    private var watchdog = FilterWatchdog()
    private var watchTimer: Timer?

    /// Where an update's swap of the filter has got to (#278): the running
    /// filter is switched off, replaced, then switched on again, so the new
    /// one starts a session of its own instead of taking over a live one.
    private enum Swap { case switchingOff, replacing, switchingOn }
    private var swap: Swap?
    /// Whether the router answered just before the swap, so the guard knows
    /// a silence after it is the swap's doing.
    private var routerAnsweredBefore: Bool?
    private var updateGuard: UpdateGuard?
    private var guardTimer: Timer?
    /// The request whose answer counts: one the app cancelled, or replaced
    /// with another, answers too, and is ignored.
    private var activeRequest: OSSystemExtensionRequest?
    /// Set while the filter is off for an update, so a launch after one cut
    /// short (the app quit or crashed) switches it back on.
    static let offForUpdateKey = "filterOffForUpdate"
    /// The DNS proxy (#291) lives in the same extension: off for the swap too,
    /// and on again after.
    static let lookupsOffForUpdateKey = "lookupsOffForUpdate"

    static let log = Logger(subsystem: "com.kevinabouhanna.NetworkMonitor", category: "filter")

    /// The filter is in the app only when it was signed with the Developer ID
    /// and its profiles; see `Scripts/bundle.sh`.
    public static var isBundled: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundlePath
            + "/Contents/Library/SystemExtensions/\(FilterIdentity.extensionIdentifier).systemextension")
    }

    /// The service of the filter this app ships, which is the one macOS was
    /// asked to run (#142).
    static var machServiceName: String {
        let path = Bundle.main.bundlePath
            + "/Contents/Library/SystemExtensions/\(FilterIdentity.extensionIdentifier).systemextension"
        return FilterIdentity.machServiceName(inInfo: Bundle(path: path)?.infoDictionary)
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

    #if DEBUG
    /// For DesignShots' pictures (#437): says the filter is in `state`
    /// without asking macOS anything, and watches nothing. Debug builds only;
    /// the app is always built for release.
    public func showForPictures(_ state: State) {
        self.state = state
        hasResolved = true
        stopWatching()
    }
    #endif

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
                let manager = NEFilterManager.shared()
                if !manager.isEnabled, UserDefaults.standard.bool(forKey: Self.offForUpdateKey),
                   manager.providerConfiguration != nil {
                    Self.log.notice("the filter was left off partway through an update; switching it back on")
                    self.state = .on
                    self.restarting = true
                    self.setFilterEnabled(true) { error in
                        self.restarting = false
                        if let error {
                            Self.log.error("switching the filter back on failed: \(error.localizedDescription, privacy: .public)")
                            self.state = .failed(error.localizedDescription)
                        } else {
                            UserDefaults.standard.removeObject(forKey: Self.offForUpdateKey)
                            Self.setLookupsEnabled(true)
                            self.update()
                        }
                    }
                } else if manager.isEnabled {
                    UserDefaults.standard.removeObject(forKey: Self.offForUpdateKey)
                    // Lookups switched off for an update cut short come back.
                    Self.setLookupsEnabled(true)
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
        guard !restarting, state == .on || state == .off else { return }
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.restarting, self.state == .on || self.state == .off else { return }
                if manager.isEnabled, self.state == .off {
                    self.state = .on
                    self.connect()
                } else if !manager.isEnabled, self.state == .on {
                    // Switched off by the person: not to be undone at launch.
                    UserDefaults.standard.removeObject(forKey: Self.offForUpdateKey)
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
        activate()
    }

    private func activate() {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: FilterIdentity.extensionIdentifier, queue: .main)
        request.delegate = self
        activeRequest = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Switches the filter's configuration on or off; `completion` runs on
    /// the main queue.
    private func setFilterEnabled(_ enabled: Bool, completion: @escaping (Error?) -> Void) {
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { error in
            guard error == nil else { DispatchQueue.main.async { completion(error) }; return }
            manager.isEnabled = enabled
            manager.saveToPreferences { error in DispatchQueue.main.async { completion(error) } }
        }
    }

    // MARK: Switching

    public func turnOn() {
        guard Self.isBundled, Self.isInApplications else { return }
        state = .starting
        removing = false
        updating = false
        activate()
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
                    self.activeRequest = request
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
        let versions = "\(existing.bundleShortVersion) (\(existing.bundleVersion)) with "
            + "\(replacement.bundleShortVersion) (\(replacement.bundleVersion))"
        // A new version of the app brings a new filter. While one is running,
        // switch it off first (#278): taking over a live filter's session
        // twice left macOS dropping every packet for minutes. Cancelled here,
        // and asked again once it's off.
        guard request === activeRequest, updating, swap == nil, state == .on else {
            Self.log.notice("replacing filter \(versions, privacy: .public)")
            return .replace
        }
        Self.log.notice("replacing filter \(versions, privacy: .public); switching it off first")
        activeRequest = nil
        switchOffForSwap()
        return .cancel
    }

    public func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        guard request === activeRequest else { return }
        state = .waitingForApproval
    }

    public func request(_ request: OSSystemExtensionRequest,
                        didFinishWithResult result: OSSystemExtensionRequest.Result) {
        guard request === activeRequest else { return }
        activeRequest = nil
        if removing {
            removing = false
            state = Self.offState
        } else if updating {
            updating = false
            // Replaced while off: switch the new one on.
            if swap != nil { switchOnAfterSwap(); return }
            // Still on. A replaced filter dropped its connection, which
            // reconnects by itself; one that was asked to approve is back.
            state = .on
            connect()
        } else {
            enableFilter()
        }
    }

    public func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        guard request === activeRequest else { return }
        activeRequest = nil
        if removing {
            removing = false
            state = Self.offState
        } else if updating, swap != nil {
            // The old filter is still installed: switch it back on.
            Self.log.error("replacing the filter failed: \(error.localizedDescription, privacy: .public)")
            updating = false
            switchOnAfterSwap()
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

    // MARK: An update's swap (#278)

    private func switchOffForSwap() {
        swap = .switchingOff
        restarting = true
        stopGuard()
        disconnect()
        UserDefaults.standard.set(true, forKey: Self.offForUpdateKey)
        logDropAll("before the update")
        UpdateGuard.routerAnswers { answered in
            DispatchQueue.main.async {
                self.routerAnsweredBefore = answered
                Self.setLookupsEnabled(false)
                self.setFilterEnabled(false) { error in
                    if let error {
                        // Replaced while it runs, as before #278.
                        Self.log.error("switching the filter off failed: \(error.localizedDescription, privacy: .public)")
                    } else {
                        Self.log.notice("filter off for the update")
                    }
                    self.swap = .replacing
                    self.activate()
                }
            }
        }
    }

    private func switchOnAfterSwap() {
        swap = .switchingOn
        logDropAll("with the new filter installed")
        Self.setLookupsEnabled(true)
        setFilterEnabled(true) { error in
            self.swap = nil
            self.restarting = false
            if let error {
                // Left set, so the next launch tries again.
                Self.log.error("switching the filter back on failed: \(error.localizedDescription, privacy: .public)")
                self.state = .failed(error.localizedDescription)
                return
            }
            UserDefaults.standard.removeObject(forKey: Self.offForUpdateKey)
            Self.log.notice("filter back on after the update")
            self.state = .on
            self.watchdog.heard()
            self.connect()
            self.startGuard()
        }
    }

    /// Two minutes of asking the router, if it answered before the swap.
    private func startGuard() {
        let answeredBefore = routerAnsweredBefore
        routerAnsweredBefore = nil
        guard answeredBefore == true else {
            Self.log.notice("the router didn't answer before the update, so the network isn't checked after it")
            return
        }
        updateGuard = UpdateGuard()
        guardTimer?.invalidate()
        guardTimer = Timer.scheduledTimer(withTimeInterval: UpdateGuard.interval, repeats: true) { [weak self] _ in
            self?.checkAfterSwap()
        }
    }

    private func stopGuard() {
        guardTimer?.invalidate()
        guardTimer = nil
        updateGuard = nil
    }

    private func checkAfterSwap() {
        UpdateGuard.routerAnswers { answered in
            DispatchQueue.main.async {
                guard var check = self.updateGuard, self.state == .on, !self.restarting else { return }
                let action = check.checked(answered)
                self.updateGuard = check
                switch action {
                case .keepChecking:
                    if answered == false { Self.log.notice("the router didn't answer after the update") }
                case .done:
                    Self.log.notice("the network kept working after the update")
                    self.stopGuard()
                case .restart:
                    Self.log.error("the router stopped answering after the update; switching the filter off and on")
                    self.logDropAll("with the network cut off")
                    self.stopGuard()
                    self.restartFilter()
                }
            }
        }
    }

    /// Encrypted lookups off for an update, if they were on, or on again
    /// after it, if they were switched off for it. Remembered across a quit.
    static func setLookupsEnabled(_ on: Bool) {
        let defaults = UserDefaults.standard
        let manager = NEDNSProxyManager.shared()
        manager.loadFromPreferences { _ in
            if on {
                guard defaults.bool(forKey: lookupsOffForUpdateKey) else { return }
                defaults.removeObject(forKey: lookupsOffForUpdateKey)
            } else {
                guard manager.isEnabled else { return }
                defaults.set(true, forKey: lookupsOffForUpdateKey)
            }
            manager.isEnabled = on
            manager.saveToPreferences { error in
                log.notice("encrypted lookups \(on ? "on again" : "off", privacy: .public) for the update\(error.map { ": \($0.localizedDescription)" } ?? "", privacy: .public)")
            }
        }
    }

    private func logDropAll(_ when: String) {
        let level = UpdateGuard.dropAllLevel.map(String.init) ?? "unknown"
        Self.log.notice("drop-all level \(level, privacy: .public) \(when, privacy: .public)")
    }

    // MARK: The connection

    private func connect() {
        guard connection == nil else { return }
        Self.log.notice("connecting to \(Self.machServiceName, privacy: .public)")
        let connection = NSXPCConnection(machServiceName: Self.machServiceName, options: [])
        connection.setCodeSigningRequirement(FilterIdentity.extensionRequirement)
        connection.remoteObjectInterface = NSXPCInterface(with: FilterExtensionInterface.self)
        connection.exportedInterface = NSXPCInterface(with: FilterAppInterface.self)
        connection.exportedObject = self
        // The filter restarts with each new version, and when macOS stops it.
        // While it's meant to be on, keep trying to reach it.
        connection.invalidationHandler = { [weak self, weak connection] in
            DispatchQueue.main.async {
                guard let self else { return }
                Self.log.notice("connection to the filter invalidated")
                // Replaced already, by the watchdog's reconnecting (#272).
                if let current = self.connection, current !== connection { return }
                self.connection = nil
                guard self.state == .on else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, self.state == .on, !self.restarting else { return }
                    self.connect()
                }
            }
        }
        // The filter restarted under the same connection: open it again, and
        // hand over the rules.
        connection.interruptionHandler = { [weak self, weak connection] in
            Self.log.notice("connection to the filter interrupted; reopening it")
            (connection?.remoteObjectProxyWithErrorHandler { _ in } as? FilterExtensionInterface)?.register { _ in }
            DispatchQueue.main.async {
                self?.sendPolicy(); self?.sendGeoData(); self?.sendBlocklists(); self?.sendDownloadedLists()
            }
        }
        connection.resume()
        self.connection = connection
        // The first message opens the connection the filter reports over.
        (connection.remoteObjectProxyWithErrorHandler { _ in } as? FilterExtensionInterface)?.register { _ in }
        sendPolicy()
        sendGeoData()
        sendBlocklists()
        sendDownloadedLists()
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

    public func applyGeoData(at directory: URL, month: String) {
        geoData = (directory, month)
        sendGeoData()
    }

    private func sendGeoData() {
        guard let geoData, let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in })
                as? FilterExtensionInterface,
              let countries = try? FileHandle(forReadingFrom: geoData.directory.appendingPathComponent("countries.bin")),
              let owners = try? FileHandle(forReadingFrom: geoData.directory.appendingPathComponent("owners.bin"))
        else { return }
        proxy.applyGeoData(countries, owners, geoData.month)
    }

    /// Newer lists are in place (#176): the filter gets them as open files.
    public func applyBlocklists(at directory: URL, version: String) {
        blocklists = (directory, version)
        sendBlocklists()
    }

    private func sendBlocklists() {
        guard let blocklists, let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in })
                as? FilterExtensionInterface,
              let ads = try? FileHandle(forReadingFrom: blocklists.directory.appendingPathComponent(
                  BlocklistTopic.ads.fileName)),
              let malware = try? FileHandle(forReadingFrom: blocklists.directory.appendingPathComponent(
                  BlocklistTopic.malware.fileName))
        else { return }
        proxy.applyBlocklists(ads, malware, blocklists.version)
    }

    /// The downloaded lists in use changed (#254): the filter gets them as
    /// one open file.
    public func applyDownloadedLists(at file: URL, version: String) {
        downloadedLists = (file, version)
        sendDownloadedLists()
    }

    private func sendDownloadedLists() {
        guard let downloadedLists, let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in })
                as? FilterExtensionInterface,
              let handle = try? FileHandle(forReadingFrom: downloadedLists.file)
        else { return }
        proxy.applyDownloadedLists(handle, downloadedLists.version)
    }

    private func disconnect() {
        connection?.invalidate()
        connection = nil
    }

    public func flowsSeen(_ reports: Data) {
        let all = FlowReport.decode(reports)
        // The watchdog's test connections are the app's own, not the person's.
        let flows = all.filter { !FilterWatchdog.isProbe(address: $0.address, port: $0.port, pid: $0.pid) }
        DispatchQueue.main.async {
            self.watchdog.heard()
            if !flows.isEmpty { self.flows.send(flows) }
        }
    }

    // MARK: The watchdog (#272)

    private func startWatching() {
        watchdog = FilterWatchdog()
        watchTimer?.invalidate()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.watch() }
        watchTimer?.tolerance = 2
    }

    private func stopWatching() {
        watchTimer?.invalidate()
        watchTimer = nil
    }

    private func watch() {
        guard state == .on, !restarting else { return }
        switch watchdog.tick() {
        case .none:
            break
        case .probe:
            Self.log.notice("nothing heard from the filter for \(Int(FilterWatchdog.quiet))s; testing it")
            if !FilterWatchdog.startProbe() {
                Self.log.notice("the test connection couldn't start; no network to test on")
                watchdog.probeCouldNotStart()
            }
        case .reconnect:
            Self.log.error("the filter didn't report the test connection; reconnecting")
            disconnect()
            connect()
            if !FilterWatchdog.startProbe() { watchdog.probeCouldNotStart() }
        case .restart:
            Self.log.error("the filter is still silent; switching it off and on")
            restartFilter()
        }
    }

    /// Off and on again: macOS starts a new filter session, and with it
    /// hands the filter connections again.
    private func restartFilter() {
        restarting = true
        disconnect()
        let manager = NEFilterManager.shared()
        let finish: (Error?) -> Void = { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.restarting = false
                if let error {
                    Self.log.error("restarting the filter failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    Self.log.notice("filter restarted")
                }
                self.watchdog.heard()
                if self.state == .on { self.connect() }
            }
        }
        manager.loadFromPreferences { error in
            guard error == nil, manager.isEnabled else { finish(error); return }
            manager.isEnabled = false
            manager.saveToPreferences { error in
                guard error == nil else { finish(error); return }
                manager.isEnabled = true
                manager.saveToPreferences { error in finish(error) }
            }
        }
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
