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

    public static let rulesKey = "firewallRules"
    public static let modeKey = "firewallMode"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rules = defaults.data(forKey: Self.rulesKey)
            .flatMap { try? JSONDecoder().decode([FirewallRule].self, from: $0) } ?? []
        mode = defaults.string(forKey: Self.modeKey).flatMap(FirewallMode.init) ?? .anywhere
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
    public func setSite(_ action: RuleAction, domain: String, forName name: String) {
        let title = domain == name ? domain : "*.\(domain)"
        add(FirewallRule(subject: .site, key: domain, title: title, action: action))
    }

    /// Whether a row can have a rule: not "Unknown", and not "Other servers",
    /// which are many things at once.
    public static func canHaveRule(_ item: ConnectionsItem) -> Bool {
        item.key != ConnectionsReport.unknownKey && item.key != ConnectionsReport.otherKey
    }

    /// One rule per row: a new one replaces the old.
    public func set(_ action: RuleAction, for item: ConnectionsItem) {
        guard Self.canHaveRule(item), let subject = Self.subject(of: item) else { return }
        add(FirewallRule(subject: subject, key: item.key, title: item.title, action: action))
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

    public func policy(onHotspot: Bool) -> FirewallPolicy {
        FirewallPolicy(mode: mode, rules: rules, onHotspot: onHotspot)
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
