import CryptoKit
import Foundation
import Network
import Security
import SwiftASN1
import X509

// Enhanced ad blocking's certificates (#682, a step of #256). To remove ads
// from a secure page, NetworkMonitor has to answer for the site, so it needs a
// certificate the Mac trusts for that site. It makes one root certificate on
// this Mac when the switch goes on, trusted only once the person approves it,
// and from it a short-lived certificate per site, on demand, in memory.
//
// The root's private key never leaves the keychain it's made in: it signs
// through its `SecKey`, and is made unexportable. Security, CryptoKit and
// Network, no AppKit, so the filter, the app and the tests share it.

/// The root certificate made on this Mac, and what it signs with.
public struct CertificateAuthority {
    public let certificate: Certificate
    private let signer: Certificate.PrivateKey

    /// What the root is called wherever macOS shows it: Keychain Access, a
    /// certificate's details in a browser.
    public static let commonName = "NetworkMonitor Enhanced Ad Blocking"

    /// How long the root lasts. Two years: switched off and on again, it's
    /// made anew; a root that outlived the switch would be removed with it.
    public static let lifetime: TimeInterval = 2 * 365 * 24 * 3600

    /// How long a site's certificate lasts: a week, far under the 398 days
    /// macOS accepts, so a leaked one is soon worthless.
    public static let siteLifetime: TimeInterval = 7 * 24 * 3600

    public init(certificate: Certificate, key: Certificate.PrivateKey) {
        self.certificate = certificate
        self.signer = key
    }

    /// A new root, signed by `key`, named for this Mac (`machine`, such as
    /// its computer name) so two Macs' roots tell apart.
    public static func make(key: Certificate.PrivateKey, machine: String, now: Date = Date()) throws -> CertificateAuthority {
        let name = try DistinguishedName {
            CommonName("\(commonName) (\(machine))")
            OrganizationName("NetworkMonitor")
        }
        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
            Critical(KeyUsage(keyCertSign: true, cRLSign: true))
            SubjectKeyIdentifier(hash: key.publicKey)
        }
        let certificate = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(),
            publicKey: key.publicKey, notValidBefore: now - 3600, notValidAfter: now + lifetime,
            issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions, issuerPrivateKey: key)
        return CertificateAuthority(certificate: certificate, key: key)
    }

    /// A certificate for `host` (a name, or an address), for `key`, signed by
    /// this root: what a browser checks the site's identity against.
    public func issue(for host: String, key: Certificate.PublicKey, now: Date = Date()) throws -> Certificate {
        // A name as a certificate holds it: ASCII (one in another script
        // reaches us as punycode already), without a trailing dot.
        var host = host.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.allSatisfy({ $0.isASCII }) else { throw CertificateError.badName(host) }
        // The subject's common name holds 64 characters at most; browsers go
        // by the alternative name anyway, which is then the only one, and
        // marked critical as RFC 5280 asks of a certificate with no subject.
        let subject = host.count <= 64 ? try DistinguishedName { CommonName(host) } : DistinguishedName()
        let name: GeneralName
        if let address = IPv4Address(host) {
            name = .ipAddress(ASN1OctetString(contentBytes: ArraySlice(address.rawValue)))
        } else if let address = IPv6Address(host) {
            name = .ipAddress(ASN1OctetString(contentBytes: ArraySlice(address.rawValue)))
        } else {
            name = .dnsName(host)
        }
        let authorityKey = try certificate.extensions.subjectKeyIdentifier?.keyIdentifier
        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.notCertificateAuthority)
            Critical(KeyUsage(digitalSignature: true))
            try ExtendedKeyUsage([.serverAuth])
            if subject.isEmpty {
                Critical(SubjectAlternativeNames([name]))
            } else {
                SubjectAlternativeNames([name])
            }
            if let authorityKey { AuthorityKeyIdentifier(keyIdentifier: authorityKey) }
        }
        // Never past the root's own end, when no chain to it holds.
        let end = min(now + Self.siteLifetime, certificate.notValidAfter)
        return try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(),
            publicKey: key, notValidBefore: now - 3600, notValidAfter: end,
            issuer: certificate.subject, subject: subject, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions, issuerPrivateKey: signer)
    }

    /// As DER, for the keychain and the trust settings.
    public func der() throws -> Data {
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        return Data(serializer.serializedBytes)
    }
}

