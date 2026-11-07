import Combine
import FirewallPolicy
import Foundation

/// The person's rules (#114): what they blocked or always allowed in
/// Connections, and what everything else does. Kept in the app's defaults;
/// the content filter is sent a copy, with whether the Mac is on a hotspot,
/// every time any of it changes.
public final class FirewallRules: ObservableObject {
    /// Newest first, as the list in Settings shows them.
    @Published public private(set) var rules: [FirewallRule]
    @Published public var mode: FirewallMode {
        didSet { defaults.set(mode.rawValue, forKey: Self.modeKey) }
    }
    /// The ad, tracker and malware lists switched on (#176). None at first.
    @Published public var lists: Set<BlocklistTopic> {
        didSet { defaults.set(lists.map(\.rawValue).sorted(), forKey: Self.listsKey) }
    }

    /// Ad blocking paused (#251): the lists stay chosen, and the filter is
    /// sent none until then. Nil when it isn't paused.
    @Published public private(set) var listsPausedUntil: Date? {
        didSet { defaults.set(listsPausedUntil, forKey: Self.listsPausedKey) }
    }
    private var resumeTimer: Timer?

    /// Your own ad-blocking rules (#253), newest first.
    @Published public private(set) var adRules: [AdRule]
    public static let adRulesKey = "adRules"

    public static let listsPausedKey = "blocklistsPausedUntil"

    /// Networks where ad blocking is off (#253), by identity, with their
    /// names: a work network that needs a listed site, say.
    @Published public private(set) var listsPausedNetworks: [String: String] {
        didSet { defaults.set(listsPausedNetworks, forKey: Self.listsPausedNetworksKey) }
    }
    public static let listsPausedNetworksKey = "blocklistsPausedNetworks"
    public static let rulesKey = "firewallRules"
    public static let modeKey = "firewallMode"
    public static let listsKey = "blocklists"
    public static let blocksEverythingKey = "blockEverything"

    /// Block Everything (#198), from the right-click menu. Kept across a
    /// relaunch, like the filter's own copy, until it's turned off.
    @Published public var blocksEverything: Bool {
        didSet { defaults.set(blocksEverything, forKey: Self.blocksEverythingKey) }
    }

    private let defaults: UserDefaults
    /// The team that signed an app key's program (#202).
    private let teamOf: (String) -> String?

    public init(defaults: UserDefaults = .standard, teamOf: @escaping (String) -> String? = AppMaker.team(forAppKey:)) {
        self.defaults = defaults
        self.teamOf = teamOf
        rules = defaults.data(forKey: Self.rulesKey)
            .flatMap { try? JSONDecoder().decode([FirewallRule].self, from: $0) } ?? []
        mode = defaults.string(forKey: Self.modeKey).flatMap(FirewallMode.init) ?? .anywhere
        lists = Set((defaults.stringArray(forKey: Self.listsKey) ?? []).compactMap(BlocklistTopic.init))
        blocksEverything = defaults.bool(forKey: Self.blocksEverythingKey)
        adRules = defaults.data(forKey: Self.adRulesKey)
            .flatMap { try? JSONDecoder().decode([AdRule].self, from: $0) } ?? []
        listsPausedUntil = (defaults.object(forKey: Self.listsPausedKey) as? Date).flatMap { $0 > Date() ? $0 : nil }
        listsPausedNetworks = defaults.dictionary(forKey: Self.listsPausedNetworksKey) as? [String: String] ?? [:]
        scheduleResume()
    }

    /// The lists the filter is sent: none while paused, or on a network
    /// where ad blocking is off.
    public static func activeLists(_ lists: Set<BlocklistTopic>, pausedUntil: Date?, network: String? = nil,
                                   pausedNetworks: Set<String> = [], now: Date = Date()) -> Set<BlocklistTopic> {
        if let network, pausedNetworks.contains(network) { return [] }
        guard let pausedUntil, pausedUntil > now else { return lists }
        return []
    }

    /// Ad blocking off, or on again, wherever the Mac is on `network`.
    public func pauseLists(on network: CurrentNetwork, _ paused: Bool) {
        var updated = listsPausedNetworks
        updated[network.id] = paused ? network.name : nil
        listsPausedNetworks = updated
    }

