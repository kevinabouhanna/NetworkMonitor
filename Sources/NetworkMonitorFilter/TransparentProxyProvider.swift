import FilterProtocol
import FirewallPolicy
import Foundation
import HandshakeName
import Network
import NetworkExtension
import os
import PageRewriter
import SecureBridge
import SiteCertificates
import SwiftASN1
import SystemConfiguration
import X509

/// Enhanced ad blocking's transparent proxy (#702, a step of #256): macOS
/// hands it every new connection to port 443, TCP and UDP, and it decides as
/// `EnhancedBlocking` says. A connection it leaves goes on as if it weren't
/// here; one it opens goes through the secure bridge (#701), which removes
/// the page's ads; a browser's QUIC is refused, so the browser uses TCP.
///
/// It fails towards working: with the switch off, without a root macOS
/// trusts, or with no bridge, it takes nothing, and a connection it took but can't bridge
/// goes on to the site unchanged.
///
/// Named for the Objective-C runtime, as the Info.plist's
/// `NEProviderClasses` names it.
@objc(TransparentProxyProvider)
final class TransparentProxyProvider: NETransparentProxyProvider {

    static let log = Logger(subsystem: FilterIdentity.extensionIdentifier, category: "enhanced")

    override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.includedNetworkRules = Self.rules
        setTunnelNetworkSettings(settings) { error in
            if let error {
                Self.log.error("couldn't start: \(error.localizedDescription, privacy: .public)")
            } else {
                Self.log.notice("started")
                EnhancedProxy.shared.prepare()
            }
            completionHandler(error)
        }
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        Self.log.notice("stopped: \(reason.rawValue)")
        EnhancedProxy.shared.stop()
        completionHandler()
    }

    /// Outgoing connections to port 443, any address, TCP and UDP.
    static var rules: [NENetworkRule] {
        ([.TCP, .UDP] as [NENetworkRule.`Protocol`]).flatMap { transport in
            ["0.0.0.0", "::"].map { any in
                NENetworkRule(remoteNetwork: NWHostEndpoint(hostname: any, port: String(EnhancedBlocking.proxiedPort)),
                              remotePrefix: 0, localNetwork: nil, localPrefix: 0,
                              protocol: transport, direction: .outbound)
            }
        }
    }

    /// UDP flows come here too, as `handleNewUDPFlow` isn't overridden:
    /// only to port 443, as the rules say.
    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        if let tcp = flow as? NEAppProxyTCPFlow { return EnhancedProxy.shared.take(tcp) }
        if let udp = flow as? NEAppProxyUDPFlow { return EnhancedProxy.shared.take(udp) }
        return false
    }
}

/// The proxy's state: the bridge once its root is trusted, and the apps found
/// to refuse our certificate.
final class EnhancedProxy {

    static let shared = EnhancedProxy()

    private let lock = NSLock()
    private var bridge: SecureBridge?
    private var preparing = false
    /// Counts each start and stop, so a bridge made for a run that has
    /// stopped since is dropped.
    private var generation = 0
    private var lastTry: Date?
    /// How often a missing bridge is tried again: the root may be trusted since.
    static let retry: TimeInterval = 30
    /// Apps found to refuse our certificate while it ran (they pin their
    /// own): left alone from then on, and sent to the app, which keeps them
    /// for good (#685). Once the policy carries one, it's the policy's.
    private var pinned: Set<String> = []
    /// Whether the switch was on in the last policy, nil before the first.
    private var wasOn: Bool?
    private var trustedRoot: String?
    /// The apps the last policy kept for good: one it no longer keeps was
    /// tried again (Try Again), and is forgotten here too.
    private var keptByApp: Set<String> = []
    /// Making the root and taking it out, one after the other, never at once.
    private let keychainWork = DispatchQueue(label: "com.kevinabouhanna.NetworkMonitor.Filter.keychain",
                                             qos: .userInitiated)
    /// The app behind each connection to the bridge, by its loopback port,
    /// so a refusal is put down to the app that refused.
    private var appsByPort: [UInt16: String] = [:]
    let queue = DispatchQueue(label: "com.kevinabouhanna.NetworkMonitor.Filter.enhanced", qos: .userInitiated,
                              attributes: .concurrent)

    private var log: Logger { TransparentProxyProvider.log }

    /// The settings, with the apps found pinning added.
    var settings: EnhancedBlocking {
        var settings = Firewall.shared.enhancedBlocking
        lock.lock()
        settings.pinnedApps.formUnion(pinned)
        lock.unlock()
        return settings
    }

