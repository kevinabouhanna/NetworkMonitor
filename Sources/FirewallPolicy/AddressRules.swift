import Foundation

// Requests refused by their whole address (#699, a step of Enhanced ad
// blocking, #256): inside an opened page, the secure bridge asks these about
// each request before it goes to the site, and answers a refused one itself,
// empty. They're EasyList's and EasyPrivacy's rules by address
// (`||example.com/ads/`, `/banner/*`, with `$third-party`, `$script`,
// `$domain=`), indexed by a token of each, as ad blockers keep them, so an
// address is checked against the few rules that could match it rather than
// all of them. Pure Foundation, like the page rules they ship in.

/// What a request is for, as a rule's type options name it.
public struct RequestKind: OptionSet, Hashable, Codable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let script = RequestKind(rawValue: 1 << 0)
    public static let image = RequestKind(rawValue: 1 << 1)
    public static let stylesheet = RequestKind(rawValue: 1 << 2)
    public static let xmlhttprequest = RequestKind(rawValue: 1 << 3)
    public static let subdocument = RequestKind(rawValue: 1 << 4)
    public static let media = RequestKind(rawValue: 1 << 5)
    public static let font = RequestKind(rawValue: 1 << 6)
    public static let ping = RequestKind(rawValue: 1 << 7)
    public static let websocket = RequestKind(rawValue: 1 << 8)
    public static let object = RequestKind(rawValue: 1 << 9)
    public static let other = RequestKind(rawValue: 1 << 10)
    /// A page itself, as a browser navigates to it: never refused.
    public static let document = RequestKind(rawValue: 1 << 11)

    /// Every kind a rule with no type option reaches: all but a page itself.
    public static let allButDocument: RequestKind = [.script, .image, .stylesheet, .xmlhttprequest, .subdocument,
                                                     .media, .font, .ping, .websocket, .object, .other]

    static let names: [String: RequestKind] = [
        "script": .script, "image": .image, "stylesheet": .stylesheet, "css": .stylesheet,
        "xmlhttprequest": .xmlhttprequest, "xhr": .xmlhttprequest, "subdocument": .subdocument, "frame": .subdocument,
        "media": .media, "font": .font, "ping": .ping, "beacon": .ping, "websocket": .websocket,
        "object": .object, "object-subrequest": .object, "other": .other,
    ]

    /// The kind a browser says a request is for, by its `Sec-Fetch-Dest`
    /// (Safari, Chrome and their kind send it); without it, by what it
    /// accepts.
    public static func of(fetchDest: String?, accept: String?, upgrade: String? = nil) -> RequestKind {
        if upgrade?.lowercased() == "websocket" { return .websocket }
        if let dest = fetchDest?.lowercased() {
            switch dest {
            case "document": return .document
            case "script": return .script
            case "style": return .stylesheet
            case "image": return .image
            case "font": return .font
            case "audio", "video", "track": return .media
            case "iframe", "frame": return .subdocument
            case "object", "embed": return .object
            case "empty": return .xmlhttprequest
            default: return .other
            }
        }
        let accept = accept?.lowercased() ?? ""
        if accept.hasPrefix("text/html") { return .document }
        if accept.hasPrefix("image/") { return .image }
        if accept.hasPrefix("text/css") { return .stylesheet }
        return .other
    }
}

/// One request, as the rules see it.
public struct AddressRequest: Equatable {
    /// Its whole address: `https://host/path?query`.
    public var url: String
    public var host: String
    /// The page that made it, by its host (from `Origin` or `Referer`); nil
    /// when the browser didn't say.
    public var pageHost: String?
    public var kind: RequestKind
    /// Whether it goes to another site than its page's; nil when unknown.
    public var isThirdParty: Bool?

    public init(url: String, host: String, pageHost: String?, kind: RequestKind, isThirdParty: Bool?) {
        self.url = url
        self.host = host.lowercased()
        self.pageHost = pageHost?.lowercased()
        self.kind = kind
        self.isThirdParty = isThirdParty
    }

