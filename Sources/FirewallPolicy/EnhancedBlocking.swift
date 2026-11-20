import Foundation

// Which connections Enhanced ad blocking opens (#684, a step of #256). The
// transparent proxy asks this for each new connection, before anything is
// read: open it, leave it alone, or (for a browser's QUIC) refuse it so the
// browser uses TCP, where the page can be read. Pure Foundation, so the app
// that keeps the settings and the filter that applies them agree, and every
// rule is tested without a system extension.

/// Enhanced ad blocking's settings, as the app sends them to the filter.
public struct EnhancedBlocking: Codable, Equatable {
    /// Off until the person switches it on, and the root certificate is
    /// trusted.
    public var isOn: Bool
    /// Apps the person adds to the browsers, and browsers they take away, by
    /// signing identifier. Only their own choices are kept, so a change to
    /// the browsers' list reaches everyone.
    public var addedApps: Set<String>
    public var removedApps: Set<String>
    /// Sites the person keeps it away from, each with every name under it.
    public var excludedSites: Set<String> {
        didSet { excludedSites = Set(excludedSites.compactMap(SiteName.normalized)) }
    }
    /// Apps found to refuse our certificate (they pin their own): left alone
    /// for good, by signing identifier, their helpers too.
    public var pinnedApps: Set<String>
    /// The SHA-256 of the root the person approved (#685), so the filter
    /// knows to try it at once rather than at its next retry.
    public var trustedRoot: String?

    public init(isOn: Bool = false, addedApps: Set<String> = [], removedApps: Set<String> = [],
                excludedSites: Set<String> = [], pinnedApps: Set<String> = [], trustedRoot: String? = nil) {
        self.isOn = isOn
        self.addedApps = addedApps
        self.removedApps = removedApps
        self.excludedSites = Set(excludedSites.compactMap(SiteName.normalized))
        self.pinnedApps = pinnedApps
        self.trustedRoot = trustedRoot
    }

