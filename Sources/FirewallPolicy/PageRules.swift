import Foundation

// Rules for inside pages (#681, a step of Enhanced ad blocking, #256): which
// parts of a page to hide, and which small scripts ("scriptlets") to run in
// it, by site. They come from EasyList and EasyPrivacy, in the syntax most
// ad blockers share, and ship beside the lists of names (`pages.bin`). Pure
// Foundation, so the builder, the app and the filter read them alike.

/// A small script a page is given, by name, with its arguments: what removes
/// an ad slot from a site's own reply, where hiding can't (#256).
public struct Scriptlet: Codable, Hashable {
    public let name: String
    public let arguments: [String]

    public init(name: String, arguments: [String]) {
        self.name = name
        self.arguments = arguments
    }

    /// The scriptlets Enhanced ad blocking runs: its own code, not a copied
    /// library, so only these are kept. uBlock Origin's short names, and
    /// AdGuard's for the same, are read as these.
    public static let known: [String: String] = [
        "json-prune": "json-prune",
        "set-constant": "set-constant", "set": "set-constant",
        "abort-on-property-read": "abort-on-property-read", "aopr": "abort-on-property-read",
        "abort-on-property-write": "abort-on-property-write", "aopw": "abort-on-property-write",
        "abort-current-script": "abort-current-script", "acs": "abort-current-script",
        "abort-current-inline-script": "abort-current-script",
        "remove-class": "remove-class", "rc": "remove-class",
        "remove-attr": "remove-attr", "ra": "remove-attr",
        "no-setTimeout-if": "no-setTimeout-if", "nostif": "no-setTimeout-if",
        "prevent-setTimeout": "no-setTimeout-if",
    ]
}

/// One rule as written in a list, before it's indexed.
public struct PageRule: Equatable {
    public enum Action: Equatable {
        case hide(String)
        /// `#@#`: don't hide this selector there.
        case unhide(String)
        case scriptlet(Scriptlet)
    }

    public let action: Action
    /// Where it applies, and under each; none for everywhere. `example.*`
    /// means `example` under any public suffix.
    public let sites: [String]
    /// `~site`: where it doesn't, and under each.
    public let notOn: [String]

    public init(action: Action, sites: [String], notOn: [String]) {
        self.action = action
        self.sites = sites
        self.notOn = notOn
    }

    /// The rule a list's line holds, or nil for anything else: a comment, a
    /// rule by address, or a kind of page rule left out (procedural hiding,
    /// `#$#`, `#?#`, HTML rules, a scriptlet not in `Scriptlet.known`).
    public static func parse(_ line: String) -> PageRule? {
        let line = line.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("[") else { return nil }
        for (marker, unhide) in [("#@#", true), ("##", false)] {
            guard let range = line.range(of: marker) else { continue }
            let domains = String(line[..<range.lowerBound])
            let body = String(line[range.upperBound...])
            // Another marker before this one: `#?#`, `#$#` and their kind.
            if domains.contains("#") || domains.contains("$") || domains.contains("/") { return nil }
            guard let (sites, notOn) = parseDomains(domains) else { return nil }
            if body.hasPrefix("+js(") {
                guard !unhide, let scriptlet = parseScriptlet(body) else { return nil }
                return PageRule(action: .scriptlet(scriptlet), sites: sites, notOn: notOn)
            }
            guard isPlainSelector(body) else { return nil }
            return PageRule(action: unhide ? .unhide(body) : .hide(body), sites: sites, notOn: notOn)
        }
        // AdGuard's way of writing a scriptlet: `site#%#//scriptlet('name', 'arg')`.
        if let range = line.range(of: "#%#//scriptlet(") {
            guard let (sites, notOn) = parseDomains(String(line[..<range.lowerBound])),
                  let scriptlet = parseScriptlet("+js(" + line[range.upperBound...]) else { return nil }
            return PageRule(action: .scriptlet(scriptlet), sites: sites, notOn: notOn)
        }
        return nil
    }

    static func parseDomains(_ text: String) -> (sites: [String], notOn: [String])? {
        var sites: [String] = [], notOn: [String] = []
        for part in text.split(separator: ",") {
            var domain = part.trimmingCharacters(in: .whitespaces).lowercased()
            let negated = domain.hasPrefix("~")
            if negated { domain.removeFirst() }
            // A regular expression or a path: left out.
            guard !domain.isEmpty, !domain.contains("/"), !domain.contains("["),
                  domain.allSatisfy({ $0.isLetter || $0.isNumber || ".-*_".contains($0) }) else { return nil }
            if negated { notOn.append(domain) } else { sites.append(domain) }
        }
        return (sites, notOn)
    }

