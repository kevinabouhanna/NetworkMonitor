import Foundation

/// Names as site rules use them (#197): a rule for `wp.com` covers `wp.com`
/// and every name under it, such as `stats.wp.com`.
public enum SiteName {

    /// A host name as rules key it: lowercase, without a trailing dot. Nil
    /// for an address, which a server rule covers instead.
    public static func normalized(_ name: String) -> String? {
        let trimmed = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !trimmed.isEmpty, trimmed.contains("."), !isAddress(trimmed) else { return nil }
        return trimmed
    }

    /// The name and each domain above it, narrowest first: `a.stats.wp.com`,
    /// `stats.wp.com`, `wp.com`. Never a bare suffix such as `com` or `co.uk`.
    public static func domains(of name: String) -> [String] {
        guard let name = normalized(name) else { return [] }
        let labels = name.split(separator: ".")
        let site = self.site(of: name)
        var domains: [String] = []
        for start in labels.indices {
            let domain = labels[start...].joined(separator: ".")
            domains.append(domain)
            if domain == site { break }
        }
        return domains
    }

    /// The site a name belongs to: its registrable domain, as a person would
    /// say it. `stats.wp.com` is on `wp.com`, `news.bbc.co.uk` on `bbc.co.uk`,
    /// `moph.gov.lb` on itself. A name that is itself a public suffix is its
    /// own site.
    public static func site(of name: String) -> String {
        guard let name = normalized(name) else { return name }
        let labels = name.split(separator: ".").map(String.init)
        // The longest public suffix decides: the first, from the left, that's
        // one. An exception is a site itself, one label under its suffix.
        for start in labels.indices {
            let candidate = labels[start...].joined(separator: ".")
            if suffixes.exceptions.contains(candidate) { return candidate }
            let wildcard = start + 1 < labels.count
                && suffixes.wildcards.contains(labels[(start + 1)...].joined(separator: "."))
            if suffixes.rules.contains(candidate) || wildcard {
                return start == 0 ? name : labels[(start - 1)...].joined(separator: ".")
            }
        }
        // No rule: the last label is the suffix, as the list's default says.
        return labels.suffix(2).joined(separator: ".")
    }

    /// The Public Suffix List (#318), the one browsers use for cookies: where
    /// people register names, such as `co.uk`, `gov.lb` and `myshopify.com`,
    /// with its private section of hosting platforms. Read once, when a site
    /// is first asked for.
    static let suffixes: (rules: Set<String>, wildcards: Set<String>, exceptions: Set<String>) = {
        var rules = Set<String>(), wildcards = Set<String>(), exceptions = Set<String>()
        for line in publicSuffixRules.split(separator: "\n") {
            let rule = line.trimmingCharacters(in: .whitespaces)
            if rule.hasPrefix("!") {
                exceptions.insert(String(rule.dropFirst()))
            } else if rule.hasPrefix("*.") {
                wildcards.insert(String(rule.dropFirst(2)))
            } else if !rule.isEmpty {
                rules.insert(rule)
            }
        }
        return (rules.union(extraSuffixes), wildcards, exceptions)
    }()

    /// Hosting platforms the list leaves out, where each customer's name is
    /// still its own site: `someone.wordpress.com` is someone's blog.
    static let extraSuffixes: Set<String> = ["wordpress.com", "amazonaws.com"]

    static func isAddress(_ text: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return text.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
}
