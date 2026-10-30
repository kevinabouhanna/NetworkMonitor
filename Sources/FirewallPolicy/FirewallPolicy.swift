import Foundation
import HostsFile

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
    /// The programs behind it, unfolded, to tell an app's updater from the
    /// app (#98).
    public var executablePaths: [String]
    /// The name it connected by, when there is one.
    public var hostname: String?

    public init(appKeys: [String], companyKey: String?, country: String?, address: String, port: Int,
                isApple: Bool, executablePaths: [String] = [], hostname: String? = nil) {
        self.appKeys = appKeys
        self.companyKey = companyKey
        self.country = country
        self.address = address
        self.port = port
        self.isApple = isApple
        self.executablePaths = executablePaths
        self.hostname = hostname
    }
}

public enum Verdict: Equatable {
    case allow(AllowReason)
    case block(BlockReason)

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

    /// How a report names it: the rule's id, or what blocked it.
    public var id: String {
        switch self {
        case .rule(let rule):   return rule.id
        case .mode:             return "mode"
        case .updatesOnHotspot: return "hotspot-updates"
        }
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
    /// Hotspot mode is on and this is a hotspot: updates wait (#98).
    public var pausesUpdates: Bool

    public init(mode: FirewallMode = .anywhere, rules: [FirewallRule] = [], onHotspot: Bool = false,
                pausesUpdates: Bool = false) {
        self.mode = mode
        self.rules = rules
        self.onHotspot = onHotspot
        self.pausesUpdates = pausesUpdates
    }

    /// Anything to decide at all. Without it, the filter looks nothing up.
    public var isActive: Bool {
        mode != .anywhere || !rules.isEmpty || pausesUpdates
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
                case .block:           return .block(.rule(rule))
                case .blockOnHotspots: if onHotspot { return .block(.rule(rule)) }
                }
            }
        }
        // After your rules, which always win: Always Allow lets an updater
        // through. macOS and Apple's apps follow Hotspot mode's system setting
        // instead, so an update started by hand still goes.
        if pausesUpdates, !flow.isApple,
           flow.executablePaths.contains(where: Self.isUpdater) || flow.hostname.map(Self.isUpdateHost) == true {
            return .block(.updatesOnHotspot)
        }
        switch mode {
        case .anywhere:    return .allow(.mode)
        case .onlyAllowed: return flow.isApple ? .allow(.apple) : .block(.mode)
        }
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
