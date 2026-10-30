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

    public func rule(for item: ConnectionsItem) -> FirewallRule? {
        guard let subject = Self.subject(of: item) else { return nil }
        return rules.first { $0.subject == subject && $0.key == item.key }
    }

    /// Whether a row can have a rule: not "Unknown", and not "Other servers",
    /// which are many things at once.
    public static func canHaveRule(_ item: ConnectionsItem) -> Bool {
        item.key != ConnectionsReport.unknownKey && item.key != ConnectionsReport.otherKey
    }

    /// One rule per row: a new one replaces the old.
    public func set(_ action: RuleAction, for item: ConnectionsItem) {
        guard Self.canHaveRule(item), let subject = Self.subject(of: item) else { return }
        var updated = rules.filter { !($0.subject == subject && $0.key == item.key) }
        updated.insert(FirewallRule(subject: subject, key: item.key, title: item.title, action: action), at: 0)
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