    /// A browser's request to `host`, read from its head: the page from
    /// `Origin` or `Referer`, the kind from `Sec-Fetch-Dest`, whether it's
    /// another site's from `Sec-Fetch-Site`, or else by comparing sites.
    public init(host: String, port: UInt16 = 443, target: String, header: (String) -> String?) {
        let host = host.lowercased()
        let path = target.hasPrefix("/") ? target : "/" + target
        let url = "https://" + host + (port == 443 ? "" : ":\(port)") + path
        var pageHost: String?
        for name in ["Origin", "Referer"] {
            if let value = header(name), value != "null", let found = URLComponents(string: value)?.host, !found.isEmpty {
                pageHost = found.lowercased()
                break
            }
        }
        var thirdParty: Bool?
        switch header("Sec-Fetch-Site")?.lowercased() {
        case "cross-site"?: thirdParty = true
        case "same-site"?, "same-origin"?, "none"?: thirdParty = false
        default:
            if let pageHost { thirdParty = SiteName.site(of: pageHost) != SiteName.site(of: host) }
        }
        self.init(url: url, host: host, pageHost: pageHost,
                  kind: .of(fetchDest: header("Sec-Fetch-Dest"), accept: header("Accept"), upgrade: header("Upgrade")),
                  isThirdParty: thirdParty)
    }
}

/// One rule by address, as a list writes it.
public struct AddressRule: Equatable {
    /// `@@`: lets a request through that another rule would refuse.
    public var isException: Bool
    /// The address pattern, lowercased unless `$match-case`: `*` any run of
    /// characters, `^` a separator or the end.
    public var pattern: String
    /// `||`: starts at the start of the host or of one of its labels.
    public var hostAnchored: Bool
    /// `|` at the start: the address starts with it; at the end: ends.
    public var startAnchored: Bool
    public var endAnchored: Bool
    public var kinds: RequestKind
    /// `$third-party` true, `$~third-party` false.
    public var thirdParty: Bool?
    /// `$domain=`: pages it applies on, and those it doesn't.
    public var domains: [String]
    public var notDomains: [String]
    public var matchCase: Bool
    /// `$important`: refuses whatever an exception says, but an important one.
    public var important: Bool
    /// `@@…$document`: nothing on a page whose address it matches is refused.
    public var wholePage: Bool

    public init(isException: Bool = false, pattern: String, hostAnchored: Bool = false, startAnchored: Bool = false,
                endAnchored: Bool = false, kinds: RequestKind = .allButDocument, thirdParty: Bool? = nil,
                domains: [String] = [], notDomains: [String] = [], matchCase: Bool = false, important: Bool = false,
                wholePage: Bool = false) {
        self.isException = isException
        self.pattern = pattern
        self.hostAnchored = hostAnchored
        self.startAnchored = startAnchored
        self.endAnchored = endAnchored
        self.kinds = kinds
        self.thirdParty = thirdParty
        self.domains = domains
        self.notDomains = notDomains
        self.matchCase = matchCase
        self.important = important
        self.wholePage = wholePage
    }

    /// Options that only change how a page looks, or what another blocker
    /// does: a rule with one isn't about refusing a request.
    static let cosmetic: Set<String> = ["elemhide", "ehide", "generichide", "ghide", "specifichide", "shide",
                                        "content", "jsinject", "urlblock", "genericblock", "stealth", "extension"]

