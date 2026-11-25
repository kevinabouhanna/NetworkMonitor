import CryptoKit
import FirewallPolicy
import Foundation
import Network
import PageRewriter
import Security
import SiteCertificates
import SwiftASN1
import X509

// Enhanced ad blocking's secure bridge (#701, a step of #256): it stands
// between a browser and a site. To the browser it answers as the site, with
// the site's certificate made on this Mac (#682); to the site it connects as
// a browser would, refusing one whose certificate macOS doesn't trust; each
// reply goes through the page rewriter (#683), which passes on anything it
// can't read for certain.
//
// Each site has a listener of its own on the loopback address, with that
// site's certificate: the transparent proxy (#702) connects a browser's
// connection to it. HTTP/1.1 only (no HTTP/2 offered, so browsers use 1.1).
// A browser's connection has one connection to the site of its own, and both
// are kept for the browser's next requests (#741): a new pair for each made
// YouTube's pages many times slower. Nothing is shared between two of the
// browser's connections, so what it keeps apart (a private window) stays
// apart. An upgrade (a WebSocket) is passed through both ways, untouched.

/// What the bridge tells whoever runs it.
public enum BridgeEvent: Equatable {
    /// The browser refused our certificate: the app pins its own, and is to
    /// be left alone from now on (#684's `pinnedApps`).
    /// `clientPort` is the browser side's port, to tell whose connection it was.
    case clientRefused(host: String, clientPort: UInt16?)
    /// The site's certificate isn't one macOS trusts: refused.
    case serverRefused(host: String)
    /// A reply went on untouched, and why.
    case untouched(host: String, PageRewriter.Untouched)
    case rewritten(host: String)
    /// A request its rules by address refuse (#699) was answered empty.
    case answeredEmpty(host: String)
}

public final class SecureBridge: @unchecked Sendable {
    private let identities: SiteIdentities
    private let additions: (String) -> PageAdditions
    fileprivate let refuses: (AddressRequest) -> Bool
    /// The names of the ad slots in a reply's own data (#741), by the site
    /// and what's asked of it.
    fileprivate let slots: (String, String) -> [String]
    private let trusts: (SecTrust, String) -> Bool
    private let endpoint: (String, UInt16) -> NWEndpoint
    fileprivate let events: (BridgeEvent) -> Void
    fileprivate let queue = DispatchQueue(label: "SecureBridge")
    /// The sites' certificates are made here, and sites' certificates
    /// checked here, never on `queue`, where every exchange's bytes move.
    private let keychainQueue = DispatchQueue(label: "SecureBridge.keychain")
    private let verifyQueue = DispatchQueue(label: "SecureBridge.verify", attributes: .concurrent)
    /// Pages are rewritten here, so a big one never holds up the others.
    fileprivate let rewriteQueue = DispatchQueue(label: "SecureBridge.rewrite", qos: .userInitiated,
                                                 attributes: .concurrent)

    /// A site's listener: ready with its port, or still starting with whoever
    /// is waiting for it.
    private final class Site {
        var listener: NWListener?
        var port: UInt16?
        var waiting: [(UInt16?) -> Void] = []
        var lastUsed = Date()
    }
    private var sites: [String: Site] = [:]
    /// Exchanges under way, and the bytes their pages hold (#686): past
    /// either limit, a new site's connections go on unopened, and a page goes
    /// on as it comes, so a hostile page can't wear the extension down.
    fileprivate var exchanges = 0
    fileprivate var heldBytes = 0
    /// The browsers' connections, those kept for a next request too.
    fileprivate var connections = 0
    fileprivate let open = NSHashTable<Exchange>.weakObjects()

    /// The most sites with a listener: the least used one goes past it.
    public static let maxSites = 256
    public static let maxExchanges = 512
    public static let maxConnections = 1_024
    public static let maxHeld = 128 * 1024 * 1024
    /// The most a page is held to be read; past it, it goes on as it comes.
    public static let maxPage = 16 * 1024 * 1024
    /// A connection quiet this long is closed.
    public static let idle: TimeInterval = 60