    public func resumeLists(onNetwork id: String) {
        var updated = listsPausedNetworks
        updated[id] = nil
        listsPausedNetworks = updated
    }

    /// Pauses ad blocking until `date`, or resumes it with nil.
    public func pauseLists(until date: Date?) {
        listsPausedUntil = date.flatMap { $0 > Date() ? $0 : nil }
        scheduleResume()
    }

    private func scheduleResume() {
        resumeTimer?.invalidate()
        resumeTimer = nil
        guard let until = listsPausedUntil else { return }
        let timer = Timer(fire: until, interval: 0, repeats: false) { [weak self] _ in
            self?.pauseLists(until: nil)
        }
        RunLoop.main.add(timer, forMode: .common)
        resumeTimer = timer
    }

    // MARK: Ad-blocking rules (#253)

    /// Adds a rule, replacing one for the same site and app: a site is
    /// either never or always blocked, not both. One app's rule remembers the
    /// team that signed it (#320).
    public func add(_ rule: AdRule) {
        guard rule.isValid else { return }
        let rule = signed(rule)
        var updated = adRules.filter { !($0.site == rule.site && $0.appKey == rule.appKey) }
        updated.insert(rule, at: 0)
        saveAdRules(updated)
    }

    /// Several at once, as an import brings them, saved and sent once. The
    /// last for a site and app wins.
    public func add(_ rules: [AdRule]) {
        var updated = adRules
        for rule in rules.map(signed) where rule.isValid {
            updated.removeAll { $0.site == rule.site && $0.appKey == rule.appKey }
            updated.insert(rule, at: 0)
        }
        saveAdRules(updated)
    }

    private func signed(_ rule: AdRule) -> AdRule {
        rule.team == nil ? rule.appKey.flatMap(teamOf).map(rule.signed(by:)) ?? rule : rule
    }

    public func remove(_ rule: AdRule) {
        saveAdRules(adRules.filter { $0.id != rule.id })
    }

    /// The rule a report names, by its id.
    public func adRule(id: String) -> AdRule? {
        adRules.first { $0.id == id }
    }

    private func saveAdRules(_ updated: [AdRule]) {
        adRules = updated
        defaults.set(try? JSONEncoder().encode(updated), forKey: Self.adRulesKey)
    }

    /// The rule for every app on a row. Rules for one app, made by answering
    /// Ask Me, are listed in Settings. A server with a name follows the
    /// narrowest site rule covering it (#197), then a rule for its address.
    public func rule(for item: ConnectionsItem) -> FirewallRule? {
        if let name = Self.serverName(of: item) {
            for domain in SiteName.domains(of: name) {
                if let rule = rules.first(where: { $0.subject == .site && $0.key == domain && $0.appKey == nil }) {
                    return rule
                }
            }
        }
        guard let subject = Self.subject(of: item) else { return nil }
        return rules.first { $0.subject == subject && $0.key == item.key && $0.appKey == nil }
    }

    /// A server row's name, when the filter saw one (#197).
    public static func serverName(of item: ConnectionsItem) -> String? {
        guard item.dimension == .server, item.title != item.key else { return nil }
        return SiteName.normalized(item.title)
    }

    /// What a server named `name` can have a rule on: the name itself, and
    /// its whole site when that's wider. `stats.wp.com` offers `wp.com` too.
    public static func siteScopes(for name: String) -> [String] {
        let site = SiteName.site(of: name)
        return site == name ? [name] : [name, site]
    }

    /// A rule for a site: `domain` and every name under it (#197). The whole
    /// site reads `*.wp.com`; one name reads as itself.
    public func setSite(_ action: RuleAction, domain: String, forName name: String,
                        network: CurrentNetwork? = nil) {
        let title = domain == name ? domain : "*.\(domain)"
        add(FirewallRule(subject: .site, key: domain, title: title, action: action,
                         network: network?.id, networkTitle: network?.name))
    }

    /// Whether a row can have a rule: not "Unknown", and not "Other servers",
    /// which are many things at once.
    public static func canHaveRule(_ item: ConnectionsItem) -> Bool {
        item.key != ConnectionsReport.unknownKey && item.key != ConnectionsReport.otherKey
    }

