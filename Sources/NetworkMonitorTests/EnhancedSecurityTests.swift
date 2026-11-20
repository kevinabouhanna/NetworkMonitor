import CryptoKit
import FirewallPolicy
import Foundation
import PageRewriter
import SecureBridge
import Security
import SiteCertificates
import SwiftASN1
import X509

/// Enhanced ad blocking's own security review (#686): what it found, held.
func runEnhancedSecurityTests() {
    func secCertificate(_ certificate: Certificate) -> SecCertificate? {
        var serializer = DER.Serializer()
        guard (try? serializer.serialize(certificate)) != nil else { return nil }
        return SecCertificateCreateWithData(nil, Data(serializer.serializedBytes) as CFData)
    }

    Check.suite("Enhanced ad blocking — its security review (#686)") {

        Check.test("the root vouches only for websites, and never for a site it never opens, whatever signs") {
            do {
                let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
                let root = try CertificateAuthority.make(key: key, machine: "Test Mac",
                                                         excluded: EnhancedBlocking.neverVouchedFor)
                Check.expectEqual(try root.certificate.extensions.extendedKeyUsage.map(Array.init), [.serverAuth])
                Check.expectNotNil(try root.certificate.extensions.nameConstraints)
                guard let anchor = SecCertificateCreateWithData(nil, try root.der() as CFData) else {
                    return Check.expectTrue(false, "no root")
                }
                func trusted(_ host: String) -> Bool {
                    guard let leaf = try? root.issue(for: host, key: key.publicKey), let certificate = secCertificate(leaf)
                    else { return false }
                    return ServerTrust.isTrusted([certificate, anchor], host: host, anchors: [anchor])
                }
                Check.expectTrue(trusted("news.example"), "an ordinary site")
                for host in ["www.paypal.com", "login.chase.com", "www.irs.gov", "www.gov.uk", "my.bank"] {
                    Check.expectFalse(trusted(host), "\(host): refused by the root's own constraints")
                }
            } catch {
                Check.expectTrue(false, "\(error)")
            }
        }

        Check.test("everything the root may never vouch for is never opened, so no site of it is ever broken") {
            for name in EnhancedBlocking.neverVouchedFor {
                Check.expectTrue(EnhancedBlocking.isNeverOpened("www." + name), name)
            }
        }

        Check.test("a scriptlet's argument can't open an HTML comment or a script") {
            let script = ScriptletCode.script(for: [Scriptlet(name: "no-setTimeout-if", arguments: ["<!--<script>", "1"])])
            Check.expectFalse(script?.contains("<!--") == true || script?.lowercased().contains("<script") == true,
                              script ?? "none")
            Check.expectTrue(script?.contains("\\u003c!--") == true, "the argument kept, escaped")
        }

        Check.test("why a reply went on untouched never holds the reply's own text") {
            let response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nTransfer-Encoding: chunked\r\n\r\n<html>my account 1234</html>".utf8)
            let (bytes, untouched) = PageRewriter.rewrite(response: response, requestMethod: "GET",
                                                          additions: PageAdditions(selectors: [".ad"], scriptlets: []))
            Check.expectEqual(bytes, response, "passed on as it came")
            guard case .cantRead(let why)? = untouched else { return Check.expectTrue(false, "\(String(describing: untouched))") }
            Check.expectFalse(why.contains("account") || why.contains("1234"), why)
        }

        Check.test("a head with a UTF-8 cookie goes on byte for byte, its last character kept") {
            let request = Data("GET / HTTP/1.1\r\nHost: a.example\r\nCookie: city=Bogotà\r\n\r\n".utf8)
            guard let (head, _) = (try? HTTPHead.parse(request)) ?? nil else { return Check.expectTrue(false, "unread") }
            Check.expectEqual(head.bytes, request)
        }

        Check.test("a root made before its limits, or with others, is made again; one with them is kept") {
            let excluded = EnhancedBlocking.neverVouchedFor
            do {
                let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
                Check.expectFalse(try CertificateAuthority.make(key: key, machine: "Mac").isLimited(to: excluded))
                Check.expectTrue(try CertificateAuthority.make(key: key, machine: "Mac", excluded: excluded).isLimited(to: excluded))
                Check.expectFalse(try CertificateAuthority.make(key: key, machine: "Mac", excluded: ["gov"]).isLimited(to: excluded))
            } catch {
                Check.expectTrue(false, "\(error)")
            }
        }

        Check.test("site certificates an earlier version left in the keychain are found by their issuer and taken out") {
            let path = NSTemporaryDirectory() + "security-\(UUID().uuidString).keychain"
            var made: SecKeychain?
            guard SecKeychainCreate(path, 4, "test", false, nil, &made) == errSecSuccess, let keychain = made else {
                return Check.expectTrue(false, "no test keychain")
            }
            defer { SecKeychainDelete(keychain); try? FileManager.default.removeItem(atPath: path) }
            do {
                let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
                let root = try CertificateAuthority.make(key: key, machine: "Test Mac")
                guard let left = secCertificate(try root.issue(for: "visited.example", key: key.publicKey)) else {
                    return Check.expectTrue(false, "no certificate")
                }
                SecItemAdd([kSecClass as String: kSecClassCertificate, kSecValueRef as String: left,
                            kSecUseKeychain as String: keychain] as CFDictionary, nil)
                Check.expectEqual(SiteIdentities.siteCertificates(in: keychain).count, 1)
                _ = try SiteIdentities(authority: root, keychain: keychain)
                Check.expectEqual(SiteIdentities.siteCertificates(in: keychain).count, 0, "gone once the bridge starts")
            } catch {
                Check.expectTrue(false, "\(error)")
            }
        }
    }
}