    /// - Parameters:
    ///   - identities: the sites' certificates and their key.
    ///   - additions: what a page on a host gets.
    ///   - refuses: whether a request is answered empty instead of going on
    ///     to the site (#699).
    ///   - slots: the names of the ad slots in a reply's own data, for a host
    ///     and a request's target (#741).
    ///   - trusts: whether a site's certificate chain is trusted for it; by
    ///     default, as macOS would for a browser.
    ///   - endpoint: where a site is reached; by default, by its name.
    public init(identities: SiteIdentities, additions: @escaping (String) -> PageAdditions,
                refuses: @escaping (AddressRequest) -> Bool = { _ in false },
                slots: @escaping (String, String) -> [String] = { AdSlots.names(host: $0, target: $1) },
                trusts: @escaping (SecTrust, String) -> Bool = { ServerTrust.isTrusted($0, host: $1) },
                endpoint: @escaping (String, UInt16) -> NWEndpoint = { .hostPort(host: .init($0), port: .init(rawValue: $1)!) },
                events: @escaping (BridgeEvent) -> Void = { _ in }) {
        self.identities = identities
        self.additions = additions
        self.refuses = refuses
        self.slots = slots
        self.trusts = trusts
        self.endpoint = endpoint
        self.events = events
    }

    /// The loopback port that answers as `host`, made the first time it's
    /// asked for; nil when it can't be (no certificate for that name).
    public func port(for host: String, sitePort: UInt16 = 443, completion: @escaping (UInt16?) -> Void) {
        let host = host.lowercased()
        // Never a certificate for a site it never opens, whatever asks (#686).
        guard !EnhancedBlocking.isNeverOpened(host) else { return completion(nil) }
        queue.async { [self] in
            guard exchanges < Self.maxExchanges, connections < Self.maxConnections else { return completion(nil) }
            let key = "\(host):\(sitePort)"
            if let site = sites[key] {
                site.lastUsed = Date()
                if let port = site.port { completion(port) } else { site.waiting.append(completion) }
                return
            }
            evictIfFull()
            let site = Site()
            site.waiting.append(completion)
            sites[key] = site
            keychainQueue.async { [self] in
                let identity = try? identities.identity(for: host)
                queue.async { [self] in listen(site, key: key, host: host, sitePort: sitePort, identity: identity) }
            }
        }
    }

    /// The least recently used site's listener goes, past `maxSites`.
    /// Never one used in the last few seconds, whose port a browser may be
    /// about to connect to; a site still starting goes with its waiters told.
    private func evictIfFull() {
        let recent = Date().addingTimeInterval(-10)
        while sites.count >= Self.maxSites {
            guard let oldest = sites.filter({ $0.value.lastUsed < recent }).min(by: { $0.value.lastUsed < $1.value.lastUsed })
            else { return }
            sites.removeValue(forKey: oldest.key)
            oldest.value.listener?.cancel()
            oldest.value.waiting.forEach { $0(nil) }
            oldest.value.waiting.removeAll()
        }
    }

    private func listen(_ site: Site, key: String, host: String, sitePort: UInt16, identity: sec_identity_t?) {
        func fail() {
            if sites[key] === site { sites.removeValue(forKey: key) }
            site.waiting.forEach { $0(nil) }
            site.waiting.removeAll()
        }
        guard sites[key] === site, let identity else { return fail() }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let parameters = NWParameters(tls: tls, tcp: Self.atOnce)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { return fail() }
        site.listener = listener
        listener.stateUpdateHandler = { [weak self, weak site] state in
            guard let self, let site else { return }
            switch state {
            case .ready:
                site.port = listener.port?.rawValue
                site.waiting.forEach { $0(site.port) }
                site.waiting.removeAll()
            case .failed, .cancelled:
                // Only this listener's own entry: never one that took its place.
                if self.sites[key] === site { self.sites.removeValue(forKey: key) }
                site.waiting.forEach { $0(nil) }
                site.waiting.removeAll()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] client in
            self?.serve(client, host: host, sitePort: sitePort)
        }
        listener.start(queue: queue)
    }

    /// Stops every listener, and keeps none of the browsers' connections:
    /// when the switch goes off.
    public func stop() {
        queue.async { [self] in
            let all = sites.values
            sites.removeAll()
            all.forEach { $0.listener?.cancel() }
        }
        retire()
    }

    /// Keeps none of the browsers' connections past the reply under way, so
    /// what the settings now say is asked for each from its start (#741): a
    /// site just left alone isn't still opened on a connection kept before.
    public func retire() {
        queue.async { [self] in open.allObjects.forEach { $0.retire() } }
    }

    // MARK: One exchange