    /// One rule per row: a new one replaces the old. With `network`, it
    /// applies only there (#200).
    public func set(_ action: RuleAction, for item: ConnectionsItem, network: CurrentNetwork? = nil) {
        guard Self.canHaveRule(item), let subject = Self.subject(of: item) else { return }
        add(FirewallRule(subject: subject, key: item.key, title: item.title, action: action,
                         network: network?.id, networkTitle: network?.name))
    }

    /// The network a rule can be made for (#200): its identity and its name.
    public struct CurrentNetwork: Equatable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// Any rule, replacing one with the same subject, key and app. A rule
    /// about an app remembers the team that signed it (#202).
    public func add(_ rule: FirewallRule) {
        let rule = rule.team == nil ? rule.ruledApp.flatMap(teamOf).map(rule.signed(by:)) ?? rule : rule
        var updated = rules.filter { $0.id != rule.id }
        updated.insert(rule, at: 0)
        save(updated)
    }

    public func remove(_ rule: FirewallRule) {
        save(rules.filter { $0.id != rule.id })
    }

    /// An app quit: its answers for this session go (#199).
    public func removeRules(untilQuitOf appKey: String) {
        let kept = rules.filter { !($0.lastsUntilQuit && $0.appKey == appKey) }
        if kept.count != rules.count { save(kept) }
    }

    /// At launch: answers for apps that aren't running any more, quit while
    /// NetworkMonitor wasn't, go too.
    public func pruneUntilQuit(running appKeys: Set<String>) {
        let kept = rules.filter { !$0.lastsUntilQuit || $0.appKey.map(appKeys.contains) == true }
        if kept.count != rules.count { save(kept) }
    }

    // MARK: Export and import (#201)

    /// What Export writes: the rules, in a file that says what it is.
    public struct RulesFile: Codable, Equatable {
        public let networkMonitorRules: Int
        public let rules: [FirewallRule]

        public static let format = 1
    }

    public enum ImportError: Error, Equatable {
        case notRules
    }

    /// Every rule, newest first, as a file another Mac can import. Answers
    /// "until it quits" (#199) are for this session on this Mac, so they stay.
    public func exportData() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let lasting = rules.filter { !$0.lastsUntilQuit }
        return (try? encoder.encode(RulesFile(networkMonitorRules: RulesFile.format, rules: lasting))) ?? Data()
    }

    /// Adds the rules in an exported file, or a plain list of them, that
    /// aren't here already. Never replaces one: a rule here wins. Returns how
    /// many were added, and how many were already here.
    @discardableResult
    public func importRules(from data: Data) throws -> (added: Int, alreadyHere: Int) {
        let decoder = JSONDecoder()
        guard let incoming = (try? decoder.decode(RulesFile.self, from: data))?.rules
                ?? (try? decoder.decode([FirewallRule].self, from: data))
        else { throw ImportError.notRules }
        var seen = Set(rules.map(\.id))
        var added: [FirewallRule] = []
        for rule in incoming where !seen.contains(rule.id) {
            seen.insert(rule.id)
            added.append(rule)
        }
        if !added.isEmpty { save(added + rules) }
        return (added.count, incoming.count - added.count)
    }

    /// "Added 3 rules. 2 were already here."
    public static func importSummary(added: Int, alreadyHere: Int) -> String {
        let first = added == 0 ? "No new rules." : "Added \(added) rule\(added == 1 ? "" : "s")."
        guard alreadyHere > 0 else { return first }
        return first + " \(alreadyHere) \(alreadyHere == 1 ? "was" : "were") already here."
    }

    public func policy(onHotspot: Bool) -> FirewallPolicy {
        FirewallPolicy(mode: mode, rules: rules, onHotspot: onHotspot, lists: lists, adRules: adRules)
    }

    static func subject(of item: ConnectionsItem) -> RuleSubject? {
        RuleSubject(rawValue: item.dimension.rawValue)
    }

    private func save(_ updated: [FirewallRule]) {
        rules = updated
        defaults.set(try? JSONEncoder().encode(updated), forKey: Self.rulesKey)
    }
}

extension RuleAction {
    /// What a row with this rule says about itself.
    public var badge: String {
        switch self {
        case .block:           return "Blocked"
        case .blockOnHotspots: return "Blocked on hotspots"
        case .allow:           return "Always allowed"
        }
    }
}
