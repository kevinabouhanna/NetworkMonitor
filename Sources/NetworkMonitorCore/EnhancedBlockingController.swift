import Combine
import CryptoKit
import FirewallPolicy
import Foundation
import os
import Security

/// Enhanced ad blocking's root as the app sees it (#685): the certificate the
/// filter makes in the System keychain when the switch goes on, and macOS's
/// trust in it, which only the person can give (macOS asks for their
/// password) and which is taken away when the switch goes off.
public enum EnhancedRoot {
    /// The root's name, before "(this Mac's name)": as the filter makes it
    /// (`CertificateAuthority.commonName`, held to it by a test).
    public static let name = "NetworkMonitor Enhanced Ad Blocking"

    static var systemKeychain: SecKeychain? {
        var keychain: SecKeychain?
        guard SecKeychainCopyDomainDefault(.system, &keychain) == errSecSuccess else { return nil }
        return keychain
    }

    /// The root in the System keychain that's still good, the latest if
    /// there were ever two; nil before the filter has made it.
    public static func current(now: Date = Date()) -> SecCertificate? {
        guard let system = systemKeychain else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate, kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll, kSecMatchSearchList as String: [system],
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        let roots = ((result as? [SecCertificate]) ?? []).filter {
            (SecCertificateCopySubjectSummary($0) as String?)?.hasPrefix(name + " (") == true
        }
        return roots
            .map { ($0, notValidAfter($0) ?? .distantPast) }
            .filter { $0.1 > now }
            .max { $0.1 < $1.1 }?.0
    }

    static func notValidAfter(_ certificate: SecCertificate) -> Date? {
        let key = kSecOIDX509V1ValidityNotAfter
        guard let values = SecCertificateCopyValues(certificate, [key] as CFArray, nil) as? [CFString: Any],
              let entry = values[key] as? [CFString: Any], let seconds = entry[kSecPropertyKeyValue] as? NSNumber else {
            return nil
        }
        return Date(timeIntervalSinceReferenceDate: seconds.doubleValue)
    }

    /// Its SHA-256, as the policy names the approved root.
    public static func fingerprint(_ certificate: SecCertificate) -> String {
        SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether the Mac's trust settings (the admin's, for every user) trust
    /// it as a root.
    public static func isTrusted(_ certificate: SecCertificate) -> Bool {
        var settings: CFArray?
        guard SecTrustSettingsCopyTrustSettings(certificate, .admin, &settings) == errSecSuccess else { return false }
        let entries = (settings as? [[String: Any]]) ?? []
        // No entries: trusted for everything.
        if entries.isEmpty { return true }
        return entries.contains { entry in
            let result = (entry[kSecTrustSettingsResult as String] as? NSNumber)?.uint32Value
                ?? SecTrustSettingsResult.trustRoot.rawValue
            return result == SecTrustSettingsResult.trustRoot.rawValue
        }
    }

    /// Trusts it for secure connections, for every user: macOS asks for the
    /// person's password. Blocks until they've answered: call it away from
    /// the main queue.
    public static func trust(_ certificate: SecCertificate) -> OSStatus {
        let settings: [[String: Any]] = [[
            kSecTrustSettingsPolicy as String: SecPolicyCreateSSL(true, nil),
            kSecTrustSettingsResult as String: NSNumber(value: SecTrustSettingsResult.trustRoot.rawValue),
        ]]
        return SecTrustSettingsSetTrustSettings(certificate, .admin, settings as CFArray)
    }

    /// Takes the trust away: macOS asks for the password again.
    public static func removeTrust(_ certificate: SecCertificate) -> OSStatus {
        SecTrustSettingsRemoveTrustSettings(certificate, .admin)
    }
}

/// Enhanced ad blocking's switch (#685): on only once the person has agreed
/// (the sheet) and approved the root (macOS's password dialog); off takes
/// the trust away, and the filter deletes the root, its key and the sites'
/// certificates.
public final class EnhancedBlockingController: ObservableObject {

    public enum Status: Equatable {
        case off
        /// On, waiting for the filter to make the root.
        case preparing
        /// macOS is asking for the password.
        case approving
        /// On, but the root isn't trusted: cancelled, refused, or a new root.
        case needsApproval
        case on
    }

    @Published public private(set) var status: Status
    /// The sheet that says what switching it on means, shown once each time.
    @Published public var asksToTurnOn = false
    @Published public var showsApps = false

    private let firewall: FirewallRules
    /// Seams for the tests: the root, its trust, and waiting.
    private let root: () -> SecCertificate?
    private let isTrusted: (SecCertificate) -> Bool
    private let trust: (SecCertificate) -> OSStatus
    private let removeTrust: (SecCertificate) -> OSStatus
    private let configureProxy: () -> Void
    private let work: DispatchQueue
    /// How long the filter has to make the root: the person may first be
    /// reading macOS's question about the proxy.
    static let rootWait: TimeInterval = 300
    private var waitID = 0

    static let log = Logger(subsystem: "com.kevinabouhanna.NetworkMonitor", category: "enhanced")

