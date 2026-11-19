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
}

public final class SecureBridge: @unchecked Sendable {
    private let identities: SiteIdentities
    private let additions: (String) -> PageAdditions
    private let trusts: ([SecCertificate], String) -> Bool
    private let endpoint: (String, UInt16) -> NWEndpoint
    fileprivate let events: (BridgeEvent) -> Void
    fileprivate let queue = DispatchQueue(label: "SecureBridge")

    /// A site's listener: ready with its port, or still starting with whoever
    /// is waiting for it.
    private final class Site {
        let listener: NWListener
        var port: UInt16?
        var waiting: [(UInt16?) -> Void] = []
        init(_ listener: NWListener) { self.listener = listener }
    }
    private var sites: [String: Site] = [:]

    /// The most a page is held to be read; past it, it goes on as it comes.
    public static let maxPage = 16 * 1024 * 1024
    /// A connection quiet this long is closed.
    public static let idle: TimeInterval = 60

    /// - Parameters:
    ///   - identities: the sites' certificates and their key.
    ///   - additions: what a page on a host gets.
    ///   - trusts: whether a site's certificate chain is trusted for it; by
    ///     default, as macOS would for a browser.
    ///   - endpoint: where a site is reached; by default, by its name.
    public init(identities: SiteIdentities, additions: @escaping (String) -> PageAdditions,
                trusts: @escaping ([SecCertificate], String) -> Bool = { ServerTrust.isTrusted($0, host: $1) },
                endpoint: @escaping (String, UInt16) -> NWEndpoint = { .hostPort(host: .init($0), port: .init(rawValue: $1)!) },
                events: @escaping (BridgeEvent) -> Void = { _ in }) {
        self.identities = identities
        self.additions = additions
        self.trusts = trusts
        self.endpoint = endpoint
        self.events = events
    }

    /// The loopback port that answers as `host`, made the first time it's
    /// asked for; nil when it can't be (no certificate for that name).
    public func port(for host: String, sitePort: UInt16 = 443, completion: @escaping (UInt16?) -> Void) {
        let host = host.lowercased()
        queue.async { [self] in
            let key = "\(host):\(sitePort)"
            if let site = sites[key] {
                if let port = site.port { completion(port) } else { site.waiting.append(completion) }
                return
            }
            guard let identity = try? identities.identity(for: host) else { return completion(nil) }
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
            let parameters = NWParameters(tls: tls)
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            guard let listener = try? NWListener(using: parameters) else { return completion(nil) }
            let site = Site(listener)
            site.waiting.append(completion)
            sites[key] = site
            listener.stateUpdateHandler = { [weak self, weak site] state in
                guard let self, let site else { return }
                switch state {
                case .ready:
                    site.port = site.listener.port?.rawValue
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
    }

    /// Stops every listener: when the switch goes off.
    public func stop() {
        queue.async { [self] in
            let all = sites.values
            sites.removeAll()
            all.forEach { $0.listener.cancel() }
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
        sec_protocol_options_set_verify_block(options, { [trusts, events] _, trust, done in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            let chain = (SecTrustCopyCertificateChain(secTrust) as? [SecCertificate]) ?? []
            let ok = trusts(chain, host)
            if !ok { events(.serverRefused(host: host)) }
            done(ok)
        }, queue)
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
        let timer = DispatchSource.makeTimerSource(queue: bridge.queue)
        // Strong: the timer keeps the exchange until it closes or goes quiet.
        timer.setEventHandler { self.close() }
        self.timer = timer
        touch()
        timer.resume()
    }

    /// Something moved: the idle clock starts again.
    private func touch() {
        timer?.schedule(deadline: .now() + SecureBridge.idle)
    }

    func close() {
        guard !closed else { return }
        closed = true
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
                close()
            }
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
            guard !closed else { return }
            touch()
            if let data, !data.isEmpty { reply.append(data) }
            let ended = done || error != nil
            decideFromHead()
            switch holding {
            case true?:
                if ended || isComplete() { return deliverPage() }
                if reply.count > SecureBridge.maxPage {
                    // Too big to hold: what's here as it came, the rest as it comes.
                    holding = false
                    bridge.events(.untouched(host: host, .cantRead("a page over 16 MB")))
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

    /// Complete by its stated length, for a site that keeps the connection
    /// open; anything else ends when the site closes, as asked.
    private func isComplete() -> Bool {
        guard let (head, bodyStart) = (try? HTTPHead.parse(reply)) ?? nil,
              case .length(let length)? = try? BodyFraming.forResponse(head, requestMethod: method) else { return false }
        return reply.count - bodyStart >= length
    }

    private func deliverPage() {
        let (bytes, untouched) = PageRewriter.rewrite(response: reply, requestMethod: method,
                                                      additions: bridge.pageAdditions(for: host))
        bridge.events(untouched.map { .untouched(host: host, $0) } ?? .rewritten(host: host))
        reply.removeAll()
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
    private let lock = NSLock()

    /// The key's and the sites' certificates' label, to find and remove them.
    public static let label = "NetworkMonitor Enhanced Ad Blocking site"

    public init(authority: CertificateAuthority, keychain: SecKeychain?) throws {
        let key = try Self.existingKey(in: keychain) ?? Self.makeKey(in: keychain)
        guard let publicKey = SecKeyCopyPublicKey(key),
              let raw = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { throw BridgeError.identity }
        let p256 = try P256.Signing.PublicKey(x963Representation: raw)
        self.certificates = SiteCertificateCache(authority: authority, siteKey: Certificate.PublicKey(p256))
        self.keychain = keychain
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
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true, kSecAttrIsExtractable as String: false,
                                            kSecAttrLabel as String: label] as [String: Any],
        ]
        if let keychain { attributes[kSecUseKeychain as String] = keychain }
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw BridgeError.keychain("making the key: \(String(describing: error?.takeRetainedValue()))", 0)
        }
        return key
    }

    /// Takes the sites' key and every site certificate out of `keychain`,
    /// one by one, and says whether anything is left.
    @discardableResult
    public static func remove(from keychain: SecKeychain?) -> Bool {
        for itemClass in [kSecClassKey, kSecClassCertificate] {
            var find = query(itemClass, in: keychain)
            find[kSecReturnRef as String] = true
            find[kSecMatchLimit as String] = kSecMatchLimitAll
            var result: CFTypeRef?
            guard SecItemCopyMatching(find as CFDictionary, &result) == errSecSuccess,
                  let items = result as? [AnyObject] else { continue }
            for item in items {
                SecItemDelete([kSecClass as String: itemClass, kSecValueRef as String: item] as CFDictionary)
            }
        }
        return [kSecClassKey, kSecClassCertificate].allSatisfy {
            var find = query($0, in: keychain)
            find[kSecReturnRef as String] = true
            var result: CFTypeRef?
            return SecItemCopyMatching(find as CFDictionary, &result) != errSecSuccess
        }
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