    /// The rule a list's line holds, or nil for anything else: a comment, a
    /// rule for inside pages, a regular expression, a pop-up's, or one with
    /// an option it doesn't do (rewriting, headers, `$csp`, `$removeparam`…),
    /// left out rather than read as something it isn't.
    public static func parse(_ line: String) -> AddressRule? {
        var text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.hasPrefix("!"), !text.hasPrefix("[") else { return nil }
        for marker in ["##", "#@#", "#?#", "#$#", "#%#", "#@%#", "#@?#", "#@$#", "$$", "$@$"] where text.contains(marker) {
            return nil
        }
        var rule = AddressRule(pattern: "")
        if text.hasPrefix("@@") {
            rule.isException = true
            text.removeFirst(2)
        }
        var options: [Substring] = []
        if let dollar = text.lastIndex(of: "$") {
            let tail = text[text.index(after: dollar)...]
            // A `$` in an address, not before options: an option starts
            // with its name, a word.
            let name = tail.prefix { $0 != "," && $0 != "=" }
            if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || "-_~".contains($0) }) {
                options = tail.split(separator: ",")
                text = String(text[..<dollar])
            }
        }
        // A regular expression: few, and slow to check every address against.
        if text.count > 1, text.hasPrefix("/"), text.hasSuffix("/") { return nil }
        var include = RequestKind(), exclude = RequestKind()
        var document = false
        for option in options {
            var name = option.lowercased()
            let negated = name.hasPrefix("~")
            if negated { name.removeFirst() }
            if let kind = RequestKind.names[name] {
                if negated { exclude.insert(kind) } else { include.insert(kind) }
                continue
            }
            switch name {
            case "third-party", "3p":
                rule.thirdParty = !negated
            case "first-party", "1p":
                rule.thirdParty = negated
            case "match-case":
                rule.matchCase = !negated
            case "important":
                rule.important = true
            case "document", "doc":
                if negated { continue }
                document = true
            case "all":
                include.formUnion(.allButDocument)
            case _ where name.hasPrefix("domain=") || name.hasPrefix("from="):
                let list = name.split(separator: "=", maxSplits: 1).last ?? ""
                for part in list.split(separator: "|") {
                    var domain = String(part)
                    let not = domain.hasPrefix("~")
                    if not { domain.removeFirst() }
                    guard !domain.isEmpty, !domain.contains("/"),
                          domain.allSatisfy({ $0.isLetter || $0.isNumber || ".-*_".contains($0) }) else { return nil }
                    if not { rule.notDomains.append(domain) } else { rule.domains.append(domain) }
                }
            case _ where name.hasPrefix("redirect=") || name == "empty" || name == "mp4":
                // Another blocker's stand-in for what it refuses: ours is an
                // empty reply of the kind asked for, so it's refused all the same.
                if rule.isException { return nil }
            default:
                // A pop-up's, a cosmetic one, or an option it doesn't do.
                return nil
            }
        }
        if document {
            // Refusing a page itself is the name filter's to do; an exception
            // for a whole page is kept, for what that page asks for.
            guard rule.isException, include.isEmpty else { return nil }
            rule.wholePage = true
        }
        if rule.isException && options.contains(where: { cosmetic.contains($0.lowercased()) }) { return nil }
        var kinds = include.isEmpty ? RequestKind.allButDocument : include
        kinds.subtract(exclude)
        guard !kinds.isEmpty || rule.wholePage else { return nil }
        rule.kinds = kinds
        if text.hasPrefix("||") {
            rule.hostAnchored = true
            text.removeFirst(2)
        } else if text.hasPrefix("|") {
            rule.startAnchored = true
            text.removeFirst()
        }
        if text.hasSuffix("|") {
            rule.endAnchored = true
            text.removeLast()
        }
        // A rule with no pattern and no options would refuse everything.
        while text.hasPrefix("*") && !rule.hostAnchored && !rule.startAnchored { text.removeFirst() }
        while text.hasSuffix("*") && !rule.endAnchored { text.removeLast() }
        // A rule with no pattern would refuse everything of its kind: only
        // kept when it's for some pages alone.
        if text.isEmpty && (rule.domains.isEmpty || rule.isException) && !rule.wholePage { return nil }
        guard !text.contains("|") || text.hasPrefix("http") else { return nil }
        rule.pattern = rule.matchCase ? text : text.lowercased()
        return rule
    }

    /// A rule refusing a whole host and nothing else (`||ads.example^`): kept
    /// as a name, looked up rather than matched.
    var plainHost: String? {
        guard !isException, hostAnchored, !startAnchored, !endAnchored, kinds == .allButDocument, thirdParty == nil,
              domains.isEmpty, notDomains.isEmpty, !important, !wholePage else { return nil }
        var host = pattern
        if host.hasSuffix("^") { host.removeLast() } else { return nil }
        guard !host.isEmpty, host.contains("."),
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        return host
    }

    // MARK: Matching

    /// Whether its options hold for the request: its kind, another site's,
    /// on which pages. Its pattern is checked apart.
    func optionsHold(for request: AddressRequest, pageNames: () -> [String]) -> Bool {
        if !wholePage {
            guard kinds.contains(request.kind) else { return false }
        }
        if let thirdParty {
            guard let actual = request.isThirdParty, actual == thirdParty else { return false }
        }
        if !domains.isEmpty || !notDomains.isEmpty {
            guard let page = request.pageHost else { return domains.isEmpty }
            func on(_ domain: String) -> Bool {
                // `example.*`: under any public suffix, as the page rules read it.
                if domain.hasSuffix(".*") { return pageNames().contains(domain) }
                guard page.hasSuffix(domain) else { return false }
                let page = page.utf8, domain = domain.utf8
                return page.count == domain.count
                    || page[page.index(page.endIndex, offsetBy: -domain.count - 1)] == UInt8(ascii: ".")
            }
            if !domains.isEmpty, !domains.contains(where: on) { return false }
            if notDomains.contains(where: on) { return false }
        }
        return true
    }
}