    private func serve(_ client: NWConnection, host: String, sitePort: UInt16) {
        let exchange = Exchange(client: client, host: host, sitePort: sitePort, bridge: self)
        var ready = false
        client.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready = true
                exchange.start()
            case .failed(let error):
                // Before it was ready, a browser that turned our certificate
                // down: it pins its own. Any other failure says nothing of that.
                if !ready, Self.refusedCertificate(error) {
                    var clientPort: UInt16?
                    if case .hostPort(_, let port) = client.endpoint { clientPort = port.rawValue }
                    self.events(.clientRefused(host: host, clientPort: clientPort))
                }
                exchange.close()
            case .waiting, .cancelled:
                exchange.close()
            default: break
            }
        }
        client.start(queue: queue)
    }

    /// A TLS alert saying the peer turned the certificate down.
    static func refusedCertificate(_ error: NWError) -> Bool {
        guard case .tls(let status) = error else { return false }
        return [errSSLPeerBadCert, errSSLPeerUnsupportedCert, errSSLPeerCertRevoked, errSSLPeerCertExpired,
                errSSLPeerCertUnknown, errSSLPeerUnknownCA, errSSLBadCert, errSSLUnknownRootCert,
                errSSLNoRootCert, errSSLXCertChainInvalid].contains(status)
    }

    fileprivate func connectToSite(_ host: String, port: UInt16) -> NWConnection {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_tls_server_name(options, host)
        sec_protocol_options_add_tls_application_protocol(options, "http/1.1")
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        // The handshake's own trust, with what the site stapled to it (its
        // OCSP response, its certificate transparency), checked as a browser
        // checks it, away from the exchanges' queue.
        sec_protocol_options_set_verify_block(options, { [trusts, events] _, trust, done in
            let ok = trusts(sec_trust_copy_ref(trust).takeRetainedValue(), host)
            if !ok { events(.serverRefused(host: host)) }
            done(ok)
        }, verifyQueue)
        return NWConnection(to: endpoint(host, port), using: NWParameters(tls: tls, tcp: Self.atOnce))
    }

    /// TCP that sends each piece as it's written: a reply's last piece never
    /// waits for the one before it to be acknowledged.
    public static var atOnce: NWProtocolTCP.Options {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return tcp
    }

    fileprivate func pageAdditions(for host: String) -> PageAdditions { additions(host) }
}

/// A connection to a site, read one piece at a time. Between two of the
/// browser's requests it's still read, so a site that closes it is heard at
/// once, and anything else it says unasked ends it too.
private final class SiteLink {
    let connection: NWConnection
    /// What ended it while nothing was being asked of it.
    var endedIdle: (() -> Void)?
    private var reading = false
    private var reader: ((Data?, Bool, NWError?) -> Void)?

    init(_ connection: NWConnection) { self.connection = connection }

    /// The site's next piece, or its end.
    func read(_ reader: @escaping (Data?, Bool, NWError?) -> Void) {
        self.reader = reader
        listen()
    }

    /// Nothing asked of it: watched until the next request.
    func rest() { listen() }

    private func listen() {
        guard !reading else { return }
        reading = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [self] data, _, done, error in
            reading = false
            if let reader {
                self.reader = nil
                reader(data, done, error)
            } else {
                endedIdle?()
            }
        }
    }

    func cancel() {
        reader = nil
        endedIdle = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}

/// A browser's connection: its requests one after the other, each with its
/// reply from the site, until either side is done.
private final class Exchange {
    private enum Phase {
        /// Waiting for a request's head.
        case head
        /// A request refused by its address, its body read to its end.
        case refusing(RequestKind, HTTPHead)
        /// Under way: its body going to the site, its reply coming back.
        case exchanging
        /// Both ways untouched, or over.
        case passing
    }

    let client: NWConnection
    let host: String
    let sitePort: UInt16
    let bridge: SecureBridge
    private var phase = Phase.head
    private var link: SiteLink?
    private var linkReady = false
    /// The browser's bytes not used yet: a request's head, what follows it.
    private var incoming = Data()
    private var readingClient = false
    private var clientEnded = false
    private var method: String?
    /// The names of the ad slots in what was asked for.
    private var slots: [String] = []
    /// How much of the request's body is still to go to the site; nil when
    /// its end isn't known, and whatever the browser sends follows it.
    private var bodyLeft: Int? = 0
    private var sendingBody = false
    /// How much of a refused request's body was read.
    private var dropped = 0
    /// Whether the browser asked to keep this connection, and whether it and
    /// the site's are kept after this reply.
    private var asksToKeep = false
    private var keeps = false
    private var siteKeeps = false
    /// Not kept past the reply under way.
    private var retiring = false
    private var reply = Data()
    /// Whether the reply is being held to be read whole, nil until its head is.
    private var holding: Bool?
    /// Where the reply ends, as it comes; nil when only its site's closing says.
    private var end: BodyEnd?
    private var closed = false
    private var counting = false
    private var timer: DispatchSourceTimer?

