import Foundation

// What may connect (#114): the rules a person made in Connections, and what
// happens to everything they didn't make one for. Shared by the app, which
// keeps the rules and shows them, and the content filter, which applies them
// to each new connection. Pure Foundation, like FilterProtocol, so the two
// can't disagree about what a rule means.

/// What a rule is about: the four things Connections groups by.
public enum RuleSubject: String, Codable, CaseIterable {
    case company, app, country, server
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

    public var id: String { "\(subject.rawValue):\(key)" }

    public init(subject: RuleSubject, key: String, title: String, action: RuleAction) {
        self.subject = subject
        self.key = key
        self.title = title
        self.action = action
    }
}

/// What everything without a rule does.
public enum FirewallMode: String, Codable {
    /// Every app connects, except what's blocked. The default.
    case anywhere
    /// Only what's allowed connects, and macOS and Apple's own apps.
    case onlyAllowed
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

    public init(appKeys: [String], companyKey: String?, country: String?, address: String, port: Int,
                isApple: Bool) {
        self.appKeys = appKeys
        self.companyKey = companyKey
        self.country = country
        self.address = address
        self.port = port
        self.isApple = isApple
    }
}

public enum Verdict: Equatable {
    case allow(AllowReason)
    case block(FirewallRule?)

    public var allows: Bool {
        if case .allow = self { return true }
        return false
    }
}

public enum AllowReason: Equatable {
    /// The local network, names, the clock, an address: never blocked.
    case essential
    case rule(FirewallRule)
    case apple
    case mode
}

/// The rules, the mode, and whether the Mac is on a hotspot: everything the
/// filter needs to decide, in one value the app sends it.
public struct FirewallPolicy: Codable, Equatable {
    public var mode: FirewallMode
    public var rules: [FirewallRule]
    public var onHotspot: Bool

    public init(mode: FirewallMode = .anywhere, rules: [FirewallRule] = [], onHotspot: Bool = false) {
        self.mode = mode
        self.rules = rules
        self.onHotspot = onHotspot
    }

    /// Most specific first: one server is narrower than an app, an app than a
    /// company, a company than a country. So *Block Meta* with *Always allow
    /// WhatsApp* lets WhatsApp through, and *Block United States* with
    /// *Always allow Apple* lets Apple's servers there through.
    public static let precedence: [RuleSubject] = [.server, .app, .company, .country]

    public func decide(_ flow: FlowFacts) -> Verdict {
        if Self.isEssential(address: flow.address, port: flow.port) { return .allow(.essential) }
        let index = Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for subject in Self.precedence {
            for key in Self.keys(of: flow, subject) {
                guard let rule = index["\(subject.rawValue):\(key)"] else { continue }
                switch rule.action {
                case .allow:           return .allow(.rule(rule))
                case .block:           return .block(rule)
                case .blockOnHotspots: if onHotspot { return .block(rule) }
                }
            }
        }
        switch mode {
        case .anywhere:    return .allow(.mode)
        case .onlyAllowed: return flow.isApple ? .allow(.apple) : .block(nil)
        }
    }

    private static func keys(of flow: FlowFacts, _ subject: RuleSubject) -> [String] {
        switch subject {
        case .server:  return [flow.address]
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