/// An address as the rules read it: its bytes (lowercased, and as written
/// for `$match-case`), where its host is, and its tokens.
struct Address {
    let original: [UInt8]
    let lowered: [UInt8]
    let hostRange: Range<Int>

    init(_ url: String) {
        original = Array(url.utf8)
        // ASCII, as addresses are sent: lowercased by the standard library;
        // anything else byte by byte, so the two line up.
        let lower = Array(url.lowercased().utf8)
        lowered = lower.count == original.count ? lower : original.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 32 : $0 }
        // The host: after `://`, up to the path, port, query or fragment.
        var start = 0
        let colon = UInt8(ascii: ":"), slash = UInt8(ascii: "/")
        if lowered.count > 3 {
            for index in 0..<(lowered.count - 2)
            where lowered[index] == colon && lowered[index + 1] == slash && lowered[index + 2] == slash {
                start = index + 3
                break
            }
        }
        var end = start
        while end < lowered.count {
            let byte = lowered[end]
            if byte == slash || byte == colon || byte == UInt8(ascii: "?") || byte == UInt8(ascii: "#") { break }
            end += 1
        }
        hostRange = start..<end
    }

    /// Its runs of letters and digits, each once, by their hash (as the
    /// rules are indexed), and 0 for the rules with no token.
    var tokens: [UInt64] {
        var tokens: [UInt64] = [0]
        var index = 0
        let count = lowered.count
        while index < count {
            guard Pattern.isTokenByte(lowered[index]) else { index += 1; continue }
            var hash = Token.seed
            while index < count, Pattern.isTokenByte(lowered[index]) {
                hash = Token.mix(hash, lowered[index])
                index += 1
            }
            if !tokens.contains(hash) { tokens.append(hash) }
        }
        return tokens
    }
}

/// A token's hash, FNV-1a: what the rules are indexed by, so an address's
/// tokens are looked up without making a string of each. Two tokens with the
/// same hash only put a few more rules before the pattern that decides.
enum Token {
    static let seed: UInt64 = 0xcbf2_9ce4_8422_2325

    @inline(__always)
    static func mix(_ hash: UInt64, _ byte: UInt8) -> UInt64 { (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }

    static func hash(_ token: String) -> UInt64 {
        token.isEmpty ? 0 : token.utf8.reduce(seed, mix)
    }
}

/// What's quickly checked of a rule, before its pattern: its kinds, whether
/// for another site's requests (-1 either), and whether it's for some pages.
struct Quick {
    let kinds: UInt16
    let party: Int8
    let important: Bool
    let hasDomains: Bool

    init(_ rule: AddressRule) {
        kinds = rule.kinds.rawValue
        party = rule.thirdParty.map { $0 ? 1 : 0 } ?? -1
        important = rule.important
        hasDomains = !rule.domains.isEmpty || !rule.notDomains.isEmpty
    }
}

/// A rule's pattern, ready to match: its bytes, and its parts between `*`s.
struct Pattern {
    let bytes: [UInt8]
    let parts: [Range<Int>]
    let hostAnchored: Bool
    let startAnchored: Bool
    let endAnchored: Bool
    let matchCase: Bool

    init(_ rule: AddressRule) {
        bytes = Array(rule.pattern.utf8)
        var parts: [Range<Int>] = []
        var start = 0
        for (index, byte) in bytes.enumerated() where byte == UInt8(ascii: "*") {
            parts.append(start..<index)
            start = index + 1
        }
        parts.append(start..<bytes.count)
        self.parts = parts
        hostAnchored = rule.hostAnchored
        startAnchored = rule.startAnchored
        endAnchored = rule.endAnchored
        matchCase = rule.matchCase
    }

    static let caret = UInt8(ascii: "^")

    /// A character a `^` matches: anything but a letter, a digit, or
    /// `_ - . %`.
    @inline(__always)
    static func isSeparator(_ byte: UInt8) -> Bool {
        !(isTokenByte(byte) || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "."))
    }

