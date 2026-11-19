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
        /// `#@#+js(…)`: don't run this scriptlet there; nil for none at all.
        case noScriptlet(Scriptlet?)
        /// `@@||site^$generichide`: none of the rules for every page there.
        case noGenericHiding
        /// `@@||site^$elemhide` (or `$document`): no hiding there at all.
        case noHiding
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
        if line.hasPrefix("@@") { return parseException(line) }
        for (marker, unhide) in [("#@#", true), ("##", false)] {
            guard let range = line.range(of: marker) else { continue }
            let domains = String(line[..<range.lowerBound])
            let body = String(line[range.upperBound...])
            // Another marker before this one: `#?#`, `#$#` and their kind.
            if domains.contains("#") || domains.contains("$") || domains.contains("/") { return nil }
            guard let (sites, notOn) = parseDomains(domains) else { return nil }
            if body.hasPrefix("+js(") {
                if unhide {
                    if body == "+js()" { return PageRule(action: .noScriptlet(nil), sites: sites, notOn: notOn) }
                    guard let scriptlet = parseScriptlet(body) else { return nil }
                    return PageRule(action: .noScriptlet(scriptlet), sites: sites, notOn: notOn)
                }
                guard let scriptlet = parseScriptlet(body) else { return nil }
                return PageRule(action: .scriptlet(scriptlet), sites: sites, notOn: notOn)
            }
            guard isPlainSelector(body) else { return nil }
            return PageRule(action: unhide ? .unhide(body) : .hide(body), sites: sites, notOn: notOn)
        }
        // AdGuard's way of writing a scriptlet, and an exception to one:
        // `site#%#//scriptlet('name', 'arg')`, `site#@%#//scriptlet(…)`.
        for (marker, exception) in [("#@%#//scriptlet(", true), ("#%#//scriptlet(", false)] {
            guard let range = line.range(of: marker) else { continue }
            guard let (sites, notOn) = parseDomains(String(line[..<range.lowerBound])) else { return nil }
            let body = "+js(" + line[range.upperBound...]
            if exception && body == "+js()" { return PageRule(action: .noScriptlet(nil), sites: sites, notOn: notOn) }
            guard let scriptlet = parseScriptlet(body) else { return nil }
            return PageRule(action: exception ? .noScriptlet(scriptlet) : .scriptlet(scriptlet), sites: sites, notOn: notOn)
        }
        return nil
    }

    /// `@@||site^$generichide`, `$elemhide`, `$document`: a site's exception
    /// from hiding. Any other exception by address is the filter's, not ours.
    static func parseException(_ line: String) -> PageRule? {
        guard line.hasPrefix("@@||"), let dollar = line.lastIndex(of: "$") else { return nil }
        var site = String(line[line.index(line.startIndex, offsetBy: 4)..<dollar])
        if site.hasSuffix("^") { site.removeLast() }
        guard let (sites, _) = parseDomains(site), sites.count == 1 else { return nil }
        let options = line[line.index(after: dollar)...].split(separator: ",").map(String.init)
        if options.contains(where: { ["elemhide", "ehide", "document", "doc"].contains($0) }) {
            return PageRule(action: .noHiding, sites: sites, notOn: [])
        }
        if options.contains(where: { ["generichide", "ghide"].contains($0) }) {
            return PageRule(action: .noGenericHiding, sites: sites, notOn: [])
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
    /// names it, and its arguments. A backslash escapes only a comma (and,
    /// in quotes, the quote): everywhere else it's kept, as regular
    /// expressions need it. A quoted empty argument is kept; empty ones at
    /// the end, unquoted, are padding.
    public static func parseScriptlet(_ body: String) -> Scriptlet? {
        guard body.hasPrefix("+js("), body.hasSuffix(")") else { return nil }
        let inner = Array(body.dropFirst(4).dropLast())
        var parts: [(text: String, quoted: Bool)] = []
        var current = ""
        var quoted = false
        var quote: Character?
        var index = 0
        while index < inner.count {
            let character = inner[index]
            let next = index + 1 < inner.count ? inner[index + 1] : nil
            if character == "\\", let next, next == "," || next == quote {
                current.append(next)
                index += 2
                continue
            }
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if (character == "'" || character == "\"") && current.allSatisfy(\.isWhitespace) {
                quote = character
                quoted = true
                current = ""
            } else if character == "," {
                parts.append((quoted ? current : current.trimmingCharacters(in: .whitespaces), quoted))
                current = ""
                quoted = false
            } else {
                current.append(character)
            }
            index += 1
        }
        parts.append((quoted ? current : current.trimmingCharacters(in: .whitespaces), quoted))
        var name = parts.removeFirst().text
        if name.hasSuffix(".js") { name.removeLast(3) }
        guard let known = Scriptlet.known[name] else { return nil }
        while let last = parts.last, last.text.isEmpty, !last.quoted { parts.removeLast() }
        return Scriptlet(name: known, arguments: parts.map(\.text))
    }

    /// A CSS selector a stylesheet can hide as it is: not one of the
    /// extended kinds only an ad blocker's own code understands.
    static func isPlainSelector(_ selector: String) -> Bool {
        guard !selector.isEmpty, !selector.hasPrefix("+"), !selector.hasPrefix("^") else { return false }
        let extended = [":has(", ":has-text(", ":-abp-", ":xpath(", ":upward(", ":remove", ":style(", ":matches-",
                        ":min-text-length(", ":watch-attr(", ":others(", ":if(", ":if-not(", ":contains(",
                        ":nth-ancestor(", ":spath(", ":shadow", ":matches-css"]
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
        /// 0 hide, 1 unhide, 2 scriptlet, 3 no scriptlet (nil: none), 4 no
        /// generic hiding, 5 no hiding.
        var kind: UInt8
        var selector: String?
        var scriptlet: Scriptlet?
        var notOn: [String]?
    }
    /// Rules for each site, and the ones for everywhere but some (`~site##`)
    /// under "".
    private(set) var bySite: [String: [Entry]] = [:]
    /// The rules read from the lists, before they're spread over their sites.
    public private(set) var ruleCount = 0
    /// Where each generic selector is, so a site's few exceptions are taken
    /// out without looking at the thirteen thousand others.
    private var genericIndex: [String: [Int]] = [:]

    private enum CodingKeys: String, CodingKey { case generic, bySite, ruleCount }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generic = try container.decode([String].self, forKey: .generic)
        bySite = try container.decode([String: [Entry]].self, forKey: .bySite)
        ruleCount = try container.decode(Int.self, forKey: .ruleCount)
        genericIndex = Self.index(generic)
    }

    private static func index(_ selectors: [String]) -> [String: [Int]] {
        Dictionary(grouping: selectors.indices, by: { selectors[$0] })
    }

    public init(rules: [PageRule]) {
        var generic: [String] = []
        var seen = Set<String>()
        // Exceptions everywhere (`#@#.x`) apply to every rule, wherever in
        // the lists they come: they're taken out once all are read.
        var unhiddenEverywhere = Set<String>()
        for rule in rules {
            var entry: Entry
            switch rule.action {
            case .hide(let selector):        entry = Entry(kind: 0, selector: selector)
            case .unhide(let selector):      entry = Entry(kind: 1, selector: selector)
            case .scriptlet(let script):     entry = Entry(kind: 2, scriptlet: script)
            case .noScriptlet(let script):   entry = Entry(kind: 3, scriptlet: script)
            case .noGenericHiding:           entry = Entry(kind: 4)
            case .noHiding:                  entry = Entry(kind: 5)
            }
            entry.notOn = rule.notOn.isEmpty ? nil : rule.notOn
            if rule.sites.isEmpty && rule.notOn.isEmpty {
                switch rule.action {
                case .hide(let selector):
                    if seen.insert(selector).inserted { generic.append(selector) }
                    continue
                case .unhide(let selector):
                    unhiddenEverywhere.insert(selector)
                    continue
                default: break
                }
            }
            if rule.sites.isEmpty {
                bySite["", default: []].append(entry)
            } else {
                for site in rule.sites { bySite[site, default: []].append(entry) }
            }
        }
        self.generic = generic.filter { !unhiddenEverywhere.contains($0) }
        if !unhiddenEverywhere.isEmpty {
            for (site, entries) in bySite {
                bySite[site] = entries.filter { $0.kind != 0 || !unhiddenEverywhere.contains($0.selector ?? "") }
            }
        }
        ruleCount = rules.count
        genericIndex = Self.index(self.generic)
    }

    /// The rules from a list's text. Lines in `!#if … !#endif` blocks are
    /// for particular blockers or browsers: left out, whatever they say.
    public init(listText: String) {
        var depth = 0
        var rules: [PageRule] = []
        for line in listText.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("!#if") { depth += 1; continue }
            if trimmed.hasPrefix("!#endif") { depth = max(0, depth - 1); continue }
            guard depth == 0, let rule = PageRule.parse(trimmed) else { continue }
            rules.append(rule)
        }
        self.init(rules: rules)
    }

    public var siteCount: Int { bySite.keys.filter { !$0.isEmpty }.count }

    /// What a page on `host` gets.
    public struct ForPage: Equatable {
        /// Hidden there: every generic selector but its exceptions, then its own.
        public var selectors: [String]
        public var scriptlets: [Scriptlet]
    }

    public func forPage(on host: String) -> ForPage {
        let keys = Self.lookupNames(for: host)
        let hostNames = Set(keys)
        var hide: [String] = [], unhide = Set<String>(), scriptlets: [Scriptlet] = []
        var noScriptlets = Set<Scriptlet>(), noScriptletsAtAll = false
        var noGeneric = false, noHiding = false
        for key in keys + [""] {
            for entry in bySite[key] ?? [] {
                if let notOn = entry.notOn, notOn.contains(where: hostNames.contains) { continue }
                switch entry.kind {
                case 0: if let selector = entry.selector { hide.append(selector) }
                case 1: if let selector = entry.selector { unhide.insert(selector) }
                case 2: if let scriptlet = entry.scriptlet, !scriptlets.contains(scriptlet) { scriptlets.append(scriptlet) }
                case 3: if let scriptlet = entry.scriptlet { noScriptlets.insert(scriptlet) } else { noScriptletsAtAll = true }
                case 4: noGeneric = true
                default: noHiding = true
                }
            }
        }
        var selectors: [String] = []
        if !noHiding {
            if !noGeneric {
                let gone = Set(unhide.flatMap { genericIndex[$0] ?? [] })
                selectors = gone.isEmpty ? generic
                    : generic.indices.compactMap { gone.contains($0) ? nil : generic[$0] }
            }
            selectors += unhide.isEmpty ? hide : hide.filter { !unhide.contains($0) }
        }
        scriptlets = noScriptletsAtAll ? [] : scriptlets.filter { !noScriptlets.contains($0) }
        return ForPage(selectors: selectors, scriptlets: scriptlets)
    }

    /// The keys a host's rules are under: itself and every name above it but
    /// the last label, as ad-blocking lists match (so `blogspot.com`'s rules
    /// reach `someone.blogspot.com`, though it's a public suffix), each also
    /// as `name.*` with its public suffix left open.
    static func lookupNames(for host: String) -> [String] {
        guard let name = SiteName.normalized(host) else { return [] }
        let labels = name.split(separator: ".")
        var names: [String] = []
        for start in 0..<max(labels.count - 1, 0) { names.append(labels[start...].joined(separator: ".")) }
        let site = SiteName.site(of: name)
        if let dot = site.firstIndex(of: ".") {
            let suffix = site[site.index(after: dot)...]
            for domain in SiteName.domains(of: name) { names.append(String(domain.dropLast(suffix.count + 1)) + ".*") }
        }
        return names
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
