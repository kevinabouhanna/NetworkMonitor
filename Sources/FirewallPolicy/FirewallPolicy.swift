import Foundation
import HostsFile

// What may connect (#114): the rules a person made in Connections, and what
// happens to everything they didn't make one for. Shared by the app, which
// keeps the rules and shows them, and the content filter, which applies them
// to each new connection. Pure Foundation, like FilterProtocol, so the two
// can't disagree about what a rule means.

/// What a rule is about: the four things Connections groups by, and a site
/// by name (#197), which covers the name and every name under it.
public enum RuleSubject: String, Codable, CaseIterable {
    case company, app, country, server, site
}

public enum RuleAction: String, Codable, CaseIterable {
    case block
    /// Blocked only while the Mac is on a hotspot.
    case blockOnHotspots
    case allow
}

/// One thing a person decided: Meta blocked, Slack always allowed.
public struct FirewallRule: Codable, Hashable, Identifiable {
    public let subject: RuleSubject
    /// The same key Connections groups by: `Company.key`, an app's key, a
    /// country code, or an address.
    public let key: String
    /// What it was called when the rule was made, for the list of rules.
    public let title: String
    public var action: RuleAction
    /// For one app only, by its key: an answer to Ask Me, such as "Amazon,
    /// for Slack" (#129). Nil for every app.
    public let appKey: String?
    public let appTitle: String?
    /// Only until that app quits (#199): an Ask Me answer for this session.
    /// The app takes it back when the app quits; to the filter it's a rule
    /// like any other. Nil, not false, so rules made before it read the same.
    public let untilQuit: Bool?
    /// Only on one network (#200), by the router's identity as Usage History
    /// keys networks, never its Wi-Fi name; and what it was called.
    public let network: String?
    public let networkTitle: String?
    /// For a rule about an app, the team that signed it when the rule was
    /// made (#202). A program at that path signed by anyone else isn't the
    /// app the rule was made for, so the rule doesn't apply to it. Nil for
    /// apps with no team: Apple's own, ad-hoc and self-signed ones.
    public let team: String?

    public var id: String { "\(subject.rawValue):\(key)" + (appKey.map { "@\($0)" } ?? "") }

    public var lastsUntilQuit: Bool { untilQuit == true }

    public init(subject: RuleSubject, key: String, title: String, action: RuleAction,
                appKey: String? = nil, appTitle: String? = nil, untilQuit: Bool = false,
                network: String? = nil, networkTitle: String? = nil, team: String? = nil) {
        self.subject = subject
        self.key = key
        self.title = title
        self.action = action
        self.appKey = appKey
        self.appTitle = appTitle
        self.untilQuit = untilQuit ? true : nil
        self.network = network
        self.networkTitle = network == nil ? nil : networkTitle
        self.team = team
    }

    /// The app this rule is about, if it's about one: its subject, or the
    /// one app it's for.
    public var ruledApp: String? { appKey ?? (subject == .app ? key : nil) }

    /// The same rule, signed for by `team`.
    public func signed(by team: String?) -> FirewallRule {
        FirewallRule(subject: subject, key: key, title: title, action: action, appKey: appKey, appTitle: appTitle,
                     untilQuit: lastsUntilQuit, network: network, networkTitle: networkTitle, team: team)
    }
}

/// What everything without a rule does.
public enum FirewallMode: String, Codable {
    /// Every app connects, except what's blocked. The default.
    case anywhere
    /// Only what's allowed connects, and macOS and Apple's own apps.
    case onlyAllowed
    /// The first time an app reaches a company, it waits while NetworkMonitor
    /// asks (#129).
    case ask
}

/// What the filter knows about one new connection.
public struct FlowFacts: Equatable {
    /// The app the connection is made for, and the process making it, by the
    /// keys Connections uses. Often the same; Safari's pages load through a
    /// WebKit process, so a rule on either catches them.
    public var appKeys: [String]
    public var companyKey: String?
    public var country: String?
    public var address: String
    public var port: Int
    /// Signed by Apple: macOS itself or one of Apple's apps.
    public var isApple: Bool
    /// The programs behind it, unfolded, to tell an app's updater from the
    /// app (#98).
    public var executablePaths: [String]
    /// The name it connected by, when there is one.
    public var hostname: String?
    /// NetworkMonitor itself, fetching its monthly data (#121).
    public var isNetworkMonitor: Bool
    /// The lists holding its name (#176), as the filter looked them up.
    public var listedIn: Set<BlocklistTopic>
    /// The downloaded lists holding it (#254), by id.
    public var listedInDownloaded: [String]
    /// The team that signed each of its app keys' programs (#202). An app
    /// key with no entry has no team, or one that couldn't be read.
    public var teams: [String: String]