    init(client: NWConnection, host: String, sitePort: UInt16, bridge: SecureBridge) {
        self.client = client
        self.host = host
        self.sitePort = sitePort
        self.bridge = bridge
        bridge.connections += 1
        bridge.open.add(self)
        let timer = DispatchSource.makeTimerSource(queue: bridge.queue)
        // Strong: the timer keeps the exchange until it closes or goes quiet.
        timer.setEventHandler { self.quiet() }
        self.timer = timer
        touch()
        timer.resume()
    }

    /// Something moved: the idle clock starts again.
    private func touch() {
        timer?.schedule(deadline: .now() + SecureBridge.idle)
    }

    /// Quiet too long: a page being held goes on as it is, untouched, rather
    /// than lost; anything else closes.
    private func quiet() {
        if holding == true, !reply.isEmpty, !abandoned {
            holding = false
            abandoned = true
            link?.cancel()
            // Closed next time it's quiet, if the browser never takes it.
            touch()
            bridge.events(.untouched(host: host, .cantRead("a page whose end didn't come")))
            return sendHeld { [self] in finish(client) }
        }
        close()
    }

    /// The site's side given up on: nothing more read from it.
    private var abandoned = false

    /// What this exchange's held page counts against the bridge's limit.
    private var counted = 0
    private func count(_ bytes: Int) {
        bridge.heldBytes += bytes - counted
        counted = bytes
    }

    /// Whether a request is under way, for the bridge's limit.
    private func busy(_ now: Bool) {
        guard counting != now else { return }
        counting = now
        bridge.exchanges += now ? 1 : -1
    }

    /// Waiting for a request, it ends; under way, it ends with its reply.
    func retire() {
        guard !closed else { return }
        retiring = true
        keeps = false
        if case .head = phase, incoming.isEmpty { finish(client) }
    }

    func close() {
        guard !closed else { return }
        closed = true
        bridge.open.remove(self)
        phase = .passing
        count(0)
        busy(false)
        bridge.connections -= 1
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        // Its handler holds this exchange: let it go.
        client.stateUpdateHandler = nil
        client.cancel()
        dropLink()
    }

    // MARK: The browser's side

    func start() { advance() }

    /// The most of the browser's bytes held before the site takes them.
    static let maxIncoming = 256 * 1024