    /// The root, from the System keychain or made there, and the bridge once
    /// macOS trusts it: made away from the flows, and tried again while
    /// there's none.
    func prepare() {
        lock.lock()
        if bridge != nil || preparing || lastTry.map({ Date().timeIntervalSince($0) < Self.retry }) == true {
            lock.unlock()
            return
        }
        preparing = true
        lastTry = Date()
        let run = generation
        lock.unlock()
        keychainWork.async { [self] in
            let made = makeBridge()
            lock.lock()
            preparing = false
            let current = run == generation
            if current { bridge = made }
            lock.unlock()
            if !current { made?.stop() }
        }
    }

    /// A new policy from the app (#685): the apps it now keeps for good are
    /// its own, the rest sent again; a root the person just approved is
    /// tried at once; and switched off, the root, its key and the sites'
    /// certificates are taken out of the System keychain, so nothing is left.
    func apply(_ settings: EnhancedBlocking) {
        lock.lock()
        pinned.subtract(settings.pinnedApps)
        pinned.subtract(keptByApp.subtracting(settings.pinnedApps))
        keptByApp = settings.pinnedApps
        let unsent = pinned
        let switchedOff = !settings.isOn && wasOn != false
        let approved = settings.isOn && settings.trustedRoot != nil && settings.trustedRoot != trustedRoot
        wasOn = settings.isOn
        trustedRoot = settings.trustedRoot
        if approved, bridge == nil { lastTry = nil }
        lock.unlock()
        AppLink.shared.leftAlone(unsent)
        if switchedOff {
            stop()
            keychainWork.async { [self] in removeEverything() }
        } else if approved {
            prepare()
        }
    }

    /// The root, its key, the sites' key and their certificates, out of the
    /// System keychain: none of them is left once the switch is off.
    /// Only while the switch is still off: switched on again meanwhile, the
    /// root is kept, and used again.
    private func removeEverything() {
        lock.lock()
        let stillOff = wasOn == false
        lock.unlock()
        guard stillOff else { return }
        var system: SecKeychain?
        guard SecKeychainCopyDomainDefault(.system, &system) == errSecSuccess, let system else { return }
        guard !AuthorityStore.certificates(in: system).isEmpty || !AuthorityKey.find(in: system).isEmpty
                || SiteIdentities.hasAny(in: system) else { return }
        let rootGone = AuthorityStore.remove(from: system)
        let sitesGone = SiteIdentities.remove(from: system)
        log.notice("switched off: the root and the sites' certificates \(rootGone && sitesGone ? "removed" : "not all removed", privacy: .public)")
    }

    func stop() {
        lock.lock()
        let old = bridge
        bridge = nil
        generation += 1
        lastTry = nil
        lock.unlock()
        old?.stop()
    }