    @inline(__always)
    static func isTokenByte(_ byte: UInt8) -> Bool {
        (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
            || byte == 0x25
    }

    func matches(_ address: Address) -> Bool {
        let url = matchCase ? address.original : address.lowered
        if startAnchored { return rest(url, from: 0) }
        if hostAnchored {
            let range = address.hostRange
            if rest(url, from: range.lowerBound) { return true }
            var index = range.lowerBound
            while index + 1 < range.upperBound {
                if url[index] == 0x2E, rest(url, from: index + 1) { return true }
                index += 1
            }
            return false
        }
        let first = parts[0]
        if endAnchored, parts.count == 1 {
            let at = url.count - first.count
            return at >= 0 && part(first, isLast: true, at: at, url)
        }
        // Unanchored: its first part found anywhere. The leftmost leaves the
        // most room for the rest, so it's the only one to try.
        guard let found = find(first, isLast: parts.count == 1, from: 0, url) else { return false }
        return rest(url, from: found)
    }

    /// Whether the pattern matches with its first part at `start`.
    private func rest(_ url: [UInt8], from start: Int) -> Bool {
        let lastIndex = parts.count - 1
        let first = parts[0]
        guard part(first, isLast: lastIndex == 0, at: start, url) else { return false }
        var position = min(start + first.count, url.count)
        if lastIndex == 0 { return !endAnchored || position == url.count }
        var index = 1
        while index < lastIndex {
            let middle = parts[index]
            guard let found = find(middle, isLast: false, from: position, url) else { return false }
            position = min(found + middle.count, url.count)
            index += 1
        }
        let last = parts[lastIndex]
        if endAnchored {
            let at = url.count - last.count
            return at >= position && part(last, isLast: true, at: at, url)
        }
        return find(last, isLast: true, from: position, url) != nil
    }

    /// Whether the part is at `at`. A `^` ending the whole pattern also
    /// matches the end of the address.
    private func part(_ part: Range<Int>, isLast: Bool, at: Int, _ url: [UInt8]) -> Bool {
        var position = at
        var index = part.lowerBound
        let end = part.upperBound
        let count = url.count
        while index < end {
            let byte = bytes[index]
            if position == count {
                return isLast && byte == Self.caret && index == end - 1
            }
            let actual = url[position]
            if byte == Self.caret {
                if !Self.isSeparator(actual) { return false }
            } else if byte != actual {
                return false
            }
            position += 1
            index += 1
        }
        return true
    }

    /// Where the part is first found from `from`, if anywhere.
    private func find(_ part: Range<Int>, isLast: Bool, from: Int, _ url: [UInt8]) -> Int? {
        let count = url.count
        guard !part.isEmpty else { return from <= count ? from : nil }
        let first = bytes[part.lowerBound]
        var position = from
        while position <= count {
            // Only where its first byte is, unless that's a `^`.
            if first != Self.caret {
                guard position < count else { return nil }
                let from = position
                let found = url.withUnsafeBufferPointer { buffer -> Int? in
                    guard let base = buffer.baseAddress,
                          let hit = memchr(base + from, Int32(first), count - from) else { return nil }
                    return base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                }
                guard let found else { return nil }
                position = found
            }
            if self.part(part, isLast: isLast, at: position, url) { return position }
            position += 1
        }
        return nil
    }
}

/// The rules by address, indexed: the whole hosts they refuse as names, the
/// rest under a token each.
public struct AddressRules: Codable, Equatable {
    /// The rules as the lists wrote them, kept as text and indexed when read.
    public private(set) var lines: [String] = []

    private var hosts: Set<String> = []
    private var rules: [AddressRule] = []
    private var patterns: [Pattern] = []
    /// What's quickly checked of each rule, first.
    private var quick: [Quick] = []
    /// Block rules, then exceptions, by token; those with none under "".
    private var blocks: [UInt64: [Int]] = [:]
    private var exceptions: [UInt64: [Int]] = [:]
    private var wholePages: [Int] = []
    /// `@@||site^$document`, the usual kind, by site.
    private var wholePageHosts: Set<String> = []

    private enum CodingKeys: String, CodingKey { case lines }

