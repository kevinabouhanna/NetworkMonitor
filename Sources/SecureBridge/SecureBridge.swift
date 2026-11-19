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
// so a reply ends when the site closes, and the browser opens another.

/// What the bridge tells whoever runs it.
public enum BridgeEvent: Equatable {
    /// The browser refused our certificate: the app pins its own, and is to
    /// be left alone from now on (#684's `pinnedApps`).
    case clientRefused(host: String)
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
    private let events: (BridgeEvent) -> Void
    private let queue = DispatchQueue(label: "SecureBridge")
    private var listeners: [String: (listener: NWListener, port: UInt16)] = [:]

    /// The most a page is held to be read; past it, it passes on as it came.
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
        queue.async { [self] in
            let key = "\(host.lowercased()):\(sitePort)"
            if let kept = listeners[key] { return completion(kept.port) }
            guard let identity = try? identities.identity(for: host) else { return completion(nil) }
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
            let parameters = NWParameters(tls: tls)
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            guard let listener = try? NWListener(using: parameters) else { return completion(nil) }
            var answered = false
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard !answered, let port = listener?.port?.rawValue else { return }
                    answered = true
                    if let listener { self.listeners[key] = (listener, port) }
                    completion(port)
                case .failed, .cancelled:
                    self.listeners.removeValue(forKey: key)
                    if !answered { answered = true; completion(nil) }
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
            listeners.values.forEach { $0.listener.cancel() }
            listeners.removeAll()
        }
    }

    // MARK: One exchange

    private func serve(_ client: NWConnection, host: String, sitePort: UInt16) {
        let exchange = Exchange(client: client, host: host, bridge: self)
        client.stateUpdateHandler = { state in
            switch state {
            case .ready:
                exchange.readRequest()
            case .failed(let error):
                // The browser's own handshake failed: it refused our certificate.
                if case .tls = error { self.events(.clientRefused(host: host)) }
                exchange.close()
            case .cancelled:
                exchange.close()
            default: break
            }
        }
        client.start(queue: queue)
        exchange.sitePort = sitePort
    }

    fileprivate func connectToSite(_ host: String, port: UInt16, for exchange: Exchange) -> NWConnection {
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
        let site = NWConnection(to: endpoint(host, port), using: NWParameters(tls: tls))
        return site
    }

    fileprivate func finished(_ host: String, _ untouched: PageRewriter.Untouched?) {
        events(untouched.map { .untouched(host: host, $0) } ?? .rewritten(host: host))
    }

    fileprivate func additions(for host: String) -> PageAdditions { additions(host) }
    fileprivate var bridgeQueue: DispatchQueue { queue }
}

/// One request and its reply, between a browser and a site.
private final class Exchange {
    let client: NWConnection
    let host: String
    unowned let bridge: SecureBridge
    var sitePort: UInt16 = 443
    private var site: NWConnection?
    private var request = Data()
    private var method: String?
    private var reply = Data()
    private var isPage: Bool?
    private var closed = false

    init(client: NWConnection, host: String, bridge: SecureBridge) {
        self.client = client
        self.host = host
        self.bridge = bridge
    }

    func close() {
        guard !closed else { return }
        closed = true
        client.cancel()
        site?.cancel()
    }