    /// `+js(name, a, b)` or `+js('name', 'a')`: its name, as `Scriptlet.known`
    /// names it, and its arguments.
    static func parseScriptlet(_ body: String) -> Scriptlet? {
        guard body.hasPrefix("+js("), body.hasSuffix(")") else { return nil }
        let inner = body.dropFirst(4).dropLast()
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in inner {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if (character == "'" || character == "\"") && current.allSatisfy(\.isWhitespace) {
                quote = character
                current = ""
            } else if character == "," {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        var name = parts.removeFirst()
        if name.hasSuffix(".js") { name.removeLast(3) }
        guard let known = Scriptlet.known[name] else { return nil }
        while parts.last == "" { parts.removeLast() }
        return Scriptlet(name: known, arguments: parts)
    }

    /// A CSS selector a stylesheet can hide as it is: not one of the
    /// extended kinds only an ad blocker's own code understands.
    static func isPlainSelector(_ selector: String) -> Bool {
        guard !selector.isEmpty, !selector.hasPrefix("+"), !selector.hasPrefix("^") else { return false }
        let extended = [":has(", ":has-text(", ":-abp-", ":xpath(", ":upward(", ":remove(", ":style(", ":matches-",
                        ":min-text-length(", ":watch-attr(", ":others(", ":if(", ":if-not(", ":contains("]
        if extended.contains(where: selector.contains) { return false }
        // Braces would end the rule the stylesheet wraps it in.
        return !selector.contains("{") && !selector.contains("}")
    }
}

/// The rules for inside pages, indexed by site.
public struct PageRules: Codable, Equatable {
    /// Hidden on every page, unless a site's exception says otherwise.
    public private(set) var generic: [String] = []
    struct Entry: Codable, Equatable {
        /// 0 hide, 1 unhide, 2 scriptlet.
        var kind: UInt8
        var selector: String?
        var scriptlet: Scriptlet?
        var notOn: [String]?
    }
    /// Rules for each site, and the ones for everywhere but some (`~site##`)
    /// under "".
    private(set) var bySite: [String: [Entry]] = [:]

    public init(rules: [PageRule]) {
        var generic: [String] = []
        var seen = Set<String>()
        for rule in rules {
            let entry: Entry
            switch rule.action {
            case .hide(let selector):    entry = Entry(kind: 0, selector: selector)
            case .unhide(let selector):  entry = Entry(kind: 1, selector: selector)
            case .scriptlet(let script): entry = Entry(kind: 2, scriptlet: script)
            }
            var placed = entry
            placed.notOn = rule.notOn.isEmpty ? nil : rule.notOn
            if rule.sites.isEmpty {
                if case .hide(let selector) = rule.action, rule.notOn.isEmpty {
                    if seen.insert(selector).inserted { generic.append(selector) }
                } else if case .unhide(let selector) = rule.action, rule.notOn.isEmpty {
                    // An exception everywhere: it was never hidden.
                    generic.removeAll { $0 == selector }
                    seen.remove(selector)
                } else {
                    bySite["", default: []].append(placed)
                }
            } else {
                for site in rule.sites { bySite[site, default: []].append(placed) }
            }
        }
        self.generic = generic
    }

    /// The rules from a list's text.
    public init(listText: String) {
        self.init(rules: listText.split(whereSeparator: \.isNewline).compactMap { PageRule.parse(String($0)) })
    }

    public var siteCount: Int { bySite.keys.filter { !$0.isEmpty }.count }
    public var ruleCount: Int { generic.count + bySite.values.reduce(0) { $0 + $1.count } }

    /// What a page on `host` gets.
    public struct ForPage: Equatable {
        /// Hidden there: every generic selector but its exceptions, then its own.
        public var selectors: [String]
        public var scriptlets: [Scriptlet]
    }

    public func forPage(on host: String) -> ForPage {
        let domains = Self.lookupNames(for: host)
        var hide: [String] = [], unhide = Set<String>(), scriptlets: [Scriptlet] = []
        for key in domains + [""] {
            for entry in bySite[key] ?? [] {
                if let notOn = entry.notOn, notOn.contains(where: { Self.matches(host, $0) }) { continue }
                switch entry.kind {
                case 0: if let selector = entry.selector { hide.append(selector) }
                case 1: if let selector = entry.selector { unhide.insert(selector) }
                default: if let scriptlet = entry.scriptlet, !scriptlets.contains(scriptlet) { scriptlets.append(scriptlet) }
                }
            }
        }
        let selectors = unhide.isEmpty ? generic + hide : (generic + hide).filter { !unhide.contains($0) }
        return ForPage(selectors: selectors, scriptlets: scriptlets)
    }

    /// The keys a host's rules are under: itself and each domain above it,
    /// each also as `name.*` with its public suffix left open.
    static func lookupNames(for host: String) -> [String] {
        let domains = SiteName.domains(of: host)
        guard let site = domains.last, let dot = site.firstIndex(of: ".") else { return domains }
        let suffix = site[site.index(after: dot)...]
        return domains + domains.map { String($0.dropLast(suffix.count + 1)) + ".*" }
    }

    /// Whether a rule's domain covers `host`: it, or a name under it, with
    /// `name.*` open to any public suffix.
    static func matches(_ host: String, _ domain: String) -> Bool {
        lookupNames(for: host).contains(domain) || host == domain
    }

    // MARK: Travelling

    /// As `pages.bin` holds them: a binary property list.
    public func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) -> PageRules? {
        try? PropertyListDecoder().decode(PageRules.self, from: data)
    }

    public static let fileName = "pages.bin"

    /// Where they come from: EasyList and EasyPrivacy, under CC BY-SA 3.0.
    public static let sources: [(name: String, url: URL)] = [
        ("EasyList", URL(string: "https://easylist.to/easylist/easylist.txt")!),
        ("EasyPrivacy", URL(string: "https://easylist.to/easylist/easyprivacy.txt")!),
    ]

    /// Far below EasyList's thirteen thousand, far above an error page.
    public static let minimumGeneric = 5_000
}