    public init(lines: [String]) {
        var kept: [(line: String, rule: AddressRule)] = []
        for line in lines {
            if let rule = AddressRule.parse(line) { kept.append((line, rule)) }
        }
        self.lines = kept.map(\.line)
        // Each rule goes under the token it has that the fewest others have,
        // so no address meets many rules.
        let candidates = kept.map { Self.tokens(of: $0.rule) }
        var frequency: [String: Int] = [:]
        for tokens in candidates { for token in tokens { frequency[token, default: 0] += 1 } }
        for (index, (_, rule)) in kept.enumerated() {
            if let host = rule.plainHost {
                hosts.insert(host)
                continue
            }
            let position = rules.count
            rules.append(rule)
            patterns.append(Pattern(rule))
            quick.append(Quick(rule))
            if rule.wholePage {
                if rule.domains.isEmpty, rule.notDomains.isEmpty, rule.thirdParty == nil,
                   let host = AddressRule(pattern: rule.pattern, hostAnchored: rule.hostAnchored,
                                          endAnchored: rule.endAnchored).plainHost {
                    wholePageHosts.insert(host)
                } else {
                    wholePages.append(position)
                }
                continue
            }
            let tokens = candidates[index]
            let usable = tokens.filter { !Self.common.contains($0) }
            let token = (usable.isEmpty ? tokens : usable).min {
                (frequency[$0] ?? 0, -$0.count) < (frequency[$1] ?? 0, -$1.count)
            } ?? ""
            if rule.isException {
                exceptions[Token.hash(token), default: []].append(position)
            } else {
                blocks[Token.hash(token), default: []].append(position)
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(lines: try container.decode([String].self, forKey: .lines))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lines, forKey: .lines)
    }

    public static func == (a: AddressRules, b: AddressRules) -> Bool { a.lines == b.lines }

    public var count: Int { lines.count }

    /// Whether the host, or a name above it (never its last label alone), is
    /// in the set.
    static func host(_ host: String, in set: Set<String>) -> Bool {
        guard !set.isEmpty else { return false }
        var rest = Substring(host)
        while let dot = rest.firstIndex(of: ".") {
            if set.contains(String(rest)) { return true }
            rest = rest[rest.index(after: dot)...]
        }
        return false
    }

    /// Tokens every address has: a rule goes under one only when it has no
    /// other.
    static let common: Set<String> = ["http", "https", "www", "com", "js", "net", "org", "html", "php", "png", "jpg",
                                      "gif"]

    /// The tokens a rule could be indexed by: the runs of letters and digits
    /// in its pattern that an address matching it holds whole, bounded by a
    /// separator or an anchor on both sides, never by a `*`; two letters at
    /// least.
    static func tokens(of rule: AddressRule) -> [String] {
        let pattern = Array(rule.pattern.lowercased().utf8)
        var tokens: [String] = []
        var index = 0
        while index < pattern.count {
            guard Pattern.isTokenByte(pattern[index]) else { index += 1; continue }
            let start = index
            while index < pattern.count, Pattern.isTokenByte(pattern[index]) { index += 1 }
            let before = start == 0 ? (rule.hostAnchored || rule.startAnchored) : pattern[start - 1] != UInt8(ascii: "*")
            let after = index == pattern.count ? rule.endAnchored : pattern[index] != UInt8(ascii: "*")
            guard before, after, index - start >= 2 else { continue }
            tokens.append(String(decoding: pattern[start..<index], as: UTF8.self))
        }
        return tokens
    }

    /// Whether the request is to be refused: a rule refuses it, and no
    /// exception lets it through (an important rule only an important one).
    public func refuses(_ request: AddressRequest) -> Bool {
        guard request.kind != .document else { return false }
        let address = Address(request.url)
        let tokens = address.tokens
        // The page's names, worked out only for a rule that asks.
        var names: [String]?
        func pageNames() -> [String] {
            if let names { return names }
            names = request.pageHost.map(PageRules.lookupNames(for:)) ?? []
            return names!
        }
        var refused = Self.host(request.host, in: hosts)
        var important = false
        let kind = request.kind.rawValue
        let party: Int8 = request.isThirdParty.map { $0 ? 1 : 0 } ?? -1
        /// Whether the rule applies: what's quick first, then its pages and
        /// its pattern.
        func applies(_ position: Int, _ check: Quick) -> Bool {
            guard check.kinds & kind != 0, check.party < 0 || check.party == party else { return false }
            if check.hasDomains, !rules[position].optionsHold(for: request, pageNames: pageNames) { return false }
            return patterns[position].matches(address)
        }
        search: for token in tokens {
            for position in blocks[token] ?? [] {
                let check = quick[position]
                // Once refused, only an important rule says more.
                if refused && !check.important { continue }
                guard applies(position, check) else { continue }
                refused = true
                if check.important {
                    important = true
                    break search
                }
            }
        }
        guard refused else { return false }
        for token in tokens {
            for position in exceptions[token] ?? [] {
                let check = quick[position]
                if important && !check.important { continue }
                if applies(position, check) { return false }
            }
        }
        if important { return true }
        if let pageHost = request.pageHost {
            if Self.host(pageHost, in: wholePageHosts) { return false }
            if !wholePages.isEmpty {
                let page = Address("https://" + pageHost + "/")
                for position in wholePages where patterns[position].matches(page) { return false }
            }
        }
        return true
    }
}