    /// One read of the browser at a time, all through: between requests for
    /// the next one, and during a reply to hear that it's gone.
    private func readClient() {
        guard !readingClient, !clientEnded, !closed, incoming.count < Self.maxIncoming else { return }
        readingClient = true
        client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, done, error in
            readingClient = false
            guard !closed else { return }
            touch()
            if let data { incoming.append(data) }
            if error != nil { return close() }
            if done { clientEnded = true }
            advance()
        }
    }

    private func advance() {
        guard !closed else { return }
        switch phase {
        case .head:
            readRequest()
        case .refusing(let kind, let request):
            answerEmpty(kind, request: request)
        case .exchanging:
            // A browser that keeps its connection closes it only to be gone.
            if clientEnded, asksToKeep { return close() }
            sendBody()
            readClient()
        case .passing:
            break
        }
    }

    /// The request: its head read, then sent to the site with its body as it
    /// comes. An upgrade goes as it came, and so does one it can't read (a
    /// folded header, one too large): to the site, both ways untouched.
    private func readRequest() {
        let parsed: (head: HTTPHead, bodyStart: Int)?
        do {
            parsed = try HTTPHead.parse(incoming)
        } catch {
            return tunnel()
        }
        guard let (head, bodyStart) = parsed else { return clientEnded ? close() : readClient() }
        guard head.value("Upgrade") == nil else { return tunnel() }
        busy(true)
        method = head.method
        asksToKeep = head.keepsConnection && !clientEnded
        keeps = asksToKeep && !retiring
        slots = head.target.map { bridge.slots(host, $0) } ?? []
        switch try? BodyFraming.forRequest(head) {
        case BodyFraming.none?: bodyLeft = 0
        case .length(let length)?: bodyLeft = length
        default: bodyLeft = nil
        }
        incoming = Data(incoming.dropFirst(bodyStart))
        // A request its rules refuse goes no further: it's answered here,
        // empty, as what it asked for.
        if let target = head.target {
            let address = AddressRequest(host: host, port: sitePort, target: target, header: head.value)
            if bridge.refuses(address) {
                phase = .refusing(address.kind, head)
                return answerEmpty(address.kind, request: head)
            }
        }
        var outgoing = head
        outgoing.remove("Proxy-Connection")
        // Only the codings a held page can be read in.
        if let asked = head.value("Accept-Encoding") {
            let readable = BodyCoding.readable(asked)
            if readable != asked { outgoing.set("Accept-Encoding", readable) }
        }
        if bodyLeft == nil {
            // A body whose end it can't tell is the connection's last.
            outgoing.set("Connection", "close")
            outgoing.remove("Keep-Alive")
            asksToKeep = false
            keeps = false
        }
        phase = .exchanging
        ask(outgoing.bytes)
    }

    /// A refused request's body (a beacon's, a form's) is read to its end
    /// first, up to a megabyte, and dropped: closing while the browser still
    /// sends would reset the connection, and the page would see an error
    /// rather than the empty reply.
    private func answerEmpty(_ kind: RequestKind, request: HTTPHead) {
        let whole: Bool
        if let left = bodyLeft {
            let taken = min(left, incoming.count)
            incoming = Data(incoming.dropFirst(taken))
            bodyLeft = left - taken
            dropped += taken
            whole = bodyLeft == 0
        } else if (try? BodyFraming.forRequest(request)) == .chunked {
            whole = ((try? ChunkedBody.decode(incoming)) ?? nil) != nil || incoming.count >= Self.maxIncoming
        } else {
            whole = true   // its end can't be told
        }
        if !whole, !clientEnded, dropped < 1024 * 1024 { return readClient() }
        let keep = keeps && bodyLeft == 0 && !clientEnded
        phase = .passing
        bridge.events(.answeredEmpty(host: host))
        client.send(content: EmptyReply.bytes(for: kind, request: request, closing: !keep),
                    completion: .contentProcessed { [self] error in
            if error != nil { return close() }
            if keep { next() } else { finish(client) }
        })
    }

    /// The request's body to the site, as it comes, the next piece only once
    /// the last is sent.
    private func sendBody() {
        guard let link, linkReady, !sendingBody, bodyLeft != 0 else { return }
        if incoming.isEmpty {
            // The browser ended before its body did.
            if clientEnded, bodyLeft != nil { close() }
            return
        }
        let piece = bodyLeft.map { Data(incoming.prefix($0)) } ?? incoming
        incoming = Data(incoming.dropFirst(piece.count))
        if let left = bodyLeft { bodyLeft = left - piece.count }
        sendingBody = true
        link.connection.send(content: piece, completion: .contentProcessed { [self] error in
            sendingBody = false
            // A site that answered early may take no more: its reply decides.
            if error == nil, case .exchanging = phase { advance() }
        })
    }

    /// Ready for the browser's next request, on the connections it has.
    private func next() {
        guard !closed else { return }
        busy(false)
        phase = .head
        reply = Data()
        holding = nil
        end = nil
        dropped = 0
        bodyLeft = 0
        if siteKeeps { link?.rest() } else { dropLink() }
        advance()
    }

    // MARK: The site's side

    private func dropLink() {
        link?.cancel()
        link = nil
        linkReady = false
        siteKeeps = false
    }

    /// Sends a request's head on the connection there is, or a new one.
    private func ask(_ head: Data) {
        if let link, linkReady, siteKeeps { return send(head, on: link) }
        dropLink()
        let link = SiteLink(bridge.connectToSite(host, port: sitePort))
        self.link = link
        // The site closing it between two requests: the browser's side is
        // closed too, as it would be without us.
        link.endedIdle = { [weak self] in self?.siteEndedIdle() }
        link.connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                linkReady = true
                send(head, on: link)
            case .failed, .cancelled, .waiting:
                // Once ready, a reply under way ends where its reading does.
                if !linkReady { close() }
            default: break
            }
        }
        link.connection.start(queue: bridge.queue)
    }

    private func send(_ head: Data, on link: SiteLink) {
        link.connection.send(content: head, completion: .contentProcessed { _ in })
        readReply()
        advance()
    }

    private func siteEndedIdle() {
        guard !closed else { return }
        dropLink()
        if case .head = phase, incoming.isEmpty { finish(client) }
    }

    /// Both ways as they come, on a connection to the site of its own.
    private func tunnel() {
        phase = .passing
        busy(true)
        dropLink()
        let site = bridge.connectToSite(host, port: sitePort)
        link = SiteLink(site)
        let first = incoming
        incoming = Data()
        site.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                site.send(content: first, completion: .contentProcessed { _ in })
                if !clientEnded { pump(from: client, to: site) }
                pump(from: site, to: client)
            case .failed, .cancelled, .waiting:
                close()
            default: break
            }
        }
        site.start(queue: bridge.queue)
    }

    /// Bytes from one side to the other as they come, the next read only
    /// once the last is sent, until either side ends.
    private func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [self] data, _, done, error in
            guard !closed else { return }
            touch()
            let next = { [self] in
                if done || error != nil { return finish(destination) }
                pump(from: source, to: destination)
            }
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { [self] sendError in
                    if sendError != nil { return close() }
                    next()
                })
            } else {
                next()
            }
        }
    }

    // MARK: The reply

    /// A page (or a reply with ad slots of its own) is held until its end,
    /// then rewritten; anything else goes on as it comes.
    private func readReply() {
        link?.read { [self] data, done, error in
            guard !closed, !abandoned else { return }
            touch()
            var piece = data ?? Data()
            let ended = done || error != nil
            if holding == nil {
                reply.append(piece)
                piece = readHead()
                if holding == nil {
                    guard ended else { return readReply() }
                    // The site closed before a whole head: what there is,
                    // and the end, as the browser would have seen.
                    return sendHeld { [self] in finish(client) }
                }
            }
            take(piece, ended: ended, failed: error != nil)
        }
    }

    /// A piece of the reply's body: counted towards its end, then held or
    /// sent on.
    private func take(_ piece: Data, ended: Bool, failed: Bool) {
        var body = piece
        if var tracked = end {
            if let used = try? tracked.take(piece) {
                end = tracked
                if used < piece.count {
                    // More than its reply, unasked: it stops here, and the
                    // site isn't asked anything more on this connection.
                    body = Data(piece.prefix(used))
                    siteKeeps = false
                }
            } else {
                // Its framing can't be followed: as it comes, until it closes.
                end = nil
                siteKeeps = false
                keeps = false
                if holding == true {
                    holding = false
                    bridge.events(.untouched(host: host, .cantRead("a chunked body it can't follow")))
                }
            }
        }
        reply.append(body)
        let whole = end?.isEnded == true
        if holding == true {
            count(reply.count)
            if whole { return deliverPage() }
            if ended {
                // Cut off, it can't be told whole: it goes on as it came, so
                // the browser sees it cut off too. One that ends with its
                // connection is whole when that closes as it should.
                if failed || end != nil {
                    holding = false
                    bridge.events(.untouched(host: host, .cantRead("a page cut off")))
                    return sendHeld { [self] in finish(client) }
                }
                return deliverPage()
            }
            if reply.count <= SecureBridge.maxPage, bridge.heldBytes <= SecureBridge.maxHeld { return readReply() }
            // Too big to hold: what's here as it came, the rest as it comes.
            holding = false
            bridge.events(.untouched(host: host, .cantRead("a page too big to hold")))
        }
        sendHeld { [self] in
            if whole { return replied() }
            if ended { return finish(client) }
            readReply()
        }
    }

    /// Reads the reply's head once it's all there, and leaves `reply` with
    /// the head as the browser gets it: informational heads (100, 103) go on
    /// as they are; then whether it's to be held, where it ends, and whether
    /// its connections are kept. Returns what came after the head.
    private func readHead() -> Data {
        while true {
            let parsed: (head: HTTPHead, bodyStart: Int)?
            do {
                parsed = try HTTPHead.parse(reply)
            } catch {
                return asItComes()   // not a reply it can read
            }
            guard let (head, bodyStart) = parsed else { return Data() }
            guard let status = head.status else { return asItComes() }
            let sent = Data(reply.prefix(bodyStart))
            if (100..<200).contains(status), status != 101 {
                client.send(content: sent, completion: .contentProcessed { _ in })
                reply = Data(reply.dropFirst(bodyStart))
                continue
            }
            guard status != 101, let framing = try? BodyFraming.forResponse(head, requestMethod: method) else {
                return asItComes()
            }
            let rest = Data(reply.dropFirst(bodyStart))
            end = BodyEnd(framing)
            let ends = end != nil && bodyLeft == 0
            siteKeeps = ends && head.keepsConnection
            keeps = keeps && ends
            holding = PageRewriter.isPage(head, requestMethod: method)
                || !slots.isEmpty && PageRewriter.isData(head, requestMethod: method)
            reply = asksToKeep ? Self.passedOn(head, sent: sent, kept: keeps, ends: end != nil) : sent
            return rest
        }
    }

    /// A reply it can't read: all of it as it comes, until the site closes.
    private func asItComes() -> Data {
        holding = false
        end = nil
        keeps = false
        siteKeeps = false
        let all = reply
        reply = Data()
        return all
    }

    /// The reply's head for a browser that keeps its connection: as the site
    /// sent it, byte for byte, but for what it says of the connection, which
    /// is the browser's and ours.
    static func passedOn(_ head: HTTPHead, sent: Data, kept: Bool, ends: Bool) -> Data {
        var passed = head
        passed.remove("Connection")
        passed.remove("Keep-Alive")
        if !kept, ends { passed.set("Connection", "close") }
        return passed == head ? sent : passed.bytes
    }

    /// Sends what's held, then goes on.
    private func sendHeld(then next: @escaping () -> Void) {
        let chunk = reply
        reply = Data()
        count(0)
        guard !chunk.isEmpty else { return next() }
        client.send(content: chunk, completion: .contentProcessed { [self] error in
            if error != nil { return close() }
            guard !closed else { return }
            next()
        })
    }

    /// All of the reply sent: the browser's next request, or the end.
    private func replied() {
        if keeps, !sendingBody { next() } else { finish(client) }
    }

    /// Rewritten away from the queue every exchange's bytes move on.
    private func deliverPage() {
        let held = reply, method = method, slots = slots, host = host, bridge = bridge
        bridge.rewriteQueue.async { [self] in
            let (bytes, untouched) = PageRewriter.rewrite(response: held, requestMethod: method,
                                                          additions: bridge.pageAdditions(for: host), slots: slots)
            bridge.queue.async { [self] in
                guard !closed, !abandoned else { return }
                touch()
                bridge.events(untouched.map { .untouched(host: host, $0) } ?? .rewritten(host: host))
                reply = bytes
                holding = false
                sendHeld { [self] in end == nil ? finish(client) : replied() }
            }
        }
    }

    private func finish(_ connection: NWConnection) {
        phase = .passing
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [self] _ in close() })
    }
}