    private func makeBridge() -> SecureBridge? {
        do {
            let machine = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "this Mac"
            // The System keychain by name: the default search list can
            // name it twice, and every item is found twice.
            var system: SecKeychain?
            guard SecKeychainCopyDomainDefault(.system, &system) == errSecSuccess, let system else {
                log.error("no System keychain, so nothing is opened")
                return nil
            }
            if case .missing(let why) = AuthorityStore.lookUp(in: system) {
                log.notice("no root to use (\(why, privacy: .public)): making one")
            }
            let (authority, _) = try AuthorityStore.load(in: system, machine: machine)
            // A root macOS doesn't trust would show every page a certificate
            // error: until it's trusted, nothing is opened.
            let probe = try authority.issue(for: "trust-check.invalid", key: authority.certificate.publicKey)
            guard let probeCertificate = SecCertificateCreateWithData(nil, try DERData.of(probe) as CFData),
                  let rootCertificate = SecCertificateCreateWithData(nil, try authority.der() as CFData),
                  ServerTrust.isTrusted([probeCertificate, rootCertificate], host: "trust-check.invalid") else {
                log.notice("the root isn't trusted yet, so nothing is opened")
                return nil
            }
            let identities = try SiteIdentities(authority: authority, keychain: system)
            let rules = Self.pageRules()
            if rules == nil { log.error("no page rules: pages go on without hiding") }
            log.notice("ready, with the trusted root")
            return SecureBridge(identities: identities,
                                additions: { host in
                                    rules.map { PageAdditions($0.forPage(on: host)) }
                                        ?? PageAdditions(selectors: [], scriptlets: [])
                                },
                                refuses: { request in
                                    rules.map { Firewall.shared.enhancedBlocking.refuses(request, by: $0.addresses) } ?? false
                                },
                                events: { [weak self] in self?.note($0) })
        } catch {
            log.error("no bridge, so nothing is opened: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The page rules shipped in the extension (`pages.bin`, bundle.sh).
    static func pageRules() -> PageRules? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Blocklists/\(PageRules.fileName)"),
              let data = try? Data(contentsOf: url) else { return nil }
        return PageRules.decode(data)
    }

    private var currentBridge: SecureBridge? {
        lock.lock()
        let bridge = bridge
        lock.unlock()
        if bridge == nil { prepare() }
        return bridge
    }

    // MARK: Flows

    func take(_ flow: NEAppProxyTCPFlow) -> Bool {
        guard let remote = flow.remoteEndpoint as? NWHostEndpoint, let port = Int(remote.port) else { return false }
        let settings = settings
        let app = flow.metaData.sourceAppSigningIdentifier
        guard settings.isOn, let bridge = currentBridge else { return false }
        switch settings.start(app: app, host: flow.remoteHostname, port: port) {
        case .leave(let reason):
            if EnhancedBlocking.matches(app, in: settings.apps) {
                log.debug("left \(flow.remoteHostname ?? remote.hostname, privacy: .public) alone: \(String(describing: reason), privacy: .public)")
            }
            return false
        case .readName:
            ProxiedConnection(flow: flow, remote: remote, port: port, app: app, bridge: bridge, proxy: self).start()
            return true
        }
    }

    /// A browser's QUIC, refused once it's opened, so the browser hears at
    /// once and uses TCP.
    func take(_ flow: NEAppProxyUDPFlow) -> Bool {
        let settings = settings
        guard settings.isOn, currentBridge != nil else { return false }
        let app = flow.metaData.sourceAppSigningIdentifier
        let port = EnhancedBlocking.proxiedPort
        guard settings.decide(app: app, host: flow.remoteHostname, port: port, isUDP: true) == .refuseQUIC else {
            return false
        }
        log.debug("refused QUIC from \(app, privacy: .public) to \(flow.remoteHostname ?? "an address", privacy: .public)")
        let refused = NSError(domain: NEAppProxyErrorDomain, code: NEAppProxyFlowError.refused.rawValue)
        flow.open(withLocalEndpoint: nil) { _ in
            flow.closeReadWithError(refused)
            flow.closeWriteWithError(refused)
        }
        return true
    }

    /// A connection to the bridge from `port`, for `app`; forgotten a while
    /// after it closes, as the bridge's report of a refusal can come after.
    func bridging(from port: UInt16, for app: String) {
        lock.lock()
        appsByPort[port] = app
        lock.unlock()
    }

    func bridged(from port: UInt16) {
        queue.asyncAfter(deadline: .now() + 10) { [self] in
            lock.lock()
            appsByPort.removeValue(forKey: port)
            lock.unlock()
        }
    }

    private func note(_ event: BridgeEvent) {
        switch event {
        case .clientRefused(let host, let clientPort):
            lock.lock()
            let app = clientPort.flatMap { appsByPort[$0] }
            if let app { pinned.insert(app) }
            lock.unlock()
            // Only the new one: one sent before may have been tried again since.
            if let app { AppLink.shared.leftAlone([app]) }
            log.notice("\(app ?? "an app", privacy: .public) refused our certificate for \(host, privacy: .public); left alone from now on")
        case .serverRefused(let host):
            log.notice("\(host, privacy: .public)'s certificate isn't trusted: refused")
        case .rewritten(let host):
            log.notice("hid ads on a page from \(host, privacy: .public)")
        case .answeredEmpty(let host):
            log.debug("answered a request to \(host, privacy: .public) empty: its address is an ad's or a tracker's")
        case .untouched(let host, let why):
            log.debug("a reply from \(host, privacy: .public) went on untouched: \(String(describing: why), privacy: .public)")
        }
    }
}

/// A certificate as DER.
enum DERData {
    static func of(_ certificate: Certificate) throws -> Data {
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        return Data(serializer.serializedBytes)
    }
}

/// One TCP connection the proxy took: its first bytes read for the site's
/// name, then joined to the bridge, or to the site itself, both ways.
///
/// Its state is only ever touched on its own serial queue: every callback
/// from the flow, the bridge and the connection hops onto it first. One read
/// of the flow is outstanding at a time, whatever the phase.
final class ProxiedConnection {
    private enum Phase { case naming, connecting, relaying, closed }

    private let flow: NEAppProxyTCPFlow
    private let remote: NWHostEndpoint
    private let port: Int
    private let app: String
    private let bridge: SecureBridge
    private let proxy: EnhancedProxy
    private let queue: DispatchQueue

    private var phase = Phase.naming
    private var reader = HandshakeReader(.stream)
    /// The browser's bytes read before the other side was ready.
    private var first = Data()
    private var reading = false
    private var connection: NWConnection?
    private var bridgePort: UInt16?
    private var upstreamDone = false
    private var downstreamDone = false

    /// The longest the handshake is waited for. A browser connecting ahead
    /// of time may say nothing for longer: then it goes on to the site
    /// unchanged, and whatever it sends later follows.
    static let nameTimeout: TimeInterval = 10

    private var log: Logger { TransparentProxyProvider.log }

    init(flow: NEAppProxyTCPFlow, remote: NWHostEndpoint, port: Int, app: String,
         bridge: SecureBridge, proxy: EnhancedProxy) {
        self.flow = flow
        self.remote = remote
        self.port = port
        self.app = app
        self.bridge = bridge
        self.proxy = proxy
        queue = DispatchQueue(label: "com.kevinabouhanna.NetworkMonitor.Filter.connection", target: proxy.queue)
    }

    func start() {
        flow.open(withLocalEndpoint: nil) { [self] error in
            queue.async { [self] in
                if let error {
                    log.error("couldn't open a connection: \(error.localizedDescription, privacy: .public)")
                    return close()
                }
                readNext()
            }
        }
        queue.asyncAfter(deadline: .now() + Self.nameTimeout) { [self] in
            if phase == .naming { route(nil) }
        }
    }

    // MARK: Reading the browser

    private func readNext() {
        guard !reading, phase != .closed else { return }
        reading = true
        flow.readData { [self] data, error in
            queue.async { [self] in
                reading = false
                received(error == nil ? data : nil)
            }
        }
    }

    /// The browser's next bytes, or nil at its end.
    private func received(_ data: Data?) {
        guard let data, !data.isEmpty else { return browserEnded() }
        switch phase {
        case .naming:
            let offset = first.count
            first.append(data)
            switch reader.read(at: offset, data) {
            case .peek: readNext()
            case .done(let name): route(name)
            }
        case .connecting:
            first.append(data)
            readNext()
        case .relaying:
            connection?.send(content: data, completion: .contentProcessed { [self] error in
                queue.async { [self] in error == nil ? readNext() : close() }
            })
        case .closed:
            break
        }
    }

    private func browserEnded() {
        switch phase {
        case .naming, .connecting:
            close()
        case .relaying:
            connection?.send(content: nil, contentContext: .finalMessage, isComplete: true,
                             completion: .contentProcessed { _ in })
            upstreamDone = true
            if downstreamDone { close() }
        case .closed:
            break
        }
    }

    // MARK: The other side

    /// Decided again with the name: through the bridge, or on as it was.
    private func route(_ name: String?) {
        guard phase == .naming else { return }
        phase = .connecting
        let decision = proxy.settings.decide(app: app, host: name, port: port, isUDP: false)
        guard decision == .open, let name, let sitePort = UInt16(exactly: port) else {
            log.debug("passed \(name ?? self.remote.hostname, privacy: .public) on unchanged: \(String(describing: decision), privacy: .public)")
            return connect(to: original, bridged: false)
        }
        bridge.port(for: name, sitePort: sitePort) { [self] bridgePort in
            queue.async { [self] in
                guard let bridgePort, let loopback = Network.NWEndpoint.Port(rawValue: bridgePort) else {
                    log.error("no bridge for \(name, privacy: .public): it goes on unchanged")
                    return connect(to: original, bridged: false)
                }
                connect(to: .hostPort(host: "127.0.0.1", port: loopback), bridged: true)
            }
        }
    }

    private var original: Network.NWEndpoint {
        .hostPort(host: .init(remote.hostname), port: Network.NWEndpoint.Port(rawValue: UInt16(port)) ?? .https)
    }

    private func connect(to endpoint: Network.NWEndpoint, bridged: Bool) {
        guard phase == .connecting else { return }
        let connection = NWConnection(to: endpoint, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                guard phase == .connecting else { return }
                if bridged, case .hostPort(_, let local)? = connection.currentPath?.localEndpoint {
                    bridgePort = local.rawValue
                    proxy.bridging(from: local.rawValue, for: app)
                }
                // In order: what was read so far, then each read after it.
                phase = .relaying
                let pending = first
                first = Data()
                if !pending.isEmpty {
                    connection.send(content: pending, completion: .contentProcessed { [self] error in
                        if error != nil { queue.async { [self] in close() } }
                    })
                }
                readNext()
                downstream()
            case .failed, .cancelled, .waiting:
                close()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// The other side's bytes back to the browser.
    private func downstream() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            guard phase == .relaying else { return }
            if let data, !data.isEmpty {
                flow.write(data) { [self] error in
                    queue.async { [self] in
                        if error != nil { return close() }
                        if isComplete { otherSideEnded() } else { downstream() }
                    }
                }
            } else if isComplete || error != nil {
                otherSideEnded()
            } else {
                downstream()
            }
        }
    }

    private func otherSideEnded() {
        flow.closeWriteWithError(nil)
        downstreamDone = true
        if upstreamDone { close() }
    }

    private func close() {
        guard phase != .closed else { return }
        phase = .closed
        // Its handler holds this connection: let it go.
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        if let bridgePort { proxy.bridged(from: bridgePort) }
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
    }
}
