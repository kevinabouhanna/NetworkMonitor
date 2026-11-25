import CryptoKit
import FirewallPolicy
import Foundation
import Network
import PageRewriter
import SecureBridge
import Security
import SiteCertificates
import SwiftASN1
import X509

/// The secure bridge (#701): a browser on one side, a site on the other, both
/// on this Mac's loopback, with roots of the test's own.
func runSecureBridgeTests() {
    let queue = DispatchQueue(label: "SecureBridgeTests", attributes: .concurrent)

    func testKeychain() -> (SecKeychain, () -> Void)? {
        let path = NSTemporaryDirectory() + "bridge-\(UUID().uuidString).keychain"
        var keychain: SecKeychain?
        guard SecKeychainCreate(path, 4, "test", false, nil, &keychain) == errSecSuccess, let keychain else { return nil }
        return (keychain, { SecKeychainDelete(keychain); try? FileManager.default.removeItem(atPath: path) })
    }

    func root(_ name: String) throws -> CertificateAuthority {
        try CertificateAuthority.make(key: Certificate.PrivateKey(P256.Signing.PrivateKey()), machine: name)
    }

    func secCertificate(_ authority: CertificateAuthority) -> SecCertificate {
        SecCertificateCreateWithData(nil, try! authority.der() as CFData)!
    }

    /// A site on the loopback that answers every connection with `reply`
    /// and closes; its port.
    func site(answering reply: Data, identity: sec_identity_t, keepOpen: Bool = false) -> (NWListener, UInt16)? {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        let parameters = NWParameters(tls: tls)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                // A site that ignores `Connection: close` keeps it open.
                if keepOpen {
                    connection.send(content: reply, completion: .contentProcessed { _ in })
                    queue.asyncAfter(deadline: .now() + 30) { connection.cancel() }
                    return
                }
                connection.send(content: reply, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 10) == .success, let port = listener.port?.rawValue else { return nil }
        return (listener, port)
    }

    /// A browser: connects to `port` as `host`, trusting `anchor` (or
    /// refusing everything), sends a GET, and reads the reply to its end.
    func browse(port: UInt16, host: String, anchor: SecCertificate?,
                request: String? = nil) -> Data? {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, done in
            guard let anchor else { return done(false) }
            let chain = (SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate]) ?? []
            done(ServerTrust.isTrusted(chain, host: host, anchors: [anchor]))
        }, queue)
        let connection = NWConnection(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!),
                                      using: NWParameters(tls: tls))
        var received = Data()
        var failed = false
        let finished = DispatchSemaphore(value: 0)
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
                if let data { received.append(data) }
                if done || error != nil { finished.signal() } else { read() }
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let text = request ?? "GET / HTTP/1.1\r\nHost: \(host)\r\nConnection: keep-alive\r\n\r\n"
                connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
                read()
            case .failed: failed = true; finished.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        let waited = finished.wait(timeout: .now() + 20)
        connection.cancel()
        return waited == .success && !failed ? received : nil
    }

    let page = "<html><head><title>T</title></head><body><div class=\"ad-banner\">x</div>Story</body></html>"
    let pageReply = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(page.utf8.count)\r\n\r\n\(page)".utf8)
    let additions = PageAdditions(selectors: [".ad-banner"], scriptlets: [])

    /// A bridge and a site, both with roots of their own, the bridge
    /// trusting the site's root (or not).
    func setUp(reply: Data, bridgeTrustsSite: Bool = true, keepOpen: Bool = false,
               refuses: @escaping (AddressRequest) -> Bool = { _ in false },
               body: (_ bridgePort: UInt16, _ bridgeRoot: SecCertificate, _ events: () -> [BridgeEvent],
                      _ bridge: SecureBridge) -> Void) {
        guard let (keychain, done) = testKeychain(), let (siteKeychain, siteDone) = testKeychain() else {
            return Check.expectTrue(false, "no test keychain")
        }
        defer { done(); siteDone() }
        do {
            let siteRoot = try root("Test site"), bridgeRoot = try root("Test bridge")
            let siteIdentity = try SiteIdentities(authority: siteRoot, keychain: siteKeychain).identity(for: "test.example")
            guard let (listener, sitePort) = site(answering: reply, identity: siteIdentity, keepOpen: keepOpen) else {
                return Check.expectTrue(false, "no test site")
            }
            defer { listener.cancel() }
            var seen: [BridgeEvent] = []
            let lock = NSLock()
            let anchors = bridgeTrustsSite ? [secCertificate(siteRoot)] : [secCertificate(try root("Elsewhere"))]
            let bridge = SecureBridge(
                identities: try SiteIdentities(authority: bridgeRoot, keychain: keychain),
                additions: { _ in additions },
                refuses: refuses,
                trusts: { ServerTrust.isTrusted($0, host: $1, anchors: anchors) },
                endpoint: { _, _ in .hostPort(host: "127.0.0.1", port: .init(rawValue: sitePort)!) },
                events: { event in lock.lock(); seen.append(event); lock.unlock() })
            defer { bridge.stop() }
            let portReady = DispatchSemaphore(value: 0)
            var bridgePort: UInt16?
            bridge.port(for: "test.example") { bridgePort = $0; portReady.signal() }
            guard portReady.wait(timeout: .now() + 10) == .success, let bridgePort else {
                return Check.expectTrue(false, "no bridge listener")
            }
            body(bridgePort, secCertificate(bridgeRoot), { lock.lock(); defer { lock.unlock() }; return seen }, bridge)
        } catch {
            Check.expectTrue(false, "\(error)")
        }
    }

    Check.suite("Secure bridge — a browser and a site through it (#701)") {

        Check.test("one listener per site, however many ask at once, whatever the case") {
            setUp(reply: pageReply) { first, _, _, bridge in
                let group = DispatchGroup()
                var ports: [UInt16?] = []
                let lock = NSLock()
                for name in ["new.example", "NEW.example", "new.example", "New.Example"] {
                    group.enter()
                    bridge.port(for: name) { port in lock.lock(); ports.append(port); lock.unlock(); group.leave() }
                }
                Check.expectEqual(group.wait(timeout: .now() + 10), .success)
                Check.expectEqual(Set(ports.compactMap { $0 }).count, 1, "\(ports)")
                Check.expectFalse(ports.contains(first), "another site, another listener")
            }
        }

        Check.test("an early hint before the page, and a page after it is rewritten") {
            let hinted = Data("HTTP/1.1 103 Early Hints\r\nLink: </a.css>; rel=preload\r\n\r\n".utf8) + pageReply
            setUp(reply: hinted) { port, bridgeRoot, _, _ in
                let reply = browse(port: port, host: "test.example", anchor: bridgeRoot).map { String(decoding: $0, as: UTF8.self) }
                Check.expectTrue(reply?.hasPrefix("HTTP/1.1 103 Early Hints") == true)
                Check.expectTrue(reply?.contains(".ad-banner{display:none!important}") == true, "the page after the hint")
            }
        }

        Check.test("a big download goes on whole, as it comes") {
            let big = Data(repeating: 7, count: 3 * 1024 * 1024)
            let download = Data("HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nContent-Length: \(big.count)\r\n\r\n".utf8) + big
            setUp(reply: download) { port, bridgeRoot, _, _ in
                Check.expectEqual(browse(port: port, host: "test.example", anchor: bridgeRoot), download)
            }
        }

        Check.test("a WebSocket's upgrade goes through both ways, untouched") {
            let switched = Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\nhello".utf8)
            setUp(reply: switched) { port, bridgeRoot, _, _ in
                let request = "GET /socket HTTP/1.1\r\nHost: test.example\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n"
                Check.expectEqual(browse(port: port, host: "test.example", anchor: bridgeRoot, request: request), switched)
            }
        }

        // A key only another program may use is what macOS asks about, as when
        // the runner's own file is replaced while it runs (#739).
        Check.test("a key the tests may not use is refused, and nobody is asked for a password (#739)") {
            var allowed: DarwinBoolean = true
            SecKeychainGetUserInteractionAllowed(&allowed)
            // Checked first: past here, a dialog would come up.
            guard !allowed.boolValue else { return Check.expectTrue(false, "the tests can raise password dialogs") }
            guard let (keychain, done) = testKeychain() else { return Check.expectTrue(false, "no test keychain") }
            defer { done() }
            var length = UInt32(PATH_MAX)
            var bytes = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard SecKeychainGetPath(keychain, &length, &bytes) == errSecSuccess, length > 0 else {
                return Check.expectTrue(false, "no path for the test keychain")
            }
            let path = String(cString: bytes)
            /// `security`, which isn't kept from asking as this process is: the
            /// keychain is unlocked first, and it's stopped if it waits.
            func security(_ arguments: [String]) -> Bool {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                let ended = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in ended.signal() }
                guard (try? process.run()) != nil else { return false }
                if ended.wait(timeout: .now() + 30) == .timedOut {
                    process.terminate()
                    return false
                }
                return process.terminationStatus == 0
            }
            guard security(["unlock-keychain", "-p", "test", path]),
                  security(["create-keypair", "-a", "rsa", "-s", "2048", "-k", path,
                            "-T", "/usr/bin/true", "another program's"]) else {
                return Check.expectTrue(false, "security couldn't make the key")
            }
            var found: CFTypeRef?
            let query: [String: Any] = [kSecClass as String: kSecClassKey,
                                        kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                                        kSecMatchSearchList as String: [keychain], kSecReturnRef as String: true]
            guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let found else {
                return Check.expectTrue(false, "no key in the test keychain")
            }
            func sign(_ key: SecKey) -> (signed: Bool, code: Int) {
                var error: Unmanaged<CFError>?
                let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                                      Data("x".utf8) as CFData, &error)
                return (signature != nil, error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? 0)
            }
            let refused = sign(found as! SecKey)
            Check.expectFalse(refused.signed, "signed with a key that isn't the tests'")
            Check.expectTrue([Int(errSecAuthFailed), Int(errSecInteractionNotAllowed)].contains(refused.code),
                             "refused for another reason: \(refused.code)")
            // The same kind of key, and the tests' own.
            let own: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
            Check.expectTrue(SecKeyCreateRandomKey(own as CFDictionary, nil).map { sign($0).signed } ?? false,
                             "can't sign with the tests' own key")
        }

        Check.test("the sites' key is made once, found again, and removed with every certificate") {
            guard let (keychain, done) = testKeychain() else { return Check.expectTrue(false, "no test keychain") }
            defer { done() }
            do {
                let authority = try root("Test bridge")
                let first = try SiteIdentities(authority: authority, keychain: keychain)
                _ = try first.identity(for: "a.example")
                let again = try SiteIdentities(authority: authority, keychain: keychain)
                Check.expectEqual(again.certificates.siteKey, first.certificates.siteKey, "the same key, found again")
                _ = try again.identity(for: "b.example")
                Check.expectEqual(SiteIdentities.siteCertificates(in: keychain).count, 0,
                                  "no site's certificate kept in the keychain, which lists the sites visited (#686)")
                var find: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrLabel as String: SiteIdentities.label,
                                           kSecReturnRef as String: true, kSecMatchSearchList as String: [keychain]]
                find[kSecAttrKeyClass as String] = kSecAttrKeyClassPrivate
                var found: CFTypeRef?
                SecItemCopyMatching(find as CFDictionary, &found)
                let key = found.flatMap { SecKeyCopyAttributes($0 as! SecKey) as? [String: Any] } ?? [:]
                Check.expectEqual(key[kSecAttrIsExtractable as String] as? Bool, false, "the sites' key is unexportable")
                Check.expectNil(found.flatMap { SecKeyCopyExternalRepresentation($0 as! SecKey, nil) },
                                "and reading it out is refused")
                Check.expectTrue(SiteIdentities.remove(from: keychain), "nothing left")
                Check.expectEqual(SiteIdentities.siteCertificates(in: keychain).count, 0)
            } catch {
                Check.expectTrue(false, "\(error)")
            }
        }


        Check.test("a browser trusting the root gets the site's page with its hiding added") {
            setUp(reply: pageReply) { port, bridgeRoot, events, _ in
                let reply = browse(port: port, host: "test.example", anchor: bridgeRoot).map { String(decoding: $0, as: UTF8.self) }
                Check.expectTrue(reply?.hasPrefix("HTTP/1.1 200 OK") == true, "a reply: \(reply?.prefix(40) ?? "none")")
                Check.expectTrue(reply?.contains(".ad-banner{display:none!important}") == true, "the hiding added")
                Check.expectTrue(reply?.contains("Story</body></html>") == true, "the page itself")
                Check.expectTrue(events().contains(.rewritten(host: "test.example")), "\(events())")
            }
        }

        Check.test("a site whose certificate isn't trusted is refused, and the browser gets nothing") {
            setUp(reply: pageReply, bridgeTrustsSite: false) { port, bridgeRoot, events, _ in
                let reply = browse(port: port, host: "test.example", anchor: bridgeRoot)
                Check.expectTrue(reply == nil || reply?.isEmpty == true, "nothing from an untrusted site")
                Check.expectTrue(events().contains(.serverRefused(host: "test.example")), "\(events())")
            }
        }

        Check.test("a browser that refuses our certificate is reported as pinning") {
            setUp(reply: pageReply) { port, _, events, _ in
                Check.expectNil(browse(port: port, host: "test.example", anchor: nil))
                // The bridge hears of it a moment later.
                let deadline = Date() + 5
                func refused(_ seen: [BridgeEvent]) -> Bool {
                    seen.contains { if case .clientRefused(host: "test.example", clientPort: .some) = $0 { return true }; return false }
                }
                while !refused(events()) && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                Check.expectTrue(refused(events()), "with the client's port: \(events())")
            }
        }

        Check.test("a request its rules by address refuse is answered empty, one excepted goes to the site (#699)") {
            let rules = AddressRules(lines: ["/ads/*$script", "@@/ads/house.js$script", "/pixel.gif$image"])
            setUp(reply: pageReply, refuses: rules.refuses) { port, bridgeRoot, events, _ in
                func get(_ path: String, dest: String) -> String? {
                    let request = "GET \(path) HTTP/1.1\r\nHost: test.example\r\nSec-Fetch-Dest: \(dest)\r\n"
                        + "Sec-Fetch-Site: same-origin\r\nOrigin: https://test.example\r\n\r\n"
                    return browse(port: port, host: "test.example", anchor: bridgeRoot, request: request)
                        .map { String(decoding: $0, as: UTF8.self) }
                }
                let refused = get("/ads/banner.js", dest: "script")
                Check.expectTrue(refused?.hasPrefix("HTTP/1.1 200 OK\r\nContent-Type: text/javascript\r\nContent-Length: 0\r\n")
                                 == true, "empty: \(refused ?? "none")")
                Check.expectTrue(refused?.contains("Access-Control-Allow-Origin: https://test.example") == true)
                Check.expectFalse(refused?.contains("Story") == true, "nothing of the site's")
                let pixel = browse(port: port, host: "test.example", anchor: bridgeRoot,
                                   request: "GET /t/pixel.gif HTTP/1.1\r\nHost: test.example\r\nSec-Fetch-Dest: image\r\n\r\n")
                Check.expectTrue(pixel.map { $0.suffix(43).starts(with: Data("GIF89a".utf8)) } == true, "a transparent pixel")
                let excepted = get("/ads/house.js", dest: "script")
                Check.expectTrue(excepted?.contains("Story") == true, "the site's own reply: \(excepted?.prefix(60) ?? "none")")
                Check.expectTrue(get("/ads/banner.js", dest: "image")?.contains("Story") == true, "a script rule, not an image's")
                // A refused request with a big body: read to its end first, so
                // the browser gets the reply, never a reset connection.
                let body = String(repeating: "x", count: 300_000)
                let post = browse(port: port, host: "test.example", anchor: bridgeRoot,
                                  request: "POST /ads/send.js HTTP/1.1\r\nHost: test.example\r\nSec-Fetch-Dest: script\r\n"
                                    + "Content-Length: \(body.utf8.count)\r\n\r\n" + body)
                Check.expectTrue(post.map { String(decoding: $0, as: UTF8.self).hasPrefix("HTTP/1.1 200 OK") } == true,
                                 "the empty reply after the body")
                Check.expectEqual(events().filter { $0 == .answeredEmpty(host: "test.example") }.count, 3)
            }
        }

        Check.test("an empty reply: none for HEAD, a CORS preflight let through, nothing added from the request") {
            func head(_ text: String) -> HTTPHead? { (try? HTTPHead.parse(Data(text.utf8)))?.head }
            guard let headRequest = head("HEAD /p.gif HTTP/1.1\r\nHost: a\r\n\r\n"),
                  let preflight = head("OPTIONS /c HTTP/1.1\r\nHost: a\r\nOrigin: https://site.example\r\n"
                                       + "Access-Control-Request-Method: POST\r\n"
                                       + "Access-Control-Request-Headers: content-type\r\n\r\n"),
                  let sneaky = head("GET /x.js HTTP/1.1\r\nHost: a\r\nOrigin: https://a.example Set-Cookie: x\r\n\r\n") else {
                return Check.expectTrue(false, "heads")
            }
            let none = String(decoding: EmptyReply.bytes(for: .image, request: headRequest), as: UTF8.self)
            Check.expectTrue(none.hasSuffix("\r\n\r\n") && none.contains("Content-Length: 0"), none)
            let allowed = String(decoding: EmptyReply.bytes(for: .xmlhttprequest, request: preflight), as: UTF8.self)
            Check.expectTrue(allowed.hasPrefix("HTTP/1.1 204"), allowed)
            Check.expectTrue(allowed.contains("Access-Control-Allow-Methods: POST\r\n"), allowed)
            Check.expectTrue(allowed.contains("Access-Control-Allow-Headers: content-type\r\n"), allowed)
            let plain = String(decoding: EmptyReply.bytes(for: .script, request: sneaky), as: UTF8.self)
            Check.expectFalse(plain.contains("Set-Cookie") || plain.contains("Access-Control"), plain)
        }

        Check.test("a request with a UTF-8 cookie is read; one it can't read goes to the site untouched (#686)") {
            setUp(reply: pageReply) { port, bridgeRoot, _, _ in
                let cookie = "GET / HTTP/1.1\r\nHost: test.example\r\nCookie: name=José\r\n\r\n"
                let read = browse(port: port, host: "test.example", anchor: bridgeRoot, request: cookie)
                    .map { String(decoding: $0, as: UTF8.self) }
                Check.expectTrue(read?.contains(".ad-banner{display:none!important}") == true, "rewritten: \(read ?? "none")")
                let folded = "GET / HTTP/1.1\r\nHost: test.example\r\nX-Old: a\r\n b\r\n\r\n"
                Check.expectEqual(browse(port: port, host: "test.example", anchor: bridgeRoot, request: folded), pageReply,
                                  "a folded header: the site's reply, untouched, not a closed connection")
            }
        }

        Check.test("a chunked page from a site that keeps the connection open is rewritten at its last chunk (#686)") {
            let chunked = Data(("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nTransfer-Encoding: chunked\r\n\r\n"
                                + String(page.utf8.count, radix: 16) + "\r\n" + page + "\r\n0\r\n\r\n").utf8)
            setUp(reply: chunked, keepOpen: true) { port, bridgeRoot, _, _ in
                let start = Date()
                let reply = browse(port: port, host: "test.example", anchor: bridgeRoot).map { String(decoding: $0, as: UTF8.self) }
                Check.expectTrue(reply?.contains(".ad-banner{display:none!important}") == true, "rewritten: \(reply ?? "none")")
                Check.expectTrue(Date().timeIntervalSince(start) < 10, "without waiting for the site to close")
            }
        }

        Check.test("never a certificate, nor a listener, for a site it never opens (#686)") {
            setUp(reply: pageReply) { _, _, _, bridge in
                let done = DispatchSemaphore(value: 0)
                var port: UInt16? = 1
                bridge.port(for: "www.PayPal.com") { port = $0; done.signal() }
                Check.expectEqual(done.wait(timeout: .now() + 5), .success)
                Check.expectNil(port)
            }
        }

        Check.test("a reply it can't read goes on byte for byte") {
            let odd = Data("not HTTP at all \u{1}\u{2}\u{3}".utf8)
            setUp(reply: odd) { port, bridgeRoot, _, _ in
                Check.expectEqual(browse(port: port, host: "test.example", anchor: bridgeRoot), odd)
            }
            let image = Data("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 3\r\n\r\nabc".utf8)
            setUp(reply: image) { port, bridgeRoot, _, _ in
                Check.expectEqual(browse(port: port, host: "test.example", anchor: bridgeRoot), image)
            }
        }
    }
}