    public init(appKeys: [String], companyKey: String?, country: String?, address: String, port: Int,
                isApple: Bool, executablePaths: [String] = [], hostname: String? = nil,
                isNetworkMonitor: Bool = false, listedIn: Set<BlocklistTopic> = [], listedInDownloaded: [String] = [],
                teams: [String: String] = [:]) {
        self.appKeys = appKeys
        self.companyKey = companyKey
        self.country = country
        self.address = address
        self.port = port
        self.isApple = isApple
        self.executablePaths = executablePaths
        self.hostname = hostname
        self.isNetworkMonitor = isNetworkMonitor
        self.listedIn = listedIn
        self.listedInDownloaded = listedInDownloaded
        self.teams = teams
    }
}

public enum Verdict: Equatable {
    case allow(AllowReason)
    case block(BlockReason)
    /// Ask Me, and nothing decided it: hold it and ask (#129).
    case ask

    public var allows: Bool {
        if case .allow = self { return true }
        return false
    }
}

public enum BlockReason: Equatable {
    case rule(FirewallRule)
    /// Only Where I Allow, and nothing allowed it.
    case mode
    /// An updater, or an update server, on a hotspot with Hotspot mode on (#98).
    case updatesOnHotspot
    /// On a list that's switched on (#176).
    case list(BlocklistTopic)
    /// On a list downloaded on this Mac that's switched on (#254), by its id.
    case downloadedList(String)
    /// Block Everything is on (#198).
    case everything
    /// The person's own *always block* (#253), counted with the lists.
    case adRule(AdRule)

    /// How a report names it: the rule's id, or what blocked it.
    public var id: String {
        switch self {
        case .rule(let rule):   return rule.id
        case .mode:             return "mode"
        case .updatesOnHotspot: return "hotspot-updates"
        case .list(let topic):  return Self.listPrefix + topic.rawValue
        case .downloadedList(let id): return Self.listPrefix + id
        case .everything:       return "everything"
        case .adRule(let rule): return Self.listPrefix + Self.ownList + ":" + rule.id
        }
    }

    /// Every list's report starts so, for counting them.
    public static let listPrefix = "list:"
    /// The person's own rules, as the Ads window counts them beside the lists.
    public static let ownList = "mine"

    /// The list a report says blocked it (`ads`, or `mine` for the person's
    /// own rule), or nil when no list did.
    public static func list(inReport blockedBy: String?) -> String? {
        guard let blockedBy, blockedBy.hasPrefix(listPrefix) else { return nil }
        let rest = blockedBy.dropFirst(listPrefix.count)
        return String(rest.split(separator: ":", maxSplits: 1).first ?? rest)
    }

    /// The id of the person's rule a report names, if it was one.
    public static func adRuleID(inReport blockedBy: String?) -> String? {
        let prefix = listPrefix + ownList + ":"
        guard let blockedBy, blockedBy.hasPrefix(prefix) else { return nil }
        return String(blockedBy.dropFirst(prefix.count))
    }
}

public enum AllowReason: Equatable {
    /// The local network, names, the clock, an address: never blocked.
    case essential
    case rule(FirewallRule)
    case apple
    /// Its own monthly data, which the modes don't hold back: a rule still can.
    case networkMonitor
    case mode
}

/// The rules, the mode, and whether the Mac is on a hotspot: everything the
/// filter needs to decide, in one value the app sends it.
public struct FirewallPolicy: Codable, Equatable {
    public var mode: FirewallMode
    public var rules: [FirewallRule]
    public var onHotspot: Bool
    /// Hotspot mode is on and this is a hotspot: updates wait (#98).
    public var pausesUpdates: Bool
    /// The lists switched on (#176). None until someone turns them on.
    public var lists: Set<BlocklistTopic>
    /// Block Everything (#198): every new connection is blocked but the
    /// essentials and NetworkMonitor itself, whatever the rules say.
    public var blocksEverything: Bool
    /// The network the Mac is on (#200), as rules for one network name it.
    public var network: String?
    /// The person's own ad-blocking rules (#253). They change only what the
    /// lists do, so they count only while a list is on.
    public var adRules: [AdRule]
    /// The downloaded lists switched on (#254), by id, in the order they're
    /// named when one blocks. They apply only while a shipped list is on.
    public var downloadedLists: [String]
    /// Those of them about malware and phishing (#317), which apply whatever
    /// your ad-blocking rules say, as the shipped malware list does.
    public var threatLists: Set<String>
    /// The resolver the DNS proxy sends lookups to, encrypted (#291), by
    /// `EncryptedDNS.Resolver` id. Kept here so it's there when the proxy starts.
    public var lookupResolver: String?