/// The sites' certificates as identities a TLS listener can answer with. One
/// key for all of them, kept in a keychain (the filter's own; a test's own in
/// tests), unexportable, as macOS makes an identity only from a key it holds;
/// made once, found again after that, and removed with the switch.
public final class SiteIdentities: @unchecked Sendable {
    public let certificates: SiteCertificateCache
    private let keychain: SecKeychain?
    /// One for every instance: the bridge made each day cleans up while the
    /// last may still be making an identity.
    private static let lock = NSLock()
    private var lock: NSLock { Self.lock }

    /// The key's and the sites' certificates' label, to find and remove them.
    public static let label = "NetworkMonitor Enhanced Ad Blocking site"

    public init(authority: CertificateAuthority, keychain: SecKeychain?) throws {
        let key = try Self.existingKey(in: keychain) ?? Self.makeKey(in: keychain)
        guard let publicKey = SecKeyCopyPublicKey(key),
              let raw = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { throw BridgeError.identity }
        let p256 = try P256.Signing.PublicKey(x963Representation: raw)
        self.certificates = SiteCertificateCache(authority: authority, siteKey: Certificate.PublicKey(p256))
        self.keychain = keychain
        // Any left by an earlier version, which kept them.
        Self.lock.lock()
        for certificate in Self.siteCertificates(in: keychain) {
            SecItemDelete([kSecClass as String: kSecClassCertificate, kSecValueRef as String: certificate] as CFDictionary)
        }
        Self.lock.unlock()
    }

