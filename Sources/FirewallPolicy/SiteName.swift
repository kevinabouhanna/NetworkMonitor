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
    /// say it. `stats.wp.com` is on `wp.com`, `news.bbc.co.uk` on `bbc.co.uk`.
    public static func site(of name: String) -> String {
        guard let name = normalized(name) else { return name }
        let labels = name.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return name }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        let take = multiLabelSuffixes.contains(lastTwo) ? 3 : 2
        return labels.suffix(take).joined(separator: ".")
    }

    /// Suffixes under which people register names, where the site is one
    /// label further in. The common ones only, not the whole public suffix
    /// list: a name under a rarer one offers a narrower site, never a wider.
    static let multiLabelSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "net.uk", "ltd.uk", "plc.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au",
        "co.nz", "org.nz", "net.nz", "govt.nz",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp",
        "co.kr", "or.kr", "go.kr",
        "com.cn", "net.cn", "org.cn", "gov.cn",
        "com.hk", "com.tw", "com.sg", "com.my", "com.ph", "com.vn", "co.th", "co.id",
        "co.in", "net.in", "org.in", "gov.in",
        "com.br", "net.br", "org.br", "gov.br",
        "com.ar", "com.mx", "com.co", "com.pe", "com.uy",
        "co.za", "org.za", "gov.za",
        "com.tr", "gov.tr", "com.eg", "com.sa", "com.lb", "co.il", "org.il", "co.ke",
        "com.ua", "com.pl", "com.ru", "com.es", "com.pt", "co.at", "or.at", "com.gr",
        // Hosting platforms, where each customer's name is its own site.
        "github.io", "gitlab.io", "pages.dev", "workers.dev", "vercel.app", "netlify.app",
        "herokuapp.com", "appspot.com", "web.app", "firebaseapp.com", "azurewebsites.net",
        "cloudfront.net", "amazonaws.com", "blogspot.com", "wordpress.com", "fly.dev",
    ]

    static func isAddress(_ text: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return text.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
}
