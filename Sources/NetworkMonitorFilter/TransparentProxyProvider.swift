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
import SystemConfiguration

/// Enhanced ad blocking's transparent proxy (#702, a step of #256): macOS
/// hands it every new connection to port 443, TCP and UDP, and it decides as
/// `EnhancedBlocking` says. A connection it leaves goes on as if it weren't
/// here; one it opens goes through the secure bridge (#701), which removes
/// the page's ads; a browser's QUIC is refused, so the browser uses TCP.
///
/// It fails towards working: with the switch off, without its root, or with
/// no bridge, it takes nothing, and a connection it took but can't bridge
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

/// The proxy's state: the bridge once it's ready, and the apps found to
/// refuse our certificate.
final class EnhancedProxy {

    static let shared = EnhancedProxy()

    private let lock = NSLock()
    private var bridge: SecureBridge?
    private var preparing = false
    /// Apps found to refuse our certificate while it ran (they pin their
    /// own): left alone from then on. The app keeps them for good with #685.
    private var pinned: Set<String> = []
    /// Which app last opened each site, to know whose refusal a bridge event is.
    private var openedBy: [String: String] = [:]
    private static let openedLimit = 4_096
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

    /// The root, from the System keychain or made there, and the bridge:
    /// made once, away from the flows.
    func prepare() {
        lock.lock()
        guard bridge == nil, !preparing else { lock.unlock(); return }
        preparing = true
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let made = makeBridge()
            lock.lock()
            bridge = made
            preparing = false
            lock.unlock()
        }
    }

    func stop() {
        lock.lock()
        let old = bridge
        bridge = nil
        lock.unlock()
        old?.stop()
    }

    private func makeBridge() -> SecureBridge? {
        do {
            let machine = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "this Mac"
            let (authority, made) = try AuthorityStore.load(machine: machine)
            log.notice("\(made ? "made a new root" : "using the kept root", privacy: .public)")
            let identities = try SiteIdentities(authority: authority, keychain: nil)
            let rules = Self.pageRules()
            if rules == nil { log.error("no page rules: pages go on without hiding") }
            return SecureBridge(identities: identities,
                                additions: { host in
                                    rules.map { PageAdditions($0.forPage(on: host)) }
                                        ?? PageAdditions(selectors: [], scriptlets: [])
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
        lock.lock(); defer { lock.unlock() }
        return bridge
    }

    // MARK: Flows

    func take(_ flow: NEAppProxyTCPFlow) -> Bool {
        guard let remote = flow.remoteEndpoint as? NWHostEndpoint, let port = Int(remote.port),
              let bridge = currentBridge else { return false }
        let settings = settings
        let app = flow.metaData.sourceAppSigningIdentifier
        switch settings.start(app: app, host: flow.remoteHostname, port: port) {
        case .leave:
            return false
        case .readName:
            ProxiedConnection(flow: flow, remote: remote, port: port, app: app, bridge: bridge, proxy: self).start()
            return true
        }
    }

    func take(_ flow: NEAppProxyUDPFlow) -> Bool {
        guard currentBridge != nil else { return false }
        let app = flow.metaData.sourceAppSigningIdentifier
        let port = EnhancedBlocking.proxiedPort
        guard settings.decide(app: app, host: flow.remoteHostname, port: port, isUDP: true) == .refuseQUIC else {
            return false
        }
        log.debug("refused QUIC from \(app, privacy: .public) to \(flow.remoteHostname ?? "an address", privacy: .public)")
        let refused = NSError(domain: NEAppProxyErrorDomain, code: NEAppProxyFlowError.refused.rawValue)
        flow.closeReadWithError(refused)
        flow.closeWriteWithError(refused)
        return true
    }

    func opened(_ host: String, by app: String) {
        lock.lock()
        if openedBy.count >= Self.openedLimit { openedBy.removeAll() }
        openedBy[host.lowercased()] = app
        lock.unlock()
    }

    private func note(_ event: BridgeEvent) {
        switch event {
        case .clientRefused(let host):
            lock.lock()
            let app = openedBy[host]
            if let app { pinned.insert(app) }
            lock.unlock()
            log.notice("\(app ?? "an app", privacy: .public) refused our certificate for \(host, privacy: .public); left alone from now on")
        case .serverRefused(let host):
            log.notice("\(host, privacy: .public)'s certificate isn't trusted: refused")
        case .rewritten(let host):
            log.notice("hid ads on a page from \(host, privacy: .public)")
        case .untouched(let host, let why):
            log.debug("a reply from \(host, privacy: .public) went on untouched: \(String(describing: why), privacy: .public)")
        }
    }
}

/// One TCP connection the proxy took: its first bytes read for the site's
/// name, then joined to the bridge, or to the site itself, both ways.
final class ProxiedConnection {
    private let flow: NEAppProxyTCPFlow
    private let remote: NWHostEndpoint
    private let port: Int
    private let app: String
    private let bridge: SecureBridge
    private let proxy: EnhancedProxy
    private var reader = HandshakeReader(.stream)
    private var first = Data()
    private var connection: NWConnection?
    private let lock = NSLock()
    private var upstreamDone = false
    private var downstreamDone = false
    private let closed = Once()
    private let named = Once()
    /// Its own order, over the proxy's threads.
    private let queue: DispatchQueue

    /// The longest the handshake is waited for: a browser sends it at once.
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
            if let error {
                log.error("couldn't open a connection: \(error.localizedDescription, privacy: .public)")
                return close()
            }
            readName()
        }
        queue.asyncAfter(deadline: .now() + Self.nameTimeout) { [self] in
            if named.first() { route(nil) }
        }
    }

    private func readName() {
        flow.readData { [self] data, error in
            guard error == nil, let data, !data.isEmpty else { return close() }
            let offset = first.count
            first.append(data)
            switch reader.read(at: offset, data) {
            case .peek: readName()
            case .done(let name): if named.first() { route(name) }
            }
        }
    }

    /// Decided again with the name: through the bridge, or on as it was.
    private func route(_ name: String?) {
        let decision = proxy.settings.decide(app: app, host: name, port: port, isUDP: false)
        guard decision == .open, let name, let sitePort = UInt16(exactly: port) else {
            return connect(to: original)
        }
        proxy.opened(name, by: app)
        bridge.port(for: name, sitePort: sitePort) { [self] bridgePort in
            guard let bridgePort, let loopback = Network.NWEndpoint.Port(rawValue: bridgePort) else {
                log.error("no bridge for \(name, privacy: .public): it goes on unchanged")
                return connect(to: original)
            }
            connect(to: .hostPort(host: "127.0.0.1", port: loopback))
        }
    }

    private var original: Network.NWEndpoint {
        .hostPort(host: .init(remote.hostname), port: Network.NWEndpoint.Port(rawValue: UInt16(port)) ?? .https)
    }

    private func connect(to endpoint: Network.NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                connection.send(content: first, completion: .contentProcessed { [self] error in
                    if error != nil { return close() }
                    first = Data()
                    upstream()
                })
                downstream()
            case .failed, .cancelled, .waiting:
                close()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// The browser's bytes on to the connection; its end, as the end of ours.
    private func upstream() {
        flow.readData { [self] data, error in
            guard let connection else { return }
            guard error == nil, let data, !data.isEmpty else {
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in })
                return finished(upstream: true)
            }
            connection.send(content: data, completion: .contentProcessed { [self] error in
                error == nil ? upstream() : close()
            })
        }
    }

    /// The other side's bytes back to the browser.
    private func downstream() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                flow.write(data) { [self] error in
                    if error != nil { return close() }
                    if isComplete { endDownstream() } else { downstream() }
                }
            } else if isComplete || error != nil {
                endDownstream()
            } else {
                downstream()
            }
        }
    }

    private func endDownstream() {
        flow.closeWriteWithError(nil)
        finished(upstream: false)
    }

    private func finished(upstream: Bool) {
        lock.lock()
        if upstream { upstreamDone = true } else { downstreamDone = true }
        let both = upstreamDone && downstreamDone
        lock.unlock()
        if both { close() }
    }

    private func close() {
        guard closed.first() else { return }
        connection?.cancel()
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
    }
}