    // The request: its head read, `Connection: close` set, then whatever
    // follows (a body) passed on as it comes.
    func readRequest() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, done, error in
            if let data { request.append(data) }
            if error != nil || closed { return close() }
            do {
                guard let (head, bodyStart) = try HTTPHead.parse(request) else {
                    return done ? close() : readRequest()
                }
                var outgoing = head
                outgoing.set("Connection", "close")
                outgoing.remove("Keep-Alive")
                outgoing.remove("Proxy-Connection")
                method = head.method
                let body = request[(request.startIndex + bodyStart)...]
                openSite(sending: outgoing.bytes + body, more: !done)
            } catch {
                close()
            }
        }
    }

    private func openSite(sending first: Data, more: Bool) {
        let site = bridge.connectToSite(host, port: sitePort, for: self)
        self.site = site
        site.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                site.send(content: first, completion: .contentProcessed { _ in })
                if more { pumpRequestBody() }
                readReply()
            case .failed, .cancelled:
                close()
            default: break
            }
        }
        site.start(queue: bridge.bridgeQueue)
    }

    private func pumpRequestBody() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, done, error in
            guard !closed, let site else { return }
            if let data, !data.isEmpty { site.send(content: data, completion: .contentProcessed { _ in }) }
            if !done && error == nil { pumpRequestBody() }
        }
    }

    // The reply: a page is held until the site closes (or it's complete by
    // its length), then rewritten; anything else goes on as it comes.
    private func readReply() {
        guard let site else { return }
        site.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [self] data, _, done, error in
            guard !closed else { return }
            if let data, !data.isEmpty { take(data) }
            let ended = done || error != nil
            if isPage == true, ended || isComplete() || reply.count > SecureBridge.maxPage {
                return deliverPage()
            }
            if ended {
                if isPage != true, !reply.isEmpty { client.send(content: reply, completion: .contentProcessed { _ in }) }
                reply.removeAll()
                return finishClient()
            }
            readReply()
        }
    }

    private func take(_ data: Data) {
        if isPage == false {
            client.send(content: data, completion: .contentProcessed { _ in })
            return
        }
        reply.append(data)
        guard isPage == nil else { return }
        let parsed: (head: HTTPHead, bodyStart: Int)?
        do {
            parsed = try HTTPHead.parse(reply)
        } catch {
            // Not a reply it can read: everything as it comes.
            isPage = false
            client.send(content: reply, completion: .contentProcessed { _ in })
            reply.removeAll()
            return
        }
        guard let (head, _) = parsed else { return }
        isPage = Self.mightBePage(head, method: method)
        if isPage == false {
            client.send(content: reply, completion: .contentProcessed { _ in })
            reply.removeAll()
        }
    }

    static func mightBePage(_ head: HTTPHead, method: String?) -> Bool {
        guard let status = head.status, status == 200 || status == 203, method != "HEAD",
              head.value("Content-Range") == nil,
              let type = head.value("Content-Type")?.lowercased() else { return false }
        return type.hasPrefix("text/html")
    }

    /// Complete by its own framing, for a site that keeps the connection.
    private func isComplete() -> Bool {
        guard let (head, bodyStart) = (try? HTTPHead.parse(reply)) ?? nil,
              let framing = try? BodyFraming.forResponse(head, requestMethod: method) else { return false }
        switch framing {
        case .length(let length): return reply.count - bodyStart >= length
        case .chunked: return ((try? ChunkedBody.decode(Data(reply.dropFirst(bodyStart)))) ?? nil) != nil
        case .none: return true
        case .untilClose: return false
        }
    }

    private func deliverPage() {
        let (bytes, untouched) = PageRewriter.rewrite(response: reply, requestMethod: method,
                                                      additions: bridge.additions(for: host))
        bridge.finished(host, untouched)
        reply.removeAll()
        client.send(content: bytes, completion: .contentProcessed { [self] _ in finishClient() })
    }

    private func finishClient() {
        client.send(content: nil, contentContext: .finalMessage, isComplete: true,
                    completion: .contentProcessed { [self] _ in close() })
    }
}

/// The sites' certificates as identities a TLS listener can answer with. One
/// key for all of them, made in a keychain (the filter's own; a test's own in
/// tests), unexportable, as macOS makes an identity only from a key it holds.
public final class SiteIdentities: @unchecked Sendable {
    public let certificates: SiteCertificateCache
    private let keychain: SecKeychain?
    private let lock = NSLock()

    /// The key's label, to find and remove it with the switch.
    public static let keyLabel = "NetworkMonitor Enhanced Ad Blocking site key"

    public init(authority: CertificateAuthority, keychain: SecKeychain?) throws {
        let key = try Self.makeKey(in: keychain)
        guard let publicKey = SecKeyCopyPublicKey(key),
              let raw = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { throw BridgeError.identity }
        let p256 = try P256.Signing.PublicKey(x963Representation: raw)
        self.certificates = SiteCertificateCache(authority: authority, siteKey: Certificate.PublicKey(p256))
        self.keychain = keychain
    }

    private static func makeKey(in keychain: SecKeychain?) throws -> SecKey {
        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsExtractable as String: false,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true, kSecAttrIsExtractable as String: false,
                                            kSecAttrLabel as String: keyLabel] as [String: Any],
        ]
        if let keychain { attributes[kSecUseKeychain as String] = keychain }
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw BridgeError.keychain("making the key: \(String(describing: error?.takeRetainedValue()))", 0)
        }
        return key
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
        var add: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecValueRef as String: secCertificate]
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
