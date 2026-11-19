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
    /// The apps whose connections it opens, by signing identifier: the
    /// browsers, and any app the person adds.
    public var apps: Set<String>
    /// Sites the person keeps it away from, each with the names under it.
    public var excludedSites: Set<String>
    /// Apps found to refuse our certificate (they pin their own): left alone
    /// for good, by signing identifier.
    public var pinnedApps: Set<String>

    public init(isOn: Bool = false, apps: Set<String> = EnhancedBlocking.browsers, excludedSites: Set<String> = [],
                pinnedApps: Set<String> = []) {
        self.isOn = isOn
        self.apps = apps
        self.excludedSites = excludedSites
        self.pinnedApps = pinnedApps
    }

    /// The browsers it reaches by default, by signing identifier. Firefox
    /// keeps its own certificates, so it's reached only once the person has
    /// told it to use the Mac's.
    public static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.WebKit.Networking",
        "com.google.Chrome", "com.google.Chrome.helper", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "com.microsoft.edgemac.helper",
        "com.brave.Browser", "com.brave.Browser.helper",
        "company.thebrowser.Browser", "company.thebrowser.browser.helper",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
        "org.mozilla.firefox",
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

    /// For a new connection from `app` (its signing identifier) to `host`
    /// (the name it asked for, if known) on `port`.
    public func decide(app: String?, host: String?, port: Int, isUDP: Bool) -> Decision {
        guard isOn else { return .leave(.off) }
        guard let app, reaches(app) else { return .leave(.notAnAppItReaches) }
        guard port == 443 else { return .leave(.notWeb) }
        if pinnedApps.contains(app) { return .leave(.pinned) }
        // QUIC can't be read: refused, so the browser falls back to TCP, as
        // it does whenever QUIC is blocked. Not for a site left alone.
        if let host, Self.isNeverOpened(host) || isExcluded(host) {
            return .leave(Self.isNeverOpened(host) ? .neverOpened : .excluded)
        }
        if isUDP { return .refuseQUIC }
        // With no name, there's no certificate to show for it: leave it.
        guard host != nil else { return .leave(.noName) }
        return .open
    }

    /// The app, or a helper of one: its identifier, or one it starts with
    /// (`com.google.Chrome.helper.renderer` is Chrome's).
    func reaches(_ app: String) -> Bool {
        apps.contains(app) || apps.contains { app.hasPrefix($0 + ".") }
    }

    func isExcluded(_ host: String) -> Bool {
        SiteName.domains(of: host).contains { excludedSites.contains($0) }
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
        // gov, mil, bank, insurance, and gov.xx, gouv.xx, gob.xx, govt.nz…
        guard let last = labels.last else { return true }
        if ["gov", "mil", "bank", "insurance", "health", "bnpparibas"].contains(last) { return true }
        // A country's government's names: gov.uk, gouv.fr, gob.mx, go.jp…,
        // never go.com.
        if last.count == 2, labels.count >= 2,
           ["gov", "gouv", "gob", "govt", "go", "mil", "nhs"].contains(labels[labels.count - 2]) {
            return true
        }
        return SiteName.domains(of: name).contains { neverOpenedSites.contains($0) }
    }

    /// The largest banking, payment, health and tax sites, each with every
    /// name under it.
    public static let neverOpenedSites: Set<String> = [
        // Payment
        "paypal.com", "paypal.me", "stripe.com", "squareup.com", "wise.com", "revolut.com", "klarna.com",
        "venmo.com", "cash.app", "zellepay.com", "adyen.com", "braintreegateway.com", "checkout.com",
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
        "mychart.com", "epic.com", "kp.org", "nhs.uk", "healthcare.gov", "doctolib.fr", "doctolib.de",
        "zocdoc.com", "teladoc.com", "cvs.com", "walgreens.com", "unitedhealthcare.com", "anthem.com",
        "aetna.com", "cigna.com", "humana.com",
        // Tax and identity
        "irs.gov", "hmrc.gov.uk", "id.me", "login.gov", "turbotax.intuit.com", "hrblock.com",
    ]
}
