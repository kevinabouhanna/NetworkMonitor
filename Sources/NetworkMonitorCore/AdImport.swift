import FirewallPolicy
import Foundation

/// Rules brought over from another ad blocker (#253): a uBlock Origin backup,
/// AdGuard's settings, or rules pasted or saved as text in Adblock syntax.
/// Read first and shown as a summary; nothing changes until it's accepted.
///
/// What a filter in the network can use is a whole site, blocked or let
/// through, for every app or one. Rules that hide parts of a page wait for
/// the browser extension (#257), and rules about one address on a site wait
/// for Enhanced ad blocking (#256): they're counted, not dropped silently.
public struct AdImport: Identifiable, Equatable {

    /// A line that can't be used, and why, in plain words.
    public struct Skipped: Equatable {
        public let line: String
        public let why: String

        public init(line: String, why: String) {
            self.line = line
            self.why = why
        }
    }

    /// An app named by a rule's `$app=` (a bundle ID, a name or a path), as
    /// rules key apps, when it's on this Mac.
    public typealias AppFinder = (String) -> (key: String, name: String)?

    public let id = UUID()
    /// What it was read from: "uBlock Origin backup", "AdGuard settings",
    /// "rules".
    public var source: String
    /// New rules, in the order they were read.
    public var rules: [AdRule] = []
    /// Rules that were here already.
    public var alreadyHere = 0
    /// Lists to switch on, from the lists it had on.
    public var lists: Set<BlocklistTopic> = []
    /// Lists it had on that NetworkMonitor doesn't offer (yet).
    public var listsNotHere: [String] = []
    /// Rules that hide or change parts of a page: for the browser extension.
    public var forExtension: [String] = []
    /// Rules about one address on a site, not the whole site: for Enhanced
    /// ad blocking.
    public var forEnhanced: [String] = []
    public var skipped: [Skipped] = []
    /// Trusted sites and the allowlist mean "don't block on this site's
    /// pages" there; here, connections to the site itself go through.
    public var hasTrustedSites = false

    public init(source: String) {
        self.source = source
    }

    public static func == (lhs: AdImport, rhs: AdImport) -> Bool {
        lhs.source == rhs.source && lhs.rules == rhs.rules && lhs.alreadyHere == rhs.alreadyHere
            && lhs.lists == rhs.lists && lhs.listsNotHere == rhs.listsNotHere
            && lhs.forExtension == rhs.forExtension && lhs.forEnhanced == rhs.forEnhanced
            && lhs.skipped == rhs.skipped && lhs.hasTrustedSites == rhs.hasTrustedSites
    }

    public var isEmpty: Bool { rules.isEmpty && lists.isEmpty }

    // MARK: Reading

    public enum ReadError: Error, Equatable {
        /// Not a backup, settings or rules NetworkMonitor knows.
        case notRules
    }

