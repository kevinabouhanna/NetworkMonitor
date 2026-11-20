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
// connection to it. HTTP/1.1 only (no HTTP/2 offered, so browsers use 1.1),
// one exchange per connection: the request goes on with `Connection: close`,
// so a reply ends when the site closes, and the browser opens another. An
// upgrade (a WebSocket) is passed through both ways, untouched.

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
    private let trusts: (SecTrust, String) -> Bool
    private let endpoint: (String, UInt16) -> NWEndpoint
    fileprivate let events: (BridgeEvent) -> Void
    fileprivate let queue = DispatchQueue(label: "SecureBridge")
    /// The sites' certificates are made here, and sites' certificates
    /// checked here, never on `queue`, where every exchange's bytes move.
    private let keychainQueue = DispatchQueue(label: "SecureBridge.keychain")
    private let verifyQueue = DispatchQueue(label: "SecureBridge.verify", attributes: .concurrent)

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

    /// The most sites with a listener: the least used one goes past it.
    public static let maxSites = 256
    public static let maxExchanges = 512
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
    ///   - trusts: whether a site's certificate chain is trusted for it; by
    ///     default, as macOS would for a browser.
    ///   - endpoint: where a site is reached; by default, by its name.
    public init(identities: SiteIdentities, additions: @escaping (String) -> PageAdditions,
                refuses: @escaping (AddressRequest) -> Bool = { _ in false },
                trusts: @escaping (SecTrust, String) -> Bool = { ServerTrust.isTrusted($0, host: $1) },
                endpoint: @escaping (String, UInt16) -> NWEndpoint = { .hostPort(host: .init($0), port: .init(rawValue: $1)!) },
                events: @escaping (BridgeEvent) -> Void = { _ in }) {
        self.identities = identities
        self.additions = additions
        self.refuses = refuses
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
            guard exchanges < Self.maxExchanges else { return completion(nil) }
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
        let parameters = NWParameters(tls: tls)
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

    /// Stops every listener: when the switch goes off.
    public func stop() {
        queue.async { [self] in
            let all = sites.values
            sites.removeAll()
            all.forEach { $0.listener?.cancel() }
        }
    }

    // MARK: One exchange

    private func serve(_ client: NWConnection, host: String, sitePort: UInt16) {
        let exchange = Exchange(client: client, host: host, sitePort: sitePort, bridge: self)
        var ready = false
        client.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready = true
                exchange.readRequest()
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
        return NWConnection(to: endpoint(host, port), using: NWParameters(tls: tls))
    }

    fileprivate func pageAdditions(for host: String) -> PageAdditions { additions(host) }
}

/// One request and its reply, between a browser and a site.
private final class Exchange {
    let client: NWConnection
    let host: String
    let sitePort: UInt16
    unowned let bridge: SecureBridge
    private var site: NWConnection?
    private var request = Data()
    private var method: String?
    private var reply = Data()
    /// Whether the reply is a page being held, nil until its head is read.
    private var holding: Bool?
    private var closed = false
    private var timer: DispatchSourceTimer?