    /// Settings saved by another version read with what they have: a field
    /// it didn't know is its default, never a reason to lose the rest.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(isOn: try container.decodeIfPresent(Bool.self, forKey: .isOn) ?? false,
                  addedApps: try container.decodeIfPresent(Set<String>.self, forKey: .addedApps) ?? [],
                  removedApps: try container.decodeIfPresent(Set<String>.self, forKey: .removedApps) ?? [],
                  excludedSites: try container.decodeIfPresent(Set<String>.self, forKey: .excludedSites) ?? [],
                  pinnedApps: try container.decodeIfPresent(Set<String>.self, forKey: .pinnedApps) ?? [],
                  trustedRoot: try container.decodeIfPresent(String.self, forKey: .trustedRoot))
    }

    // MARK: The apps it reaches, as Settings shows them (#685)

    /// The browsers as Settings lists them: each app once, its helpers
    /// (which load its pages) going with it.
    public static var browserApps: [String] {
        browsers.filter { browser in !browsers.contains { $0 != browser && family($0, includes: browser) } }.sorted()
    }

    /// Whether `other` is `app` or one of its helpers, whatever the case
    /// (Arc's helper is `company.thebrowser.browser.helper`); Chrome Canary
    /// is an app of its own.
    public static func family(_ app: String, includes other: String) -> Bool {
        let app = app.lowercased(), other = other.lowercased()
        return other == app || other.hasPrefix(app + ".helper")
    }

    /// Whether it reaches the app's pages.
    public func reaches(_ app: String) -> Bool {
        isOn(app, in: apps)
    }

    private func isOn(_ app: String, in set: Set<String>) -> Bool {
        set.contains { Self.family($0, includes: app) }
    }

    /// Reaches the app (and its helpers), or no longer does.
    public mutating func setReaches(_ app: String, _ on: Bool) {
        let family = Self.browsers.union(addedApps).union([app]).filter { Self.family(app, includes: $0) }
        if on {
            removedApps.subtract(family)
            if !Self.browsers.contains(where: { Self.family(app, includes: $0) }) { addedApps.insert(app) }
        } else {
            addedApps.subtract(family)
            removedApps.formUnion(family.intersection(Self.browsers))
        }
    }

    /// The apps the person added, in Settings' order.
    public var addedAppList: [String] { addedApps.sorted() }

    /// An app found to refuse the certificate is tried again (Try Again).
    public mutating func forgetPinned(_ app: String) {
        pinnedApps = pinnedApps.filter { !Self.family(app, includes: $0) && !Self.family($0, includes: app) }
    }

    /// The apps it reaches: the browsers, the person's own added, theirs
    /// taken away.
    public var apps: Set<String> { Self.browsers.union(addedApps).subtracting(removedApps) }

    /// The browsers it reaches by default, by the signing identifier of the
    /// app a connection is made for (the filter's app audit token): Safari's
    /// pages, though loaded by WebKit's shared networking process, count as
    /// Safari's, and no other app's web views are reached. Firefox keeps its
    /// own certificates, so it's added only once the person has told it to
    /// use the Mac's.
    public static let browsers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome", "com.google.Chrome.helper", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "com.microsoft.edgemac.helper",
        "com.brave.Browser", "com.brave.Browser.helper",
        "company.thebrowser.Browser", "company.thebrowser.browser.helper",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    public enum Decision: Equatable {
        /// Open it: read the page, remove the ads, pass it on.
        case open
        /// Leave it alone, for this reason.
        case leave(Reason)
        /// A browser's QUIC: refused, so the browser uses TCP.
        case refuseQUIC
    }

    public enum Reason: Equatable {
        case off
        case notAnAppItReaches
        case notWeb
        case neverOpened
        case excluded
        case pinned
        case noName
    }

    /// For a new connection made for `app` (its signing identifier) to
    /// `host` (the name it asked for, if known) on `port`.
    ///
    /// A browser's QUIC with no name is refused too: refusing opens nothing,
    /// and the TCP connection the browser falls back to is decided by its
    /// name, so a bank's is still left alone.
    public func decide(app: String?, host: String?, port: Int, isUDP: Bool) -> Decision {
        guard isOn else { return .leave(.off) }
        guard let app, Self.matches(app, in: apps) else { return .leave(.notAnAppItReaches) }
        guard port == 443 else { return .leave(.notWeb) }
        if Self.matches(app, in: pinnedApps) { return .leave(.pinned) }
        // An address, or no name: there's no certificate to show for it.
        let name = host.flatMap(SiteName.normalized)
        if let name {
            if Self.isNeverOpened(name) { return .leave(.neverOpened) }
            if isExcluded(name) { return .leave(.excluded) }
        }
        // QUIC can't be read: refused, so the browser falls back to TCP, as
        // it does whenever QUIC is blocked.
        if isUDP { return .refuseQUIC }
        return name == nil ? .leave(.noName) : .open
    }

    /// The port the transparent proxy takes connections to (#702): HTTPS's,
    /// over TCP and, to refuse it, QUIC.
    public static let proxiedPort = 443

    /// What the transparent proxy does as a TCP connection opens, before a
    /// byte is read (#702): leave it, or take it and read the name its
    /// handshake asks for, then `decide` with that name. A browser that
    /// connects by address (Chrome looks names up itself) has no name yet,
    /// so it's taken; with the name, it may still be left, its bytes passed
    /// on unchanged.
    public enum Start: Equatable {
        case leave(Reason)
        case readName
    }

    public func start(app: String?, host: String?, port: Int) -> Start {
        switch decide(app: app, host: host, port: port, isUDP: false) {
        case .open, .leave(.noName): return .readName
        case .leave(let reason): return .leave(reason)
        case .refuseQUIC: return .leave(.notWeb)
        }
    }

    /// The app, or a helper of one: its identifier, or one it starts with
    /// (`com.google.Chrome.helper.renderer` is Chrome's).
    public static func matches(_ app: String, in apps: Set<String>) -> Bool {
        apps.contains { family($0, includes: app) }
    }

    /// Whether a request inside an opened page is answered empty (#699):
    /// its rules by address refuse it, on a page it knows, never on one it
    /// doesn't open or the person excludes, so a bank's page keeps all it
    /// asks for, and a page it can't tell keeps it too.
    public func refuses(_ request: AddressRequest, by rules: AddressRules) -> Bool {
        guard let page = request.pageHost, !Self.isNeverOpened(page), !isExcluded(page) else { return false }
        return rules.refuses(request)
    }

    /// Excluded: the name, or any name above it (a platform's too, such as
    /// `github.io`), is in the person's list.
    public func isExcluded(_ name: String) -> Bool {
        Self.namesAbove(name).contains { excludedSites.contains($0) }
    }

    /// The name and every name above it but the last label.
    static func namesAbove(_ name: String) -> [String] {
        let labels = name.split(separator: ".")
        return (0..<max(labels.count - 1, 0)).map { labels[$0...].joined(separator: ".") }
    }

    // MARK: Never opened

    /// Banking, health, government and payment sites: never opened, whatever
    /// the settings, as the issue promises (#256). By the kind of name (a
    /// government's, a bank's own top-level domain), and a list of the
    /// largest sites of each kind; a site missing here can be excluded by
    /// hand.
    public static func isNeverOpened(_ host: String) -> Bool {
        guard let name = SiteName.normalized(host) else { return true }
        let labels = name.split(separator: ".").map(String.init)
        guard let last = labels.last else { return true }
        if ["gov", "mil", "bank", "insurance", "health", "bnpparibas"].contains(last) { return true }
        // A country's government's names: gov.uk, gouv.fr, gob.mx, go.jp,
        // gc.ca, gouv.qc.ca…, never go.com.
        if last.count == 2, labels.count >= 2 {
            if labels[labels.count - 2] == "go" || labels[labels.count - 2] == "nhs" { return true }
            if labels.dropLast().contains(where: { ["gov", "gouv", "gob", "govt", "gc", "mil"].contains($0) }) {
                return true
            }
        }
        return namesAbove(name).contains { neverOpenedSites.contains($0) }
    }

    /// The largest banking, payment, health and tax sites, each with every
    /// name under it.
    public static let neverOpenedSites: Set<String> = [
        // Payment
        "paypal.com", "paypal.me", "stripe.com", "squareup.com", "wise.com", "revolut.com", "klarna.com",
        "paypalobjects.com", "venmo.com", "cash.app", "zellepay.com", "adyen.com", "braintreegateway.com", "checkout.com",
        "apple.com", "icloud.com", "pay.google.com", "payments.google.com", "accounts.google.com",
        "login.microsoftonline.com", "login.live.com", "appleid.apple.com",
        // Banks
        "chase.com", "bankofamerica.com", "wellsfargo.com", "citi.com", "citibank.com", "usbank.com",
        "capitalone.com", "pnc.com", "tdbank.com", "americanexpress.com", "discover.com", "schwab.com",
        "fidelity.com", "vanguard.com", "hsbc.com", "hsbc.co.uk", "barclays.co.uk", "lloydsbank.com",
        "natwest.com", "santander.com", "santander.co.uk", "societegenerale.fr",
        "credit-agricole.fr", "deutsche-bank.de", "commerzbank.de", "ing.com", "ing.nl", "rabobank.nl",
        "ubs.com", "credit-suisse.com", "unicredit.it", "intesasanpaolo.com", "bbva.com", "caixabank.es",
        "rbc.com", "td.com", "scotiabank.com", "bmo.com", "commbank.com.au", "westpac.com.au", "anz.com",
        "nab.com.au", "icicibank.com", "hdfcbank.com", "sbi.co.in", "dbs.com", "ocbc.com", "uob.com.sg",
        "mufg.jp", "smbc.co.jp", "bankaudi.com.lb", "blombank.com", "byblosbank.com",
        // Health
        "mychart.com", "epic.com", "kp.org", "healthcare.gov", "doctolib.fr", "doctolib.de",
        "zocdoc.com", "teladoc.com", "cvs.com", "walgreens.com", "unitedhealthcare.com", "anthem.com",
        "aetna.com", "cigna.com", "humana.com",
        // Tax and identity
        "id.me", "turbotax.intuit.com", "hrblock.com",
        // Governments whose names aren't gov.xx
        "canada.ca", "europa.eu", "admin.ch", "bund.de", "service-public.fr", "gov.uk",
    ]
}
