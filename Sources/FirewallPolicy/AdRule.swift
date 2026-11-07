import Foundation

/// A person's own say over ad blocking (#253): a site the lists must never
/// block, one to block although no list has it, or an app whose connections
/// the lists leave alone. Unlike a firewall rule it changes only what the
/// lists do: *never block* lets a listed site through, and nothing more.
/// The malware lists apply whatever these say (#317).
public struct AdRule: Codable, Hashable, Identifiable {

    public enum Kind: String, Codable, CaseIterable {
        /// uBlock Origin's trusted sites, AdGuard's `@@||site^`.
        case neverBlock
        /// `||site^`, though no list has it.
        case alwaysBlock
    }

    public let kind: Kind
    /// The site, covering it and every name under it, as `||site^` does. Nil
    /// for an app's rule about all of its connections: *never block* with no
    /// site is "don't filter this app".
    public let site: String?
    /// For one app only, by its key; nil for every app.
    public let appKey: String?
    public let appTitle: String?
    /// For one app's rule, the team that signed the app when the rule was
    /// made (#320), as firewall rules keep it (#202): a program at that path
    /// signed by anyone else isn't the app, and the rule doesn't hold for it.
    /// Nil for every app's rules, apps with no team, and rules made before.
    public let team: String?

    public init(kind: Kind, site: String?, appKey: String? = nil, appTitle: String? = nil, team: String? = nil) {
        self.kind = kind
        self.site = site
        self.appKey = appKey
        self.appTitle = appKey == nil ? nil : appTitle
        self.team = appKey == nil ? nil : team
    }

    /// The same rule, signed for by `team`.
    public func signed(by team: String?) -> AdRule {
        AdRule(kind: kind, site: site, appKey: appKey, appTitle: appTitle, team: team)
    }

    /// Whether it holds for a program whose app keys were signed by `teams`.
    /// Without them, as the app reads its log, every rule holds.
    func holds(signedBy teams: [String: String]?) -> Bool {
        guard let team, let appKey, let teams else { return true }
        return teams[appKey] == team
    }

    public var id: String { "\(kind.rawValue):\(site ?? "*")" + (appKey.map { "@\($0)" } ?? "") }

    /// The app isn't filtered at all.
    public var skipsApp: Bool { site == nil && appKey != nil && kind == .neverBlock }

    /// Whether it can be kept: a site, or an app that isn't filtered.
    public var isValid: Bool {
        if let site { return SiteName.normalized(site) == site }
        return skipsApp
    }

    /// What the rule says, as the Rules tab and the log put it.
    public var summary: String {
        let app = appTitle ?? appKey.map { ($0 as NSString).lastPathComponent }
        if skipsApp { return "Don't filter \(app ?? "this app")" }
        let verb = kind == .neverBlock ? "Never block" : "Always block"
        return "\(verb) \(site ?? "")" + (app.map { " in \($0)" } ?? "")
    }

    /// The rule deciding a connection to `name` from apps `appKeys`, if any.
    /// One app's rules come before every app's, then *never block* before
    /// *always block*, as AdGuard puts exceptions first, and within each the
    /// longer name. So never blocking `example.com` wins over always blocking
    /// `tracker.example.com`. With `teams`, one app's rule holds only for the
    /// app its team signed (#320).
    public static func deciding(_ rules: [AdRule], name: String?, appKeys: [String],
                                teams: [String: String]? = nil) -> AdRule? {
        guard !rules.isEmpty else { return nil }
        let domains = name.map(SiteName.domains(of:)) ?? []
        let index = Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for scope in [appKeys.map { "@" + $0 }, [""]] {
            for kind in Kind.allCases {
                for scopeKey in scope {
                    for domain in domains {
                        if let rule = index["\(kind.rawValue):\(domain)\(scopeKey)"], rule.holds(signedBy: teams) {
                            return rule
                        }
                    }
                    if kind == .neverBlock, !scopeKey.isEmpty, let rule = index["\(kind.rawValue):*\(scopeKey)"],
                       rule.holds(signedBy: teams) {
                        return rule
                    }
                }
            }
        }
        return nil
    }

    /// What someone typed or pasted as a site: `https://ads.example.com/x`,
    /// `*.example.com`, `||example.com^` all read as the name. Nil when
    /// there's no name in it.
    public static func site(from text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        if text.hasPrefix("||") { text.removeFirst(2) }
        if text.hasPrefix("*.") { text.removeFirst(2) }
        if let end = text.firstIndex(where: { "/^:?#$".contains($0) }) { text = String(text[..<end]) }
        return SiteName.normalized(text)
    }
}
