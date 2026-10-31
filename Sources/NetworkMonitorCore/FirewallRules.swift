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

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rules = defaults.data(forKey: Self.rulesKey)
            .flatMap { try? JSONDecoder().decode([FirewallRule].self, from: $0) } ?? []
        mode = defaults.string(forKey: Self.modeKey).flatMap(FirewallMode.init) ?? .anywhere
        lists = Set((defaults.stringArray(forKey: Self.listsKey) ?? []).compactMap(BlocklistTopic.init))
        blocksEverything = defaults.bool(forKey: Self.blocksEverythingKey)
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

    /// Any rule, replacing one with the same subject, key and app.
    public func add(_ rule: FirewallRule) {
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

    public func policy(onHotspot: Bool) -> FirewallPolicy {
        FirewallPolicy(mode: mode, rules: rules, onHotspot: onHotspot, lists: lists)
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