    init(client: NWConnection, host: String, sitePort: UInt16, bridge: SecureBridge) {
        self.client = client
        self.host = host
        self.sitePort = sitePort
        self.bridge = bridge
        bridge.exchanges += 1
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
            site?.cancel()
            // Closed next time it's quiet, if the browser never takes it.
            touch()
            bridge.events(.untouched(host: host, .cantRead("a page whose end didn't come")))
            return passOn(thenMore: false)
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

    func close() {
        guard !closed else { return }
        closed = true
        count(0)
        bridge.exchanges -= 1
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        client.cancel()
        site?.cancel()
    }

    // The request: its head read, `Connection: close` set, then whatever
    // follows (a body) passed on as it comes. An upgrade goes as it came.
    func readRequest() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, done, error in
            guard !closed else { return }
            touch()
            if let data { request.append(data) }
            if error != nil { return close() }
            do {
                guard let (head, bodyStart) = try HTTPHead.parse(request) else {
                    return done ? close() : readRequest()
                }
                method = head.method
                // A request its rules refuse goes no further: it's answered
                // here, empty, as what it asked for.
                if let target = head.target {
                    let address = AddressRequest(host: host, port: sitePort, target: target, header: head.value)
                    if bridge.refuses(address) {
                        return answerEmpty(address.kind, request: head, body: Data(request[(request.startIndex + bodyStart)...]),
                                           more: !done)
                    }
                }
                let body = request[(request.startIndex + bodyStart)...]
                if head.value("Upgrade") != nil {
                    return openSite(sending: request, then: .tunnel, more: !done)
                }
                var outgoing = head
                outgoing.set("Connection", "close")
                outgoing.remove("Keep-Alive")
                outgoing.remove("Proxy-Connection")
                openSite(sending: outgoing.bytes + body, then: .reply, more: !done)
            } catch {
                // A request it can't read (a header not in ASCII, one too
                // large) goes to the site as it came, both ways untouched.
                openSite(sending: request, then: .tunnel, more: !done)
            }
        }
    }

    /// The request's body (a beacon's, a form's) is read to its end first,
    /// up to a megabyte, and dropped: closing while the browser still sends
    /// would reset the connection, and the page would see an error rather
    /// than the empty reply.
    private func answerEmpty(_ kind: RequestKind, request: HTTPHead, body: Data, more: Bool) {
        if more, body.count < 1024 * 1024, !Self.isWhole(body, of: request) {
            client.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [self] data, _, done, error in
                guard !closed else { return }
                touch()
                if error != nil { return close() }
                answerEmpty(kind, request: request, body: body + (data ?? Data()), more: !done)
            }
            return
        }
        bridge.events(.answeredEmpty(host: host))
        client.send(content: EmptyReply.bytes(for: kind, request: request), completion: .contentProcessed { [self] error in
            if error != nil { return close() }
            finish(client)
        })
    }

    /// Whether a request's body is all there, by its framing; one that
    /// can't be read is taken as whole.
    static func isWhole(_ body: Data, of request: HTTPHead) -> Bool {
        switch try? BodyFraming.forRequest(request) {
        case .length(let length)?: return body.count >= length
        case .chunked?: return ((try? ChunkedBody.decode(body)) ?? nil) != nil
        default: return true
        }
    }

    private enum Then { case reply, tunnel }

    private func openSite(sending first: Data, then: Then, more: Bool) {
        let site = bridge.connectToSite(host, port: sitePort)
        self.site = site
        site.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                site.send(content: first, completion: .contentProcessed { _ in })
                if more { pump(from: client, to: site) }
                switch then {
                case .reply: readReply()
                case .tunnel: pump(from: site, to: client)
                }
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

    // The reply: a page is held until the site closes (or it's complete by
    // its length), then rewritten; anything else goes on as it comes.
    private func readReply() {
        guard let site else { return }
        site.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [self] data, _, done, error in
            guard !closed, !abandoned else { return }
            touch()
            if let data, !data.isEmpty { reply.append(data) }
            let ended = done || error != nil
            decideFromHead()
            switch holding {
            case true?:
                count(reply.count)
                if isComplete() { return deliverPage() }
                if ended {
                    // Cut off by an error, a page that ends with the
                    // connection can't be told whole: it goes on as it came,
                    // so the browser sees it cut off too.
                    if error != nil {
                        holding = false
                        bridge.events(.untouched(host: host, .cantRead("a page cut off")))
                        return passOn(thenMore: false)
                    }
                    return deliverPage()
                }
                if reply.count > SecureBridge.maxPage || bridge.heldBytes > SecureBridge.maxHeld {
                    // Too big to hold: what's here as it came, the rest as it comes.
                    holding = false
                    count(0)
                    bridge.events(.untouched(host: host, .cantRead("a page too big to hold")))
                    return passOn(thenMore: !ended)
                }
                readReply()
            case false?:
                passOn(thenMore: !ended)
            case nil:
                if ended { return passOn(thenMore: false) }
                readReply()
            }
        }
    }

    /// Reads the reply's head once it's all there: informational heads
    /// (100, 103) go on as they are; then whether it's a page to hold.
    private func decideFromHead() {
        while holding == nil {
            let parsed: (head: HTTPHead, bodyStart: Int)?
            do {
                parsed = try HTTPHead.parse(reply)
            } catch {
                holding = false   // not a reply it can read: as it comes
                return
            }
            guard let (head, bodyStart) = parsed else { return }
            if let status = head.status, (100..<200).contains(status), status != 101 {
                client.send(content: Data(reply.prefix(bodyStart)), completion: .contentProcessed { _ in })
                reply.removeFirst(bodyStart)
                continue
            }
            holding = Self.mightBePage(head, method: method)
        }
    }

    /// Sends what's held, then (if there's more) reads on as it comes.
    private func passOn(thenMore more: Bool) {
        let chunk = reply
        reply.removeAll()
        count(0)
        let next = { [self] in more ? readReply() : finish(client) }
        guard !chunk.isEmpty else { return next() }
        client.send(content: chunk, completion: .contentProcessed { [self] error in
            if error != nil { return close() }
            next()
        })
    }

    static func mightBePage(_ head: HTTPHead, method: String?) -> Bool {
        guard let status = head.status, status == 200 || status == 203, method != "HEAD",
              head.value("Content-Range") == nil,
              let type = head.value("Content-Type")?.lowercased() else { return false }
        return type.hasPrefix("text/html")
    }

    /// Complete by its stated length, or its last chunk, for a site that
    /// keeps the connection open; anything else ends when the site closes,
    /// as asked.
    private func isComplete() -> Bool {
        guard let (head, bodyStart) = (try? HTTPHead.parse(reply)) ?? nil else { return false }
        switch try? BodyFraming.forResponse(head, requestMethod: method) {
        case .length(let length)?:
            return reply.count - bodyStart >= length
        case .chunked?:
            // Read whole only once it ends as a last chunk does: not every
            // piece that comes.
            guard reply.count - bodyStart >= 5, reply.suffix(5) == Data("0\r\n\r\n".utf8) else { return false }
            let body = Data(reply[(reply.startIndex + bodyStart)...])
            guard let (_, used) = (try? ChunkedBody.decode(body)) ?? nil else { return false }
            return used == body.count
        default:
            return false
        }
    }

    private func deliverPage() {
        let (bytes, untouched) = PageRewriter.rewrite(response: reply, requestMethod: method,
                                                      additions: bridge.pageAdditions(for: host))
        bridge.events(untouched.map { .untouched(host: host, $0) } ?? .rewritten(host: host))
        reply.removeAll()
        count(0)
        client.send(content: bytes, completion: .contentProcessed { [self] _ in finish(client) })
    }

    private func finish(_ connection: NWConnection) {
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