    private static func query(_ itemClass: CFString, in keychain: SecKeychain?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: itemClass, kSecAttrLabel as String: label]
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        return query
    }

    private static func existingKey(in keychain: SecKeychain?) -> SecKey? {
        var query = query(kSecClassKey, in: keychain)
        query[kSecAttrKeyClass as String] = kSecAttrKeyClassPrivate
        query[kSecReturnRef as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let result, CFGetTypeID(result) == SecKeyGetTypeID() else { return nil }
        return (result as! SecKey)
    }

    private static func makeKey(in keychain: SecKeychain?) throws -> SecKey {
        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsExtractable as String: false,
            kSecAttrIsSensitive as String: true,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true, kSecAttrIsExtractable as String: false,
                                            kSecAttrIsSensitive as String: true,
                                            kSecAttrLabel as String: label] as [String: Any],
        ]
        if let keychain { attributes[kSecUseKeychain as String] = keychain }
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw BridgeError.keychain("making the key: \(String(describing: error?.takeRetainedValue()))", 0)
        }
        return key
    }

    /// Whether the sites' key or any site certificate is in `keychain`.
    public static func hasAny(in keychain: SecKeychain?) -> Bool {
        var find = query(kSecClassKey, in: keychain)
        find[kSecReturnRef as String] = true
        var result: CFTypeRef?
        return SecItemCopyMatching(find as CFDictionary, &result) == errSecSuccess
            || !siteCertificates(in: keychain).isEmpty
    }

    /// The sites' certificates in `keychain`: those our root issued. Found by
    /// their issuer, not their label: a keychain names a certificate after its
    /// subject, whatever label it was added with (found in a VM, #685).
    public static func siteCertificates(in keychain: SecKeychain?) -> [SecCertificate] {
        var find: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecReturnRef as String: true,
                                   kSecMatchLimit as String: kSecMatchLimitAll]
        if let keychain { find[kSecMatchSearchList as String] = [keychain] }
        var result: CFTypeRef?
        guard SecItemCopyMatching(find as CFDictionary, &result) == errSecSuccess else { return [] }
        let root = CertificateAuthority.commonName + " ("
        var seen = Set<Data>()
        return ((result as? [SecCertificate]) ?? []).filter { certificate in
            guard issuerName(certificate)?.hasPrefix(root) == true,
                  (SecCertificateCopySubjectSummary(certificate) as String?)?.hasPrefix(root) != true else { return false }
            return seen.insert(SecCertificateCopyData(certificate) as Data).inserted
        }
    }

    /// A certificate's issuer's common name.
    static func issuerName(_ certificate: SecCertificate) -> String? {
        let key = kSecOIDX509V1IssuerName
        guard let values = SecCertificateCopyValues(certificate, [key] as CFArray, nil) as? [CFString: Any],
              let entry = values[key] as? [CFString: Any],
              let parts = entry[kSecPropertyKeyValue] as? [[CFString: Any]] else { return nil }
        return parts.first { ($0[kSecPropertyKeyLabel] as? String) == "2.5.4.3" }?[kSecPropertyKeyValue] as? String
    }

    /// Takes the sites' key and every site certificate out of `keychain`,
    /// one by one, and says whether anything is left.
    @discardableResult
    public static func remove(from keychain: SecKeychain?) -> Bool {
        for certificate in siteCertificates(in: keychain) {
            SecItemDelete([kSecClass as String: kSecClassCertificate, kSecValueRef as String: certificate] as CFDictionary)
        }
        var find = query(kSecClassKey, in: keychain)
        find[kSecReturnRef as String] = true
        find[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        if SecItemCopyMatching(find as CFDictionary, &result) == errSecSuccess, let keys = result as? [AnyObject] {
            for key in keys {
                SecItemDelete([kSecClass as String: kSecClassKey, kSecValueRef as String: key] as CFDictionary)
            }
        }
        return !hasAny(in: keychain)
    }

    public func identity(for host: String) throws -> sec_identity_t {
        let certificate = try certificates.certificate(for: host)
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        guard let secCertificate = SecCertificateCreateWithData(nil, Data(serializer.serializedBytes) as CFData) else {
            throw BridgeError.identity
        }
        lock.lock()
        defer { lock.unlock() }
        var add: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecValueRef as String: secCertificate,
                                  kSecAttrLabel as String: Self.label]
        if let keychain { add[kSecUseKeychain as String] = keychain }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw BridgeError.keychain("adding the certificate", status)
        }
        var identity: SecIdentity?
        let made = SecIdentityCreateWithCertificate(keychain, secCertificate, &identity)
        // The certificate was only needed in the keychain to be paired with
        // the key: taken out again at once, so the System keychain, which
        // every account on the Mac can read, never lists the sites visited.
        SecItemDelete([kSecClass as String: kSecClassCertificate, kSecValueRef as String: secCertificate] as CFDictionary)
        guard made == errSecSuccess, let identity else { throw BridgeError.keychain("making the identity", made) }
        guard let result = sec_identity_create(identity) else { throw BridgeError.identity }
        return result
    }
}

public enum BridgeError: Error {
    case identity
    /// Which step, and the status macOS gave.
    case keychain(String, OSStatus)
}