    public init(firewall: FirewallRules,
                root: @escaping () -> SecCertificate? = { EnhancedRoot.current() },
                isTrusted: @escaping (SecCertificate) -> Bool = EnhancedRoot.isTrusted,
                trust: @escaping (SecCertificate) -> OSStatus = EnhancedRoot.trust,
                removeTrust: @escaping (SecCertificate) -> OSStatus = EnhancedRoot.removeTrust,
                configureProxy: @escaping () -> Void = {},
                work: DispatchQueue = DispatchQueue(label: "com.kevinabouhanna.NetworkMonitor.enhanced")) { // untranslated
        self.firewall = firewall
        self.root = root
        self.isTrusted = isTrusted
        self.trust = trust
        self.removeTrust = removeTrust
        self.configureProxy = configureProxy
        self.work = work
        status = firewall.enhancedBlocking.isOn ? .preparing : .off
        if firewall.enhancedBlocking.isOn { check(asking: false) }
    }

    public var isOn: Bool { firewall.enhancedBlocking.isOn }

    /// A status shown as it is, for the accessibility and keyboard tests and
    /// the design pictures: nothing is asked or waited for.
    public func preview(_ status: Status) {
        waitID += 1
        self.status = status
    }

    /// The switch, as Settings shows it: on asks first.
    public func setOn(_ on: Bool) {
        if on {
            guard !isOn else { return }
            asksToTurnOn = true
        } else {
            turnOff()
        }
    }

    /// The sheet's Continue: on, then the root approved once the filter
    /// has made it.
    public func confirmTurnOn() {
        asksToTurnOn = false
        firewall.enhancedBlocking.isOn = true
        status = .preparing
        check(asking: true)
    }

    public func cancelTurnOn() {
        asksToTurnOn = false
    }

    /// Try Again: the proxy configured again (the person may have said no
    /// to macOS's question), and the root approved.
    public func tryAgain() {
        configureProxy()
        status = .preparing
        check(asking: true)
    }

    public func turnOff() {
        guard isOn else { return }
        waitID += 1
        let certificate = root()
        firewall.enhancedBlocking.isOn = false
        firewall.enhancedBlocking.trustedRoot = nil
        status = .off
        // The trust taken away; the filter deletes the root, its key and the
        // sites' certificates as the policy reaches it.
        guard let certificate, isTrusted(certificate) else { return }
        work.async { [removeTrust] in
            let status = removeTrust(certificate)
            if status != errSecSuccess {
                Self.log.notice("the root's trust wasn't removed: \(status); its key is deleted all the same")
            }
        }
    }

    /// Waits for the root, then (when `asking`) asks macOS to trust it.
    private func check(asking: Bool) {
        waitID += 1
        let id = waitID
        let deadline = Date().addingTimeInterval(Self.rootWait)
        func look() {
            work.async { [self] in
                let certificate = root()
                DispatchQueue.main.async { [self] in
                    guard id == waitID, isOn else { return }
                    guard let certificate else {
                        if Date() < deadline {
                            work.asyncAfter(deadline: .now() + 1) { look() }
                        } else {
                            status = .needsApproval
                        }
                        return
                    }
                    found(certificate, asking: asking, id: id)
                }
            }
        }
        look()
    }

    private func found(_ certificate: SecCertificate, asking: Bool, id: Int) {
        if isTrusted(certificate) {
            approved(certificate)
            return
        }
        guard asking else {
            status = .needsApproval
            return
        }
        status = .approving
        work.async { [self] in
            let result = trust(certificate)
            DispatchQueue.main.async { [self] in
                guard id == waitID, isOn else { return }
                if result == errSecSuccess, isTrusted(certificate) {
                    approved(certificate)
                } else {
                    Self.log.notice("the root wasn't approved: \(result)")
                    status = .needsApproval
                }
            }
        }
    }

    private func approved(_ certificate: SecCertificate) {
        let fingerprint = EnhancedRoot.fingerprint(certificate)
        if firewall.enhancedBlocking.trustedRoot != fingerprint { firewall.enhancedBlocking.trustedRoot = fingerprint }
        status = .on
    }

    // MARK: The apps it reaches

    /// Each browser (installed or not) and each app the person added, with
    /// whether it's reached; then the apps left alone.
    public var apps: [String] {
        let added = firewall.enhancedBlocking.addedAppList.filter { added in
            !EnhancedBlocking.browserApps.contains { EnhancedBlocking.family($0, includes: added) }
        }
        return EnhancedBlocking.browserApps + added
    }

    public func reaches(_ app: String) -> Bool { firewall.enhancedBlocking.reaches(app) }

    public func setReaches(_ app: String, _ on: Bool) {
        firewall.enhancedBlocking.setReaches(app, on)
        objectWillChange.send()
    }

    public var leftAlone: [String] { firewall.enhancedBlocking.pinnedApps.sorted() }

    /// Try Again for an app left alone: it's opened again, until it refuses.
    public func forgetLeftAlone(_ app: String) {
        firewall.enhancedBlocking.forgetPinned(app)
        objectWillChange.send()
    }
}