    public init(mode: FirewallMode = .anywhere, rules: [FirewallRule] = [], onHotspot: Bool = false,
                pausesUpdates: Bool = false, lists: Set<BlocklistTopic> = [], blocksEverything: Bool = false,
                network: String? = nil, adRules: [AdRule] = [], downloadedLists: [String] = [],
                threatLists: Set<String> = [], lookupResolver: String? = nil) {
        self.mode = mode
        self.rules = rules
        self.onHotspot = onHotspot
        self.pausesUpdates = pausesUpdates
        self.lists = lists
        self.blocksEverything = blocksEverything
        self.network = network
        self.adRules = adRules
        self.downloadedLists = downloadedLists
        self.threatLists = threatLists
        self.lookupResolver = lookupResolver
    }

    private enum CodingKeys: String, CodingKey {
        case mode, rules, onHotspot, pausesUpdates, lists, blocksEverything, network, adRules, downloadedLists
        case threatLists, lookupResolver
    }

    /// A policy saved before a field existed reads it as off, so a filter
    /// updated before its app keeps applying what it was sent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(FirewallMode.self, forKey: .mode)
        rules = try container.decode([FirewallRule].self, forKey: .rules)
        onHotspot = try container.decodeIfPresent(Bool.self, forKey: .onHotspot) ?? false
        pausesUpdates = try container.decodeIfPresent(Bool.self, forKey: .pausesUpdates) ?? false
        lists = try container.decodeIfPresent(Set<BlocklistTopic>.self, forKey: .lists) ?? []
        blocksEverything = try container.decodeIfPresent(Bool.self, forKey: .blocksEverything) ?? false
        network = try container.decodeIfPresent(String.self, forKey: .network)
        adRules = try container.decodeIfPresent([AdRule].self, forKey: .adRules) ?? []
        downloadedLists = try container.decodeIfPresent([String].self, forKey: .downloadedLists) ?? []
        threatLists = try container.decodeIfPresent(Set<String>.self, forKey: .threatLists) ?? []
        lookupResolver = try container.decodeIfPresent(String.self, forKey: .lookupResolver)
    }

    /// Anything to decide at all. Without it, the filter looks nothing up.
    public var isActive: Bool {
        mode != .anywhere || !rules.isEmpty || pausesUpdates || !lists.isEmpty || blocksEverything
    }

    /// Most specific first: one server is narrower than a site, a site than an
    /// app, an app than a company, a company than a country. So *Block Meta*
    /// with *Always allow WhatsApp* lets WhatsApp through, *Block United
    /// States* with *Always allow Apple* lets Apple's servers there through,
    /// and *Block Google* with *Always allow \*.youtube.com* lets YouTube
    /// through (#197). Within sites, the longer name wins.
    public static let precedence: [RuleSubject] = [.server, .site, .app, .company, .country]

    public func decide(_ flow: FlowFacts) -> Verdict {
        if Self.isEssential(address: flow.address, port: flow.port) { return .allow(.essential) }
        // Block Everything is a way out, so it comes before every rule: only
        // what's needed to switch it off again goes through (#198).
        if blocksEverything { return flow.isNetworkMonitor ? .allow(.networkMonitor) : .block(.everything) }
        let index = Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        // The rule that lets it connect, when it's broader than a name: the
        // lists still have their say first (#316).
        var allowed: FirewallRule?
        // A rule for one app is narrower than any rule for every app, so those
        // go first: "Amazon, for Slack" over "Block Amazon".
        ruling: for scopes in [flow.appKeys.map { "@" + $0 }, [""]] {
            for subject in Self.precedence {
                for key in Self.keys(of: flow, subject) {
                    for scope in scopes {
                        guard let rule = index["\(subject.rawValue):\(key)\(scope)"] else { continue }
                        // A rule for one network says nothing anywhere else (#200).
                        if let only = rule.network, only != network { continue }
                        // Nor a rule for an app about a program at its path signed
                        // by someone else (#202).
                        if let team = rule.team, let app = rule.ruledApp, flow.teams[app] != team { continue }
                        switch rule.action {
                        // A site or a server is a name you chose to let through,
                        // listed or not (#176). An app, a company or a country
                        // may connect, but that says nothing about ads (#316).
                        case .allow:
                            if rule.subject == .site || rule.subject == .server { return .allow(.rule(rule)) }
                            allowed = rule
                            break ruling
                        case .block:           return .block(.rule(rule))
                        case .blockOnHotspots: if onHotspot { return .block(.rule(rule)) }
                        }
                    }
                }
            }
        }
        // After your rules, which always win, and your ad-blocking rules (#253),
        // which say only what the lists do, and only while one is on.
        if let listed = listBlock(flow) { return .block(listed) }
        if let allowed { return .allow(.rule(allowed)) }
        // Always Allow lets an updater through too. macOS and Apple's apps
        // follow Hotspot mode's system setting instead, so an update started
        // by hand still goes.
        if pausesUpdates, !flow.isApple,
           flow.executablePaths.contains(where: Self.isUpdater) || flow.hostname.map(Self.isUpdateHost) == true {
            return .block(.updatesOnHotspot)
        }
        // Under Only Where I Allow and Ask Me, NetworkMonitor's own monthly
        // download is no more held back than macOS is.
        if mode != .anywhere, flow.isNetworkMonitor { return .allow(.networkMonitor) }
        switch mode {
        case .anywhere:    return .allow(.mode)
        case .onlyAllowed: return flow.isApple ? .allow(.apple) : .block(.mode)
        // Nothing is asked about macOS or Apple's apps, nor about a program
        // the filter couldn't name.
        case .ask:
            if flow.isApple { return .allow(.apple) }
            return flow.appKeys.isEmpty ? .allow(.mode) : .ask
        }
    }

    /// What blocks it among the lists and your ad-blocking rules, if any.
    private func listBlock(_ flow: FlowFacts) -> BlockReason? {
        guard !lists.isEmpty else { return nil }
        let adRule = AdRule.deciding(adRules, name: flow.hostname, appKeys: flow.appKeys, teams: flow.teams)
        if let adRule, adRule.kind == .alwaysBlock { return .adRule(adRule) }
        let listed = flow.listedIn.intersection(lists)
        let downloaded = downloadedLists.filter(flow.listedInDownloaded.contains)
        // Never block and Don't filter are for ads that break a page or an
        // app: the malware lists still apply (#317).
        if adRule != nil {
            if listed.contains(.malware) { return .list(.malware) }
            return downloaded.first(where: threatLists.contains).map(BlockReason.downloadedList)
        }
        if let topic = listed.sorted().first { return .list(topic) }
        return downloaded.first.map(BlockReason.downloadedList)
    }

    // MARK: Updates on a hotspot

    /// Programs that do nothing but update, by name, wherever they are: no
    /// list of apps to keep up.
    static let updaterNames: Set<String> = ["googleupdater", "microsoft autoupdate", "microsoft update assistant",
                                            "googlesoftwareupdateagent", "ksfetch", "shipit"]

    /// An updater, by the shape of its path (#98): a program inside an app
    /// named like one (`opera_autoupdate`, Raycast's `Updater`, Sparkle's
    /// `Autoupdate` and `Updater.app`, Chrome's `UpdaterPrivilegedHelper`),
    /// Sparkle's downloader, or an updater that is a program of its own
    /// (GoogleUpdater, Microsoft AutoUpdate, Squirrel's ShipIt).
    public static func isUpdater(_ path: String) -> Bool {
        let raw = (path as NSString).pathComponents
        let names = raw.map(name)
        if names.contains(where: updaterNames.contains) { return true }
        if let sparkle = raw.firstIndex(of: "Sparkle.framework"),
           raw[sparkle...].contains(where: { $0.hasPrefix("Downloader") }) {
            return true
        }
        // Inside an app, past the app itself, and not its main program: an
        // app called "Update Notes" isn't an updater.
        guard let app = raw.firstIndex(where: { $0.hasSuffix(".app") }) else { return false }
        return names[(app + 1)...].contains { $0 != names[app] && $0.contains("update") }
    }

    /// A path component as compared: lowercased, without a bundle's extension.
    /// Only a bundle's: `com.google.Chrome.UpdaterPrivilegedHelper` is all name.
    private static func name(_ component: String) -> String {
        let lowered = component.lowercased()
        for suffix in [".app", ".xpc", ".framework", ".bundle"] where lowered.hasSuffix(suffix) {
            return String(lowered.dropLast(suffix.count))
        }
        return lowered
    }

    /// A server that carries nothing but updates: the helper's list.
    public static func isUpdateHost(_ hostname: String) -> Bool {
        let name = hostname.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return HostsFile.updateHosts.contains { name == $0 || name.hasSuffix("." + $0) }
    }

    private static func keys(of flow: FlowFacts, _ subject: RuleSubject) -> [String] {
        switch subject {
        case .server:  return [flow.address]
        case .site:    return flow.hostname.map(SiteName.domains(of:)) ?? []
        case .app:     return flow.appKeys
        case .company: return flow.companyKey.map { [$0] } ?? []
        case .country: return flow.country.map { [$0] } ?? []
        }
    }

    // MARK: Essentials

    /// Names (DNS, and DNS over TLS), the clock (NTP), an address (DHCP), and
    /// Bonjour: without them nothing else works, so no rule or mode blocks them.
    public static let essentialPorts: Set<Int> = [53, 67, 68, 123, 853, 5353]

    public static func isEssential(address: String, port: Int) -> Bool {
        essentialPorts.contains(port) || isLocal(address)
    }

    /// Loopback, the local network, link-local and multicast: never the
    /// internet, so never a company's or a country's.
    public static func isLocal(_ address: String) -> Bool {
        let address = address.split(separator: "%").first.map(String.init) ?? address
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            let b = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            return b[0] == 127 || b[0] == 10 || b[0] == 0
                || (b[0] == 172 && (16...31).contains(b[1]))
                || (b[0] == 192 && b[1] == 168)
                || (b[0] == 169 && b[1] == 254)
                || b[0] >= 224
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 {
            let b = withUnsafeBytes(of: v6) { Array($0) }
            if b[0..<15].allSatisfy({ $0 == 0 }) { return true }               // :: and ::1
            if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }           // fe80::/10
            if (b[0] & 0xfe) == 0xfc { return true }                           // fc00::/7
            if b[0] == 0xff { return true }                                    // ff00::/8
            // An IPv4 address carried in IPv6 (::ffff:a.b.c.d) is judged as itself.
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
                return isLocal("\(b[12]).\(b[13]).\(b[14]).\(b[15])")
            }
            return false
        }
        return false
    }

    /// An address as Connections keys a server: an IPv4 address carried in
    /// IPv6 (`::ffff:1.2.3.4`) as itself, and without an IPv6 zone.
    public static func serverAddress(_ address: String) -> String {
        let address = address.split(separator: "%").first.map(String.init) ?? address
        guard address.lowercased().hasPrefix("::ffff:") else { return address }
        let tail = String(address.dropFirst(7))
        return tail.split(separator: ".").count == 4 ? tail : address
    }

    // MARK: Travelling

    /// The policy travels to the filter as JSON in a `Data`, as reports
    /// travel back.
    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    public static func decode(_ data: Data) -> FirewallPolicy? {
        try? JSONDecoder().decode(FirewallPolicy.self, from: data)
    }
}

/// Which app an executable belongs to, by the key Connections uses: the
/// outermost `.app` in its path, so a dozen Chrome helpers are one Chrome, or
/// the executable's own path for a program outside any app.
public enum AppKey {
    public static func bundlePath(forExecutablePath path: String) -> String? {
        let components = (path as NSString).pathComponents
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return NSString.path(withComponents: Array(components[0...index]))
    }

    public static func key(forExecutablePath path: String) -> String {
        bundlePath(forExecutablePath: path) ?? path
    }

    /// A program outside any app, started from one, is listed under it: its
    /// key is the app's, then a separator, then its own path. A control
    /// character, so it can't occur in either half.
    public static let separator: Character = "\u{1}"

    public static func key(adopting path: String, by parentKey: String) -> String {
        "\(parentKey)\(separator)\(path)"
    }
}
