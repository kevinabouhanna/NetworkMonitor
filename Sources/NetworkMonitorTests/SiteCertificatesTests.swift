import CryptoKit
import Foundation
import Security
import SiteCertificates
import SwiftASN1
import X509

/// Enhanced ad blocking's certificates (#682): a root made on this Mac, its
/// key unexportable, and a certificate per site that macOS trusts once the
/// root is trusted.
func runSiteCertificatesTests() {
    /// A keychain of the test's own, so nothing touches the person's.
    func testKeychain() -> (SecKeychain, () -> Void)? {
        let path = NSTemporaryDirectory() + "site-certificates-\(UUID().uuidString).keychain"
        var keychain: SecKeychain?
        let password = "test"
        guard SecKeychainCreate(path, UInt32(password.utf8.count), password, false, nil, &keychain) == errSecSuccess,
              let keychain else { return nil }
        return (keychain, { SecKeychainDelete(keychain); try? FileManager.default.removeItem(atPath: path) })
    }

    /// Whether macOS would accept `site` for `host`, with `root` trusted.
    func trusts(_ site: Certificate, root: Certificate, host: String, at date: Date = Date()) -> Bool {
        func secCertificate(_ certificate: Certificate) -> SecCertificate? {
            var serializer = DER.Serializer()
            guard (try? serializer.serialize(certificate)) != nil else { return nil }
            return SecCertificateCreateWithData(nil, Data(serializer.serializedBytes) as CFData)
        }
        guard let leaf = secCertificate(site), let anchor = secCertificate(root) else { return false }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates([leaf] as CFArray, SecPolicyCreateSSL(true, host as CFString),
                                             &trust) == errSecSuccess, let trust else { return false }
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        SecTrustSetVerifyDate(trust, date as CFDate)
        return SecTrustEvaluateWithError(trust, nil)
    }

    Check.suite("Enhanced ad blocking — the certificate made on this Mac (#682)") {

        Check.test("its key is made in the keychain, signs there, and can't be exported") {
            guard let (keychain, done) = testKeychain() else { return Check.expectTrue(false, "no test keychain") }
            defer { done() }
            do {
                let key = try AuthorityKey.make(in: keychain)
                Check.expectFalse(AuthorityKey.isExportable(key), "the root's key can be read out")
                let authority = try CertificateAuthority.make(key: Certificate.PrivateKey(key), machine: "Test Mac")
                Check.expectTrue(authority.certificate.subject.description.contains(CertificateAuthority.commonName))
                let constraints = try authority.certificate.extensions.basicConstraints
                Check.expectEqual(constraints, .isCertificateAuthority(maxPathLength: 0))
            } catch {
                Check.expectTrue(false, "\(error)")
            }
        }

        Check.test("a site's certificate is trusted for that site once the root is, and only for it") {
            guard let (keychain, done) = testKeychain() else { return Check.expectTrue(false, "no test keychain") }
            defer { done() }
            do {
                let authority = try CertificateAuthority.make(key: Certificate.PrivateKey(AuthorityKey.make(in: keychain)),
                                                              machine: "Test Mac")
                let sites = SiteCertificateCache(authority: authority)
                let site = try sites.certificate(for: "www.example.com")
                Check.expectTrue(trusts(site, root: authority.certificate, host: "www.example.com"), "trusted")
                Check.expectFalse(trusts(site, root: authority.certificate, host: "bank.example.com"), "another site")
                // Without the root trusted, nothing is.
                let stranger = try CertificateAuthority.make(key: Certificate.PrivateKey(P256.Signing.PrivateKey()),
                                                             machine: "Another Mac")
                Check.expectFalse(trusts(site, root: stranger.certificate, host: "www.example.com"), "another root")
                // An address, too.
                let address = try sites.certificate(for: "93.184.216.34")
                Check.expectTrue(trusts(address, root: authority.certificate, host: "93.184.216.34"), "an address")
            } catch {
                Check.expectTrue(false, "\(error)")
            }
        }

        Check.test("a site's certificate lasts a week, and is made again before it lapses") {
            do {
                let authority = try CertificateAuthority.make(key: Certificate.PrivateKey(P256.Signing.PrivateKey()),
                                                              machine: "Test Mac")
                let sites = SiteCertificateCache(authority: authority)
                let now = Date()
                let first = try sites.certificate(for: "Example.com", now: now)
                Check.expectTrue(first.notValidAfter <= now + CertificateAuthority.siteLifetime + 1)
                Check.expectEqual(try sites.certificate(for: "example.com", now: now + 3600), first, "kept")
                let later = now + CertificateAuthority.siteLifetime - 3600
                Check.expectTrue(try sites.certificate(for: "example.com", now: later) != first, "made again")
                Check.expectFalse(trusts(first, root: authority.certificate, host: "example.com",
                                         at: now + CertificateAuthority.siteLifetime + 3600), "lapsed")
            } catch {
                Check.expectTrue(false, "\(error)")
            }
        }

        Check.test("removed, the key is gone from the keychain") {
            guard let (keychain, done) = testKeychain() else { return Check.expectTrue(false, "no test keychain") }
            defer { done() }
            do {
                _ = try AuthorityKey.make(in: keychain)
                Check.expectEqual(AuthorityKey.find(in: keychain).count, 1)
                AuthorityKey.remove(from: keychain)
                Check.expectEqual(AuthorityKey.find(in: keychain).count, 0)
            } catch {
                Check.expectTrue(false, "\(error)")
            }
        }
    }
}
