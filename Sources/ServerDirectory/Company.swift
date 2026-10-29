import Foundation

/// The company a network belongs to, named the way a person would say it.
///
/// Until the content filter can read server names (#115), the network's
/// registered owner is the only clue to whose server an address is. That's
/// accurate for companies that run their own networks, such as Google,
/// Microsoft, Meta and Apple. It says nothing about the thousands of companies
/// that rent servers from someone else, so those networks are marked as hosts:
/// traffic to Amazon's network went to *something hosted on Amazon*, not
/// necessarily to Amazon.
public struct Company: Hashable {
    public let name: String
    /// True for clouds, content delivery networks and security proxies, which
    /// carry other companies' traffic.
    public let isHost: Bool
    /// True for networks that answer one address from many places at once
    /// (anycast), such as Cloudflare's. The database files each address under
    /// one country, but the server that answered was usually the nearest, so
    /// the map lists their traffic beside it rather than painting that country.
    public let answersEverywhere: Bool

    public init(name: String, isHost: Bool, answersEverywhere: Bool = false) {
        self.name = name
        self.isHost = isHost
        self.answersEverywhere = answersEverywhere
    }

    /// The company owning `asn`, registered as `registeredName`.
    public static func owning(asn: UInt32, registeredName: String) -> Company {
        if let company = byNetwork[asn] { return company }
        let lowered = registeredName.lowercased()
        for (pattern, company) in byName where lowered.containsWord(pattern) {
            return company
        }
        let name = plainName(registeredName)
        return Company(name: name.isEmpty ? "AS\(asn)" : name, isHost: false)
    }

    /// Networks whose registered name says less than their number. Google
    /// Cloud is registered as "Google LLC", like Google's own network, but it
    /// hosts other companies.
    static let byNetwork: [UInt32: Company] = [
        396982: Company(name: "Google", isHost: true),
    ]

    /// First match wins, so the more specific pattern of a pair comes first.
    /// Patterns match whole words: "amazon" finds "Amazon.com, Inc." and
    /// "Amazon Data Services Ireland Ltd", not the Brazilian ISP "Amazonas".
    static let byName: [(String, Company)] = [
        // Hosts: their traffic belongs to their customers as much as to them.
        ("amazon", Company(name: "Amazon", isHost: true)),
        ("akamai", Company(name: "Akamai", isHost: true)),
        ("cloudflare", Company(name: "Cloudflare", isHost: true, answersEverywhere: true)),
        ("fastly", Company(name: "Fastly", isHost: true, answersEverywhere: true)),
        ("oracle", Company(name: "Oracle", isHost: true)),
        ("the constant company", Company(name: "Vultr", isHost: true)),
        ("ovh", Company(name: "OVHcloud", isHost: true)),
        ("leaseweb", Company(name: "Leaseweb", isHost: true)),
        ("digitalocean", Company(name: "DigitalOcean", isHost: true)),
        ("hetzner", Company(name: "Hetzner", isHost: true)),
        ("alibaba", Company(name: "Alibaba", isHost: true)),
        ("tencent", Company(name: "Tencent", isHost: true)),
        ("huawei", Company(name: "Huawei", isHost: true)),
        ("zscaler", Company(name: "Zscaler", isHost: true)),
        ("bunnyway", Company(name: "bunny.net", isHost: true, answersEverywhere: true)),
        ("edgecast", Company(name: "Edgecast", isHost: true, answersEverywhere: true)),
        ("imperva", Company(name: "Imperva", isHost: true, answersEverywhere: true)),
        ("yandex.cloud", Company(name: "Yandex", isHost: true)),
        // Companies on their own networks, under the name people know.
        ("google", Company(name: "Google", isHost: false)),
        ("microsoft", Company(name: "Microsoft", isHost: false)),
        ("facebook", Company(name: "Meta", isHost: false)),
        ("meta platforms", Company(name: "Meta", isHost: false)),
        ("apple inc", Company(name: "Apple", isHost: false)),
        ("bytedance", Company(name: "ByteDance", isHost: false)),
        ("netflix", Company(name: "Netflix", isHost: false)),
        ("zoom video", Company(name: "Zoom", isHost: false)),
        ("yandex", Company(name: "Yandex", isHost: false)),
    ]

    /// "Microsoft Corporation" → "Microsoft": the registered name without the
    /// legal form that follows it.
    public static func plainName(_ registered: String) -> String {
        var words = registered.split(separator: " ").map(String.init)
        while words.count > 1,
              let last = words.last,
              legalForms.contains(last.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",")))
        {
            words.removeLast()
        }
        var name = words.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ", ").union(.whitespaces))
        // Some are registered in capitals ("LIBANTELECOM"). Long words read
        // better as words; short ones stay, as they're usually acronyms (UK, SKY).
        if name == name.uppercased(), name.contains(where: \.isLetter) {
            name = name.split(separator: " ")
                .map { $0.count > 4 ? $0.capitalized : String($0) }
                .joined(separator: " ")
        }
        return name.isEmpty ? registered : name
    }

    static let legalForms: Set<String> = [
        "inc", "inc.", "incorporated", "llc", "l.l.c.", "ltd", "ltd.", "limited",
        "corporation", "corp", "corp.", "co", "co.", "company", "plc", "llp", "lp", "l.p.",
        "gmbh", "ag", "b.v.", "bv", "n.v.", "nv", "s.a.", "sa", "sas", "s.a.s.", "sarl",
        "s.l.", "sl", "s.r.l.", "srl", "s.p.a.", "spa", "pte", "pte.", "pty", "k.k.",
        "d.o.o.", "ab", "oy", "a/s", "as", "s.a.l.", "sal", "s.a.r.l.", "pbc", "p.b.c.",
    ]
}

private extension String {
    /// True when `word` appears with no letter or digit on either side.
    func containsWord(_ word: String) -> Bool {
        var searchStart = startIndex
        while let found = range(of: word, range: searchStart..<endIndex) {
            let before = found.lowerBound == startIndex ? nil : self[index(before: found.lowerBound)]
            let after = found.upperBound == endIndex ? nil : self[found.upperBound]
            if !(before?.isLetter ?? false) && !(before?.isNumber ?? false)
                && !(after?.isLetter ?? false) && !(after?.isNumber ?? false) {
                return true
            }
            searchStart = index(after: found.lowerBound)
        }
        return false
    }
}
