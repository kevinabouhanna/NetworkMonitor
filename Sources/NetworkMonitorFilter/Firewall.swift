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
    /// The country and network-owner data: the copy inside the extension, or
    /// a newer month the app sent since (#121).
    private var directory: ServerDirectory?
    private var directoryMonth: String?
    /// The ad, tracker and malware lists (#176), as the app last sent them.
    private var blocklists: Blocklists?
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
        /// NetworkMonitor itself, signed by its team (#121).
        let isNetworkMonitor: Bool
    }

    private init() {
        policy = (try? Data(contentsOf: Self.storeURL)).flatMap(FirewallPolicy.decode) ?? FirewallPolicy()
        if let newest = ServerDirectory.newest(downloaded: Self.geoURL) {
            directory = newest.directory
            directoryMonth = newest.month
        }
        blocklists = Blocklists(directory: Self.listsURL)
    }

    /// In the extension's own container. It runs as root, so this is root's.
    private static var supportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }
    private static var storeURL: URL { supportURL.appendingPathComponent("policy.json") }
    private static var geoURL: URL { supportURL.appendingPathComponent("Geo", isDirectory: true) }
    private static var listsURL: URL { supportURL.appendingPathComponent("Blocklists", isDirectory: true) }

    /// The lists from the app (#176): kept in the container so they apply
    /// from launch, and used if they open and aren't older than what's here.
    func applyBlocklists(_ files: [BlocklistTopic: FileHandle], version: String) {
        defer { files.values.forEach { try? $0.close() } }
        lock.lock()
        let current = blocklists?.version
        lock.unlock()
        guard Blocklists.isVersion(version), current.map({ version >= $0 }) ?? true,
              Set(files.keys) == Set(BlocklistTopic.allCases) else { return }
        do {
            var tables: [BlocklistTopic: BlocklistTable] = [:]
            var data: [BlocklistTopic: Data] = [:]
            for (topic, handle) in files {
                let bytes = try handle.readToEnd() ?? Data()
                tables[topic] = try BlocklistTable(data: bytes)
                data[topic] = bytes
            }
            let manager = FileManager.default
            try? manager.removeItem(at: Self.listsURL)
            try manager.createDirectory(at: Self.listsURL, withIntermediateDirectories: true)
            for (topic, bytes) in data { try bytes.write(to: Self.listsURL.appendingPathComponent(topic.fileName)) }
            try Data((version + "\n").utf8).write(to: Self.listsURL.appendingPathComponent(Blocklists.versionFile))
            lock.lock()
            blocklists = Blocklists(tables: tables, version: version)
            lock.unlock()
            log.notice("lists from \(version, privacy: .public)")
        } catch {
            log.error("couldn't use the lists from \(version, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The switched-on lists holding a name.
    private func listed(_ name: String?, in policy: FirewallPolicy) -> Set<BlocklistTopic> {
        guard let name, !policy.lists.isEmpty else { return [] }
        lock.lock()
        let lists = blocklists
        lock.unlock()
        return lists?.topics(listing: name).intersection(policy.lists) ?? []
    }

    /// A newer month from the app. Kept only if it's newer than what's in
    /// use and the tables open; the app checked its signature already.
    func applyGeoData(countries: FileHandle, owners: FileHandle, month: String) {
        lock.lock()
        let current = directoryMonth
        lock.unlock()
        guard GeoData.isMonth(month), current.map({ month > $0 }) ?? true else { return }
        do {
            let tables = [("countries.bin", try countries.readToEnd() ?? Data()),
                          ("owners.bin", try owners.readToEnd() ?? Data())]
            let replacement = try ServerDirectory(countries: RangeTable(data: tables[0].1),
                                                  owners: RangeTable(data: tables[1].1))
            let manager = FileManager.default
            try? manager.removeItem(at: Self.geoURL)
            try manager.createDirectory(at: Self.geoURL, withIntermediateDirectories: true)
            for (name, data) in tables { try data.write(to: Self.geoURL.appendingPathComponent(name)) }
            try Data((month + "\n").utf8).write(to: Self.geoURL.appendingPathComponent(GeoData.monthFile))
            lock.lock()
            directory = replacement
            directoryMonth = month
            lock.unlock()
            log.notice("data from \(month, privacy: .public)")
        } catch {
            log.error("couldn't use the data from \(month, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        try? countries.close()
        try? owners.close()
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
    /// What happens to a new flow: allowed, blocked, or held while the app
    /// asks (#129). A blocked one carries what blocked it and the app it was
    /// for, for the report.
    struct Decision {
        let verdict: NEFilterNewFlowVerdict
        var blockedBy: String?
        var appKey: String?
        /// Allowed outright: neither blocked nor held for Ask Me.
        var allows = false
        /// What the rules were asked, for deciding again once a nameless
        /// connection's handshake names it (#197). Nil with nothing to decide.
        var facts: FlowFacts?
        /// Ask Me, put off until the handshake names the site (#199).
        var asks = false
        var company: Company?

        static let allow = Decision(verdict: .allow(), allows: true)
    }

    /// `deferAsk` for a nameless connection whose handshake will be read: a
    /// question waits for the site's name rather than asking about the
    /// network's owner (#199).
    func decide(_ flow: NEFilterSocketFlow, address: String, port: Int, report: FlowReport,
                deferAsk: Bool = false) -> Decision {
        let (verdict, appKey, facts, company) = self.verdict(for: flow, address: address, port: port)
        switch verdict {
        case .allow:
            return Decision(verdict: .allow(), appKey: appKey, allows: true, facts: facts)
        case .block(let reason):
            return Decision(verdict: .drop(), blockedBy: reason.id, appKey: appKey, facts: facts)
        case .ask:
            guard let appKey, let facts else { return .allow }
            if deferAsk {
                return Decision(verdict: .allow(), appKey: appKey, facts: facts, asks: true, company: company)
            }
            switch hold(flow, dataStage: false, appKey: appKey, facts: facts, company: company, report: report) {
            case .allow: return .allow
            case .block: return Decision(verdict: .drop(), blockedBy: "ask", appKey: appKey)
            case .held:  return Decision(verdict: .pause())
            }
        }
    }

    /// Ask Me for a connection whose handshake was read first (#199): its
    /// first bytes are held in the data callback while the app asks.
    func askNamed(_ flow: NEFilterFlow, appKey: String, facts: FlowFacts, company: Company?,
                  report: FlowReport) -> NEFilterDataVerdict {
        switch hold(flow, dataStage: true, appKey: appKey, facts: facts, company: company, report: report) {
        case .allow: return .allow()
        case .block: return .drop()
        case .held:  return .pause()
        }
    }

    /// The company a name belongs to, or failing that, the network's owner.
    func company(named name: String, otherwise owner: Company?) -> Company? {
        Company.named(byHostname: name) ?? owner
    }

    private func verdict(for flow: NEFilterSocketFlow, address: String, port: Int)
        -> (Verdict, appKey: String?, facts: FlowFacts?, company: Company?) {
        let policy = current
        // Nothing to block: nothing to look up.
        guard policy.isActive else { return (.allow(.mode), nil, nil, nil) }
        let address = FirewallPolicy.serverAddress(address)
        if FirewallPolicy.isEssential(address: address, port: port) { return (.allow(.essential), nil, nil, nil) }
        let identity = self.identity(of: flow)
        lock.lock()
        let directory = self.directory
        lock.unlock()
        let info = directory?.lookup(address)
        let company = flow.remoteHostname.flatMap(Company.named(byHostname:)) ?? info?.owner?.company
        let facts = FlowFacts(appKeys: identity.appKeys, companyKey: company?.key, country: info?.country,
                              address: address, port: port, isApple: identity.isApple,
                              executablePaths: identity.paths, hostname: flow.remoteHostname,
                              isNetworkMonitor: identity.isNetworkMonitor,
                              listedIn: listed(flow.remoteHostname, in: policy))
        let verdict = policy.decide(facts)
        if case .block(let reason) = verdict {
            // Debug level: kept only while someone streams the log.
            log.debug("""
                blocked \(address, privacy: .public):\(port) for \(facts.appKeys, privacy: .public), \
                \(facts.companyKey ?? "-", privacy: .public), \(facts.country ?? "-", privacy: .public), \
                by \(reason.id, privacy: .public)
                """)
        }
        return (verdict, identity.primaryKey, facts, company)
    }

    /// The rules' answer once a connection that arrived without a name has
    /// one from its handshake (#197): a site rule can match it now, and its
    /// company is the name's rather than the network owner's.
    func verdict(for facts: FlowFacts, named name: String) -> Verdict {
        let policy = current
        var named = facts
        named.hostname = name
        named.listedIn = listed(name, in: policy)
        if let company = Company.named(byHostname: name) { named.companyKey = company.key }
        return policy.decide(named)
    }

    // MARK: Ask Me (#129)

    /// One question's held flows, and their reports, for if the answer is no.
    /// A flow held in its data callback (#199) is resumed with a data verdict.
    private struct Held {
        let pair: String
        let appKey: String
        var flows: [(flow: NEFilterFlow, dataStage: Bool)]
        var reports: [FlowReport]
    }

    private enum HoldOutcome { case allow, block, held }

    /// Set by the provider when it starts: flows are resumed through it.
    weak var provider: NEFilterDataProvider?
    private var held: [String: Held] = [:]
    private var heldByPair: [String: String] = [:]
    /// Answers given, by app and company, and until when they hold.
    private var answered: [String: (allows: Bool, until: Date)] = [:]

    static let askTimeout: TimeInterval = 30
    /// Allow Once, and no answer: the same app and company go ahead for an hour.
    static let onceFor: TimeInterval = 60 * 60
    /// Always Allow and Block: until the rule the app makes arrives.
    static let ruleFor: TimeInterval = 60

    /// What a question is about: the company when it's a real one, and on a
    /// host's network, where the owner says nothing, the site (#199).
    static func subject(of facts: FlowFacts, company: Company?) -> String {
        if let company, !company.isHost { return company.key }
        if let name = facts.hostname { return "site:" + SiteName.site(of: name) }
        return facts.companyKey ?? facts.address
    }

    /// One question per app and company, or site on a host's network: every
    /// flow between them waits on the first one's answer. With the app not
    /// there to ask, it goes ahead.
    private func hold(_ flow: NEFilterFlow, dataStage: Bool, appKey: String, facts: FlowFacts, company: Company?,
                      report: FlowReport) -> HoldOutcome {
        let pair = appKey + "|" + Self.subject(of: facts, company: company)
        let connected = AppLink.shared.isConnected
        let now = Date()
        lock.lock()
        if let earlier = answered[pair], earlier.until > now {
            lock.unlock()
            return earlier.allows ? .allow : .block
        }
        guard connected else { lock.unlock(); return .allow }
        if let id = heldByPair[pair] {
            held[id]?.flows.append((flow, dataStage))
            held[id]?.reports.append(report)
            lock.unlock()
            return .held
        }
        let id = UUID().uuidString
        held[id] = Held(pair: pair, appKey: appKey, flows: [(flow, dataStage)], reports: [report])
        heldByPair[pair] = id
        if answered.count > 512 { answered = answered.filter { $0.value.until > now } }
        lock.unlock()

        AppLink.shared.ask(FlowQuestion(id: id, appKey: appKey, companyKey: company?.key, companyName: company?.name,
                                        companyIsHost: company?.isHost ?? false, hostname: facts.hostname,
                                        address: facts.address, country: facts.country,
                                        deadline: now + Self.askTimeout, port: facts.port))
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.askTimeout) { [weak self] in
            self?.resolve(id, .allowOnce, expired: true)
        }
        return .held
    }

    func answer(_ id: String, _ answer: FlowAnswer) {
        resolve(id, answer, expired: false)
    }

    private func resolve(_ id: String, _ answer: FlowAnswer, expired: Bool) {
        lock.lock()
        guard let question = held.removeValue(forKey: id) else { lock.unlock(); return }
        heldByPair.removeValue(forKey: question.pair)
        let allows = answer != .block
        answered[question.pair] = (allows, Date() + (answer == .allowOnce ? Self.onceFor : Self.ruleFor))
        lock.unlock()

        for (flow, dataStage) in question.flows {
            if dataStage {
                provider?.resumeFlow(flow, with: allows ? NEFilterDataVerdict.allow() : NEFilterDataVerdict.drop())
            } else {
                provider?.resumeFlow(flow, with: allows ? NEFilterNewFlowVerdict.allow() : NEFilterNewFlowVerdict.drop())
            }
        }
        if !allows {
            for report in question.reports {
                AppLink.shared.report(FlowReport(address: report.address, port: report.port, hostname: report.hostname,
                                                 pid: report.pid, time: report.time, blockedBy: "ask",
                                                 appKey: question.appKey))
            }
        }
        if expired { AppLink.shared.expired(id) }
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
                                isApple: (app ?? process).map(Self.isSignedByApple) ?? false, paths: paths,
                                isNetworkMonitor: (app ?? process).map(Self.isNetworkMonitor) ?? false)

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

    private static let networkMonitor: SecRequirement? = {
        var requirement: SecRequirement?
        SecRequirementCreateWithString(FilterIdentity.appRequirement as CFString, [], &requirement)
        return requirement
    }()

    /// The app itself, by the same check the XPC link makes.
    private static func isNetworkMonitor(_ token: Data) -> Bool {
        guard let code = guestCode(token), let networkMonitor else { return false }
        return SecCodeCheckValidity(code, [], networkMonitor) == errSecSuccess
    }

    private static func guestCode(_ token: Data) -> SecCode? {
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: token] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess else { return nil }
        return code
    }
}
