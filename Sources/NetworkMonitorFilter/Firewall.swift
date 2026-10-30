import Darwin
import FilterProtocol
import FirewallPolicy
import Foundation
import NetworkExtension
import os
import Security
import ServerDirectory

/// The filter's side of the rules (#114): the policy the app last sent, kept
/// on disk so it applies from the moment the filter starts, and what each new
/// connection is, in the terms the rules use.
///
/// Anything it can't work out is left out of the facts, and a rule that can't
/// be matched doesn't block: the filter fails open.
final class Firewall {

    static let shared = Firewall()

    private let lock = NSLock()
    private var policy: FirewallPolicy
    /// The country and network-owner data, which ships inside the extension.
    private lazy var directory = ServerDirectory.bundled()
    /// Per audit token, which names one run of one process.
    private var identities: [Data: Identity] = [:]
    private static let identityLimit = 4096
    private let log = Logger(subsystem: FilterIdentity.extensionIdentifier, category: "firewall")

    private struct Identity {
        let appKeys: [String]
        /// The app the connection is for, as a blocked attempt is listed.
        let primaryKey: String?
        let isApple: Bool
        /// The programs themselves, to tell an updater from its app (#98).
        let paths: [String]
    }

    private init() {
        policy = (try? Data(contentsOf: Self.storeURL)).flatMap(FirewallPolicy.decode) ?? FirewallPolicy()
    }

    /// In the extension's own container. It runs as root, so this is root's.
    private static var storeURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("policy.json")
    }

    func apply(_ policy: FirewallPolicy) {
        lock.lock()
        self.policy = policy
        lock.unlock()
        let url = Self.storeURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? policy.encoded().write(to: url, options: .atomic)
        log.info("policy: \(policy.rules.count) rules, \(policy.mode.rawValue), hotspot \(policy.onHotspot)")
    }

    private var current: FirewallPolicy {
        lock.lock(); defer { lock.unlock() }
        return policy
    }

    /// The verdict, and for a blocked connection, the app it was for.
    func verdict(for flow: NEFilterSocketFlow, address: String, port: Int) -> (verdict: Verdict, appKey: String?) {
        let policy = current
        // Nothing to block: nothing to look up.
        guard policy.isActive else { return (.allow(.mode), nil) }
        let address = FirewallPolicy.serverAddress(address)
        if FirewallPolicy.isEssential(address: address, port: port) { return (.allow(.essential), nil) }
        let identity = self.identity(of: flow)
        let info = directory?.lookup(address)
        let company = flow.remoteHostname.flatMap(Company.named(byHostname:)) ?? info?.owner?.company
        let facts = FlowFacts(appKeys: identity.appKeys, companyKey: company?.key, country: info?.country,
                              address: address, port: port, isApple: identity.isApple,
                              executablePaths: identity.paths, hostname: flow.remoteHostname)
        let verdict = policy.decide(facts)
        if case .block(let reason) = verdict {
            // Debug level: kept only while someone streams the log.
            log.debug("""
                blocked \(address, privacy: .public):\(port) for \(facts.appKeys, privacy: .public), \
                \(facts.companyKey ?? "-", privacy: .public), \(facts.country ?? "-", privacy: .public), \
                by \(reason.id, privacy: .public)
                """)
            return (verdict, identity.primaryKey)
        }
        return (verdict, nil)
    }

    // MARK: Which app

    private func identity(of flow: NEFilterFlow) -> Identity {
        let app = flow.sourceAppAuditToken
        let process = flow.sourceProcessAuditToken
        let cacheKey = (app ?? Data()) + (process ?? Data())
        lock.lock()
        if let cached = identities[cacheKey] { lock.unlock(); return cached }
        lock.unlock()

        let processPath = process.flatMap(Self.path)
        let appPath = app.flatMap(Self.path)
        let processKeys = process.map(appKeys) ?? []
        let appTokenKeys = app.map(appKeys) ?? []
        var keys: [String] = []
        for key in processKeys + appTokenKeys where !keys.contains(key) { keys.append(key) }
        var paths: [String] = []
        for path in [processPath, appPath].compactMap({ $0 }) where !paths.contains(path) { paths.append(path) }
        let identity = Identity(appKeys: keys, primaryKey: appTokenKeys.first ?? processKeys.first,
                                isApple: (app ?? process).map(Self.isSignedByApple) ?? false, paths: paths)

        lock.lock()
        if identities.count >= Self.identityLimit { identities.removeAll() }
        identities[cacheKey] = identity
        lock.unlock()
        return identity
    }

    /// The keys Connections would list this process under: its app, or for a
    /// program outside any app, itself under the app that started it, then
    /// that app.
    private func appKeys(_ token: Data) -> [String] {
        let pid = FlowReport.pid(fromAuditToken: token)
        guard let path = Self.path(token) else { return [] }
        if let bundle = AppKey.bundlePath(forExecutablePath: path) { return [bundle] }
        if let parent = Self.nearestApp(above: pid) {
            return [AppKey.key(adopting: path, by: parent), path, parent]
        }
        return [path]
    }

    /// The program behind a token: from the process table, or failing that,
    /// its code signature.
    private static func path(_ token: Data) -> String? {
        executablePath(pid: FlowReport.pid(fromAuditToken: token)) ?? signedPath(token)
    }

    private static func executablePath(pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 2)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    /// From the code signature, should the process table be closed to the
    /// sandbox.
    private static func signedPath(_ token: Data) -> String? {
        guard let code = guestCode(token) else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var url: CFURL?
        guard SecCodeCopyPath(staticCode, [], &url) == errSecSuccess, let url else { return nil }
        // The bundle for a bundled program; its executable sits inside it.
        return (url as URL).path
    }

    /// The nearest `.app` above `pid`, as `AppIdentityResolver` adopts.
    private static func nearestApp(above pid: Int32) -> String? {
        var current = pid
        for _ in 0..<8 {
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(current, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
            let parent = Int32(bitPattern: info.pbsi_ppid)
            guard parent > 1, parent != current else { return nil }
            current = parent
            if let path = executablePath(pid: current), let bundle = AppKey.bundlePath(forExecutablePath: path) {
                return bundle
            }
        }
        return nil
    }

    // MARK: Apple's own

    private static let apple: SecRequirement? = {
        var requirement: SecRequirement?
        SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement)
        return requirement
    }()

    /// macOS itself, or one of Apple's apps: signed by Apple, not by a
    /// developer through Apple.
    private static func isSignedByApple(_ token: Data) -> Bool {
        guard let code = guestCode(token), let apple else { return false }
        return SecCodeCheckValidity(code, [], apple) == errSecSuccess
    }

    private static func guestCode(_ token: Data) -> SecCode? {
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: token] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess else { return nil }
        return code
    }
}
