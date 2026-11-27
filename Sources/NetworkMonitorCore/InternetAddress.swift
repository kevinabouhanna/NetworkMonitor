import Foundation
import LowDataMode
import ServerDirectory
import SystemConfiguration

/// The Mac's addresses, for the popover's Network view (#803): this Mac's on
/// the network it's on, read from the Mac itself, and the internet address
/// websites see, with its country and provider.
///
/// Behind a home router the internet address is the router's, which only an
/// outside service can tell. So it's asked for only once you've said so:
/// **Show** in the popover, or **Look up the internet address** in Network's
/// settings; then once per network, and never on a hotspot, a metered
/// connection or in Low Data Mode, as the country data isn't downloaded there
/// (#121). The answer is kept in memory only. Its country and provider come
/// from the DB-IP data already in the app: placing it sends nothing.
public final class InternetAddress: ObservableObject {
    /// What websites see, and where that is.
    public struct Answer: Equatable {
        public let address: String
        /// An ISO region code, as DB-IP files it.
        public let country: String?
        public let provider: String?
        /// The Mac holds this address itself: nothing was asked.
        public let isTheMacs: Bool

        public init(address: String, country: String?, provider: String?, isTheMacs: Bool) {
            self.address = address
            self.country = country
            self.provider = provider
            self.isTheMacs = isTheMacs
        }
    }

    public enum State: Equatable {
        /// Not asked for: switched off, or nothing asked yet on this network.
        case notAsked
        case asking
        case found(Answer)
        /// The service didn't answer, or not with an address.
        case failed
        /// Switched on, but this network is a hotspot, metered or in Low Data
        /// Mode: nothing is asked here.
        case notHere
    }

    /// Where it's asked: Cloudflare's trace, which answers with the address
    /// and nothing about you, with no account and no key.
    public static let service = URL(string: "https://one.one.one.one/cdn-cgi/trace")!
    static let enabledKey = "lookUpInternetAddress"

    /// Off until you turn it on.
    @Published public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults?.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { ask() } else { generation += 1; state = mine.map(State.found) ?? .notAsked }
        }
    }
    /// This Mac's address on the network in use, nil while offline.
    @Published public private(set) var local: String?
    @Published public private(set) var state: State = .notAsked

    public struct Sources {
        /// This Mac's addresses on the primary interface: IPv4 first.
        public var addresses: () -> [String]
        /// Whether this network may be asked over: not a hotspot, metered or
        /// in Low Data Mode, and not offline.
        public var mayAsk: () -> Bool
        /// The service's answer, as text, or nil.
        public var fetch: (URL, @escaping (String?) -> Void) -> Void
        /// Country and owner, from the app's DB-IP data.
        public var place: (IPAddress) -> ServerInfo?

        public init(addresses: @escaping () -> [String], mayAsk: @escaping () -> Bool,
                    fetch: @escaping (URL, @escaping (String?) -> Void) -> Void,
                    place: @escaping (IPAddress) -> ServerInfo?) {
            self.addresses = addresses
            self.mayAsk = mayAsk
            self.fetch = fetch
            self.place = place
        }
    }

    private let sources: Sources
    private let defaults: UserDefaults?
    /// Bumped on every network change, so an answer about the last one is
    /// never shown on this one.
    private var generation = 0
    /// The Mac's own public address, when it holds one.
    private var mine: Answer?
    /// What's been asked on this network already: once per network.
    private var askedHere = false

    public init(sources: Sources, defaults: UserDefaults? = nil) {
        self.sources = sources
        self.defaults = defaults
        isEnabled = defaults?.bool(forKey: Self.enabledKey) ?? false
    }

    /// The network changed, or the popover opened on a new one: read this
    /// Mac's address again, and ask for the internet address once, if on.
    public func networkDidChange() {
        generation += 1
        askedHere = false
        read()
        state = mine.map(State.found) ?? .notAsked
        if isEnabled { ask() }
    }

    /// Reads this Mac's address again, without asking anyone.
    public func read() {
        let addresses = sources.addresses()
        let found = addresses.first
        if local != found { local = found }
        mine = addresses.compactMap { text -> Answer? in
            guard let address = IPAddress(text), MacAddresses.isPublic(address) else { return nil }
            let info = sources.place(address)
            return Answer(address: text, country: info?.country, provider: info?.owner?.company.name, isTheMacs: true)
        }.first
    }

    #if DEBUG
    /// For DesignShots' pictures: addresses that aren't this Mac's.
    public func showForPictures(local: String?, state: State) {
        self.local = local
        self.state = state
    }
    #endif

    /// **Show**: turns the lookup on, which asks.
    public func show() {
        if isEnabled { ask(again: true) } else { isEnabled = true }
    }

    private func ask(again: Bool = false) {
        if let mine {
            state = .found(mine)
            return
        }
        guard sources.mayAsk() else {
            state = .notHere
            return
        }
        guard again || !askedHere else { return }
        askedHere = true
        state = .asking
        let asked = generation
        sources.fetch(Self.service) { [weak self] text in
            DispatchQueue.main.async {
                guard let self, self.generation == asked, self.isEnabled else { return }
                guard let address = text.flatMap(Self.address(inTrace:)), let parsed = IPAddress(address) else {
                    self.state = .failed
                    return
                }
                let info = self.sources.place(parsed)
                self.state = .found(Answer(address: address, country: info?.country,
                                           provider: info?.owner?.company.name, isTheMacs: false))
            }
        }
    }

    /// The `ip=` line of Cloudflare's trace.
    public static func address(inTrace text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("ip=") {
            let value = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            return IPAddress(value) == nil ? nil : value
        }
        return nil
    }
}

extension InternetAddress.Sources {
    /// The real ones: the primary interface's addresses from configd, a
    /// request with no cookies or cache, and the app's DB-IP data.
    public static func live(mayAsk: @escaping () -> Bool) -> Self {
        var directory: ServerDirectory?
        var opened = false
        return Self(
            addresses: { MacAddresses.primaryAddresses() },
            mayAsk: mayAsk,
            fetch: { url, done in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 10
                configuration.httpCookieStorage = nil
                configuration.urlCache = nil
                let session = URLSession(configuration: configuration)
                session.dataTask(with: url) { data, response, _ in
                    let ok = (response as? HTTPURLResponse)?.statusCode == 200
                    done(ok ? data.flatMap { String(data: $0, encoding: .utf8) } : nil)
                    session.finishTasksAndInvalidate()
                }.resume()
            },
            place: { address in
                if !opened {
                    opened = true
                    directory = ServerDirectory.newest(downloaded: GeoDataUpdater.downloadedDirectory)?.directory
                }
                return directory?.lookup(address)
            })
    }
}

extension MacAddresses {
    /// The primary interface's addresses as the Mac holds them, IPv4 first,
    /// link-local ones left out: what "This Mac" shows.
    public static func primaryAddresses() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "NetworkMonitor" as CFString, nil, nil) else { return [] }
        var found: [String] = []
        for family in ["IPv4", "IPv6"] {
            guard let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/\(family)" as CFString)
                    as? [String: Any],
                  let interface = global["PrimaryInterface"] as? String,
                  let state = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(interface)/\(family)" as CFString)
                    as? [String: Any],
                  let addresses = state["Addresses"] as? [String] else { continue }
            found += addresses.filter { !$0.lowercased().hasPrefix("fe80") }
        }
        return found
    }
}