    /// Reads a file or pasted text. `existing` are the rules already here, so
    /// what's new can be told apart.
    public static func read(_ data: Data, existing: [AdRule], findApp: AppFinder) throws -> AdImport {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if json["userFilters"] != nil || json["selectedFilterLists"] != nil || json["whitelist"] != nil
                || json["trustedSiteDirectives"] != nil {
                return uBlockOrigin(json, existing: existing, findApp: findApp)
            }
            if json["filters"] != nil || json["protocol-version"] != nil {
                return adGuard(json, existing: existing, findApp: findApp)
            }
            throw ReadError.notRules
        }
        guard let text = String(data: data, encoding: .utf8) else { throw ReadError.notRules }
        var result = AdImport(source: "a list of rules")
        result.add(lines: text, existing: existing, findApp: findApp)
        // A file with nothing that reads as a rule at all isn't rules.
        if result.rules.isEmpty && result.alreadyHere == 0 && result.forExtension.isEmpty
            && result.forEnhanced.isEmpty && result.skipped.isEmpty {
            throw ReadError.notRules
        }
        return result
    }

    /// uBlock Origin's Settings › Back up to file.
    static func uBlockOrigin(_ json: [String: Any], existing: [AdRule], findApp: AppFinder) -> AdImport {
        var result = AdImport(source: "uBlock Origin backup")
        let trusted = (json["whitelist"] as? [String]) ?? (json["trustedSiteDirectives"] as? [String])
            ?? (json["netWhitelist"] as? String)?.components(separatedBy: "\n") ?? []
        result.addTrusted(trusted, existing: existing)
        if let lists = json["selectedFilterLists"] as? [String] {
            // `user-filters` is My filters, read below.
            for list in lists where !list.hasPrefix("user-") { result.addList(named: list, topic: uBlockTopic(list)) }
        }
        if let filters = json["userFilters"] as? String {
            result.add(lines: filters, existing: existing, findApp: findApp)
        }
        return result
    }

    /// AdGuard's Settings › Export settings, from its browser extension.
    static func adGuard(_ json: [String: Any], existing: [AdRule], findApp: AppFinder) -> AdImport {
        var result = AdImport(source: "AdGuard settings")
        let filters = json["filters"] as? [String: Any] ?? [:]
        if let allow = (filters["whitelist"] ?? filters["allowlist"]) as? [String: Any],
           allow["enabled"] as? Bool ?? true, !(allow["inverted"] as? Bool ?? false) {
            result.addTrusted(allow["domains"] as? [String] ?? [], existing: existing)
        }
        for id in filters["enabled-filters"] as? [Int] ?? [] {
            result.addList(named: adGuardNames[id] ?? "AdGuard filter \(id)", topic: adGuardTopics[id])
        }
        for custom in filters["custom-filters"] as? [[String: Any]] ?? [] where custom["enabled"] as? Bool ?? true {
            result.addList(named: custom["title"] as? String ?? custom["customUrl"] as? String ?? "A custom list",
                           topic: nil)
        }
        if let user = filters["user-filter"] as? [String: Any], user["enabled"] as? Bool ?? true {
            let disabled = Set((user["disabled-rules"] as? String ?? "").components(separatedBy: "\n"))
            let rules = (user["rules"] as? String ?? "").components(separatedBy: "\n").filter { !disabled.contains($0) }
            result.add(lines: rules.joined(separator: "\n"), existing: existing, findApp: findApp)
        }
        return result
    }

    // MARK: Lines

    /// Each line of Adblock syntax, hosts files or plain names.
    mutating func add(lines text: String, existing: [AdRule], findApp: AppFinder) {
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            switch Self.classify(line, findApp: findApp) {
            case .nothing:            continue
            case .rule(let rule):     add(rule, existing: existing)
            case .extensionOnly:      forExtension.append(line)
            case .enhancedOnly:       forEnhanced.append(line)
            case .skipped(let why):   skipped.append(Skipped(line: line, why: why))
            }
        }
    }

    enum Line: Equatable {
        case nothing
        case rule(AdRule)
        case extensionOnly
        case enhancedOnly
        case skipped(String)
    }

    /// What one line says, as far as a filter in the network can use it.
    static func classify(_ line: String, findApp: AppFinder) -> Line {
        // Comments, a list's header, and blank lines.
        if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { return .nothing }
        // Hiding or changing parts of a page: ##, #@#, #$#, #%#, #?#, #@?#,
        // ##+js(…), and $$ for a page's HTML.
        if line.range(of: #"#@?[$%?]?\??#|\$\$"#, options: .regularExpression) != nil {
            return .extensionOnly
        }
        // A hosts file's comment.
        if line.hasPrefix("#") { return .nothing }
        // A hosts file's line.
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if words.count >= 2, ["0.0.0.0", "127.0.0.1", "::", "::1", "::0"].contains(String(words[0])) {
            guard let site = AdRule.site(from: String(words[1])), site != "localhost" else { return .nothing }
            return .rule(AdRule(kind: .alwaysBlock, site: site))
        }
        var body = line
        let allow = body.hasPrefix("@@")
        if allow { body.removeFirst(2) }
        // A path or a pattern (`/ads/banner.js`, `/^https?:\/\/ad/`): part of
        // some site, never a whole one.
        if body.hasPrefix("/") { return .enhancedOnly }
        var options: [String] = []
        if let dollar = body.lastIndex(of: "$") {
            options = body[body.index(after: dollar)...].split(separator: ",").map(String.init)
            body = String(body[..<dollar])
        }
        // What the rule's options say: one app, or something narrower than a
        // whole site, which can't be told apart in the network.
        var app: (key: String, name: String)?
        for option in options {
            let (name, value) = option.split(separator: "=", maxSplits: 1).map(String.init).pair
            switch name.trimmingCharacters(in: CharacterSet(charactersIn: "~")).lowercased() {
            case "app":
                let names = value.split(separator: "|").map(String.init)
                guard names.count == 1, !option.hasPrefix("~") else {
                    return .skipped("it names several apps, or every app but some")
                }
                guard let found = findApp(names[0]) else { return .skipped("\(names[0]) isn't on this Mac") }
                app = found
            case "important", "all", "document", "doc", "popup", "match-case":
                continue
            case "elemhide", "ehide", "generichide", "ghide", "specifichide", "shide", "jsinject", "content",
                 "extension", "stealth", "cookie", "removeparam", "csp", "redirect", "redirect-rule", "replace",
                 "permissions", "header", "removeheader", "jsonprune", "hls", "urltransform":
                return .extensionOnly
            default:
                // $third-party, $script, $domain=… and the like: only some of
                // a site's connections, which a filter in the network can't
                // pick out by name.
                return .enhancedOnly
            }
        }
        // `||site^`, `|https://site/`, `*.site`, a bare name, or app-wide: `*`.
        var name = body
        if name.hasPrefix("||") { name.removeFirst(2) }
        else if name.hasPrefix("|") { name.removeFirst() }
        if name.hasSuffix("^") || name.hasSuffix("^|") { name = String(name.prefix { $0 != "^" }) }
        if name.isEmpty || name == "*" {
            if allow, let app { return .rule(AdRule(kind: .neverBlock, site: nil, appKey: app.key, appTitle: app.name)) }
            return .skipped("it's about every site")
        }
        // A path or a part of an address is narrower than the site.
        let hostPart: String
        if let scheme = name.range(of: "://") { hostPart = String(name[scheme.upperBound...]) } else { hostPart = name }
        if let slash = hostPart.firstIndex(of: "/"), hostPart.index(after: slash) != hostPart.endIndex {
            return .enhancedOnly
        }
        let host = hostPart.prefix { $0 != "/" }
        if host.contains("*") && !host.hasPrefix("*.") { return .enhancedOnly }
        guard let site = AdRule.site(from: String(host)) else {
            return .skipped("it doesn't name a site")
        }
        return .rule(AdRule(kind: allow ? .neverBlock : .alwaysBlock, site: site, appKey: app?.key, appTitle: app?.name))
    }

    private mutating func add(_ rule: AdRule, existing: [AdRule]) {
        if existing.contains(rule) || rules.contains(rule) {
            alreadyHere += 1
        } else if let index = rules.firstIndex(where: { $0.site == rule.site && $0.appKey == rule.appKey }) {
            // Later lines win, as they would in the blocker they came from.
            rules[index] = rule
        } else {
            rules.append(rule)
        }
    }

    /// Trusted sites: every app, never blocked.
    private mutating func addTrusted(_ entries: [String], existing: [AdRule]) {
        for entry in entries.map({ $0.trimmingCharacters(in: .whitespaces) }) where !entry.isEmpty {
            // uBlock Origin's own: browser pages, not sites.
            if entry.hasSuffix("-scheme") || entry.hasPrefix("#") { continue }
            guard !entry.hasPrefix("/"), let site = AdRule.site(from: entry) else {
                skipped.append(Skipped(line: entry, why: "it isn't one site"))
                continue
            }
            hasTrustedSites = true
            add(AdRule(kind: .neverBlock, site: site), existing: existing)
        }
    }

    private mutating func addList(named name: String, topic: BlocklistTopic?) {
        if let topic { lists.insert(topic) } else if !name.isEmpty { listsNotHere.append(name) }
    }

    // MARK: Lists, by what they're for

    /// uBlock Origin's lists by id: ads, trackers and annoyances to the ads
    /// list, malware and phishing to the malware list.
    static func uBlockTopic(_ id: String) -> BlocklistTopic? {
        let id = id.lowercased()
        if id.contains("badware") || id.contains("urlhaus") || id.contains("phishing") || id.contains("malware") {
            return .malware
        }
        if id.hasPrefix("http") { return nil }
        let ads = ["ublock-filters", "ublock-privacy", "ublock-unbreak", "ublock-quick-fixes", "easylist",
                   "easyprivacy", "adguard-generic", "adguard-mobile", "adguard-spyware", "adguard-spyware-url",
                   "plowe-0", "block-lan", "adguard-social", "fanboy-social", "fanboy-cookiemonster",
                   "ublock-cookies-easylist", "ublock-annoyances", "adguard-annoyance", "easylist-annoyances",
                   "easylist-chat", "easylist-newsletters", "easylist-notifications", "dpollock-0", "mvps-0"]
        return ads.contains(id) ? .ads : nil
    }

    /// AdGuard's lists by id, as its extension numbers them.
    static let adGuardNames: [Int: String] = [
        1: "AdGuard Russian filter", 2: "AdGuard Base filter", 3: "AdGuard Tracking Protection filter",
        4: "AdGuard Social Media filter", 5: "AdGuard Experimental filter", 6: "AdGuard German filter",
        7: "AdGuard Japanese filter", 8: "AdGuard Dutch filter", 9: "AdGuard Spanish/Portuguese filter",
        10: "AdGuard Useful Ads filter", 11: "AdGuard Mobile Ads filter", 13: "AdGuard Turkish filter",
        14: "AdGuard Annoyances filter", 16: "AdGuard French filter", 17: "AdGuard URL Tracking filter",
        18: "AdGuard Cookie Notices filter", 19: "AdGuard Popups filter", 20: "AdGuard Mobile App Banners filter",
        21: "AdGuard Other Annoyances filter", 22: "AdGuard Widgets filter", 101: "EasyList",
        118: "EasyPrivacy", 207: "AdGuard Quick Fixes filter", 224: "AdGuard Chinese filter",
    ]

    static let adGuardTopics: [Int: BlocklistTopic] = [
        2: .ads, 3: .ads, 4: .ads, 11: .ads, 14: .ads, 17: .ads, 18: .ads, 19: .ads, 20: .ads, 21: .ads,
        22: .ads, 101: .ads, 118: .ads, 207: .ads,
    ]

    // MARK: Export

    /// Your rules as Adblock syntax, which uBlock Origin's My filters and
    /// AdGuard's User rules take, and this reads back. An app is named by its
    /// bundle ID where it has one.
    public static func export(_ rules: [AdRule], bundleID: (String) -> String?) -> String {
        var lines = ["! NetworkMonitor ad-blocking rules", "! \(rules.count) rule\(rules.count == 1 ? "" : "s")"]
        for rule in rules {
            let app = rule.appKey.map { "$app=" + (bundleID($0) ?? $0) }
            if rule.skipsApp, let app {
                lines.append("! Don't filter \(rule.appTitle ?? "this app")")
                lines.append("@@*" + app)
                continue
            }
            guard let site = rule.site else { continue }
            lines.append((rule.kind == .neverBlock ? "@@" : "") + "||\(site)^" + (app ?? ""))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Summary

    /// What's about to happen, in plain words, one line each.
    public var summary: [String] {
        var lines: [String] = []
        let never = rules.filter { $0.kind == .neverBlock && !$0.skipsApp }.count
        let always = rules.filter { $0.kind == .alwaysBlock }.count
        let apps = rules.filter(\.skipsApp).count
        if never > 0 { lines.append("\(Self.count(never, "site")) never blocked") }
        if always > 0 { lines.append("\(Self.count(always, "site")) always blocked") }
        if apps > 0 { lines.append("\(Self.count(apps, "app")) not filtered") }
        if !lists.isEmpty {
            lines.append("Switch on " + lists.sorted { $0.rawValue < $1.rawValue }.map(\.title).joined(separator: " and "))
        }
        if alreadyHere > 0 { lines.append("\(Self.count(alreadyHere, "rule")) already here") }
        return lines
    }

    /// What can't come over yet, and why.
    public var leftOut: [String] {
        var lines: [String] = []
        if !forExtension.isEmpty {
            let one = forExtension.count == 1
            lines.append("\(Self.count(forExtension.count, "rule")) that \(one ? "hides" : "hide") parts of a page "
                         + "\(one ? "waits" : "wait") for the browser extension")
        }
        if !forEnhanced.isEmpty {
            let one = forEnhanced.count == 1
            lines.append("\(Self.count(forEnhanced.count, "rule")) about part of a site \(one ? "waits" : "wait") "
                         + "for Enhanced ad blocking")
        }
        if !listsNotHere.isEmpty {
            lines.append("Not offered here yet: " + (AdsReport.listed(listsNotHere, shown: 3) ?? ""))
        }
        if !skipped.isEmpty {
            let examples = skipped.prefix(3).map { "\($0.line) (\($0.why))" }
            lines.append("\(Self.count(skipped.count, "line")) can't be used: " + examples.joined(separator: "; ")
                         + (skipped.count > 3 ? "…" : ""))
        }
        return lines
    }

    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}

private extension Array where Element == String {
    /// An option's name and value: `app=x` is ("app", "x"), `important` is
    /// ("important", "").
    var pair: (String, String) { (first ?? "", count > 1 ? self[1] : "") }
}