/// Site certificates, made once and kept until a day before they lapse. One
/// key for all of them, made in memory for this run: a site's certificate
/// is only as private as the process that holds it.
public final class SiteCertificateCache: @unchecked Sendable {
    public let authority: CertificateAuthority
    /// The public half of the one key every site's certificate is for.
    public let siteKey: Certificate.PublicKey
    private var issued: [String: Certificate] = [:]
    private let lock = NSLock()
    /// Enough for a day's browsing; past it, the half nearest their end are
    /// let go, to be made again when next asked for.
    public static let limit = 2_000

    public init(authority: CertificateAuthority,
                siteKey: Certificate.PublicKey = Certificate.PublicKey(P256.Signing.PrivateKey().publicKey)) {
        self.authority = authority
        self.siteKey = siteKey
    }

    public func certificate(for host: String, now: Date = Date()) throws -> Certificate {
        var host = host.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        lock.lock()
        // Kept until a day before it, or the root, lapses.
        if let kept = issued[host], kept.notValidAfter > now + 24 * 3600 { lock.unlock(); return kept }
        lock.unlock()
        let made = try authority.issue(for: host, key: siteKey, now: now)
        lock.lock()
        if issued.count >= Self.limit {
            let nearest = issued.sorted { $0.value.notValidAfter < $1.value.notValidAfter }.prefix(Self.limit / 2)
            for (name, _) in nearest { issued.removeValue(forKey: name) }
        }
        issued[host] = made
        lock.unlock()
        return made
    }
}

/// The root's key in a keychain: made there, unexportable, signing in place.
public enum AuthorityKey {
    /// The keychain item's label, to find and remove it.
    public static let label = "NetworkMonitor Enhanced Ad Blocking root key"

    /// A new P-256 key that can sign and can't be exported, in `keychain`
    /// (the System keychain for the filter; a test keychain in tests).
    public static func make(in keychain: SecKeychain? = nil) throws -> SecKey {
        // Unexportable said at the top as well as for the private key: said
        // only for the private key, a file keychain still let it be read out
        // (the test caught it).
        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsExtractable as String: false,
            kSecAttrIsSensitive as String: true,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrIsExtractable as String: false,
                kSecAttrIsSensitive as String: true,
                kSecAttrLabel as String: label,
            ] as [String: Any],
        ]
        if let keychain { attributes[kSecUseKeychain as String] = keychain }
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error?.takeRetainedValue() ?? CertificateError.keyNotMade
        }
        return key
    }

    /// The root's keys in `keychain`, by their label: one while the switch is
    /// on, none once it's off.
    public static func find(in keychain: SecKeychain? = nil) -> [SecKey] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return [] }
        return (result as? [SecKey]) ?? []
    }

    /// Takes every one of the root's keys out of `keychain`, for good, one
    /// by one (a file keychain's delete can stop at the first), and says
    /// whether any is left.
    @discardableResult
    public static func remove(from keychain: SecKeychain? = nil) -> Bool {
        for key in find(in: keychain) {
            let query: [String: Any] = [kSecClass as String: kSecClassKey, kSecValueRef as String: key]
            SecItemDelete(query as CFDictionary)
        }
        return find(in: keychain).isEmpty
    }

    /// Whether the key's private half can be read out: never, for ours.
    public static func isExportable(_ key: SecKey) -> Bool {
        SecKeyCopyExternalRepresentation(key, nil) != nil
    }
}

public enum CertificateError: Error {
    case keyNotMade
    /// Not a name a certificate can hold.
    case badName(String)
}
