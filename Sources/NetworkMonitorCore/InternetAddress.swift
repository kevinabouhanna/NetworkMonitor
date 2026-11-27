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
            generation += 1
            askedHere = false
            if isEnabled { ask(again: true) } else if mine == nil { state = .notAsked }
        }
    }
    /// This Mac's address on the network in use, nil while offline.
    @Published public private(set) var local: String?
    @Published public private(set) var state: State = .notAsked

    public struct Sources {
        /// This Mac's addresses on the primary interface: IPv4 first.
        public var addresses: () -> [String]
        /// The public IPv4 address the Mac holds itself on Wi-Fi or Ethernet,
        /// when it has one: then that's what websites see, and nobody is
        /// asked. Never an IPv6 one, which isn't the address the Mac uses
        /// for what it sends (macOS uses a temporary one), nor a VPN's.
        public var ownPublicAddress: () -> String?
        /// Whether this network may be asked over: not a hotspot, metered or
        /// in Low Data Mode, and not offline.
        public var mayAsk: () -> Bool
        /// The service's answer, as text, or nil.
        public var fetch: (URL, @escaping (String?) -> Void) -> Void
        /// Country and owner, from the app's DB-IP data. Called off the main
        /// thread: the tables are opened the first time.
        public var place: (IPAddress) -> ServerInfo?

        public init(addresses: @escaping () -> [String], ownPublicAddress: @escaping () -> String? = { nil },
                    mayAsk: @escaping () -> Bool,
                    fetch: @escaping (URL, @escaping (String?) -> Void) -> Void,
                    place: @escaping (IPAddress) -> ServerInfo?) {
            self.addresses = addresses
            self.ownPublicAddress = ownPublicAddress
            self.mayAsk = mayAsk
            self.fetch = fetch
            self.place = place
        }
    }

    private let sources: Sources
    private let defaults: UserDefaults?
    private let placing = DispatchQueue(label: "com.networkmonitor.addresses")  // untranslated: queue label
    /// Bumped on every network change and switch, so an answer about the
    /// last network is never shown on this one.
    private var generation = 0
    /// The Mac's own public address, when it holds one.
    private var mine: String?
    /// What's been asked on this network already: once per network.
    private var askedHere = false
    /// The network asked about, so a blip offline or a wake on the same one
    /// doesn't ask again.
    private var network: String?

    public init(sources: Sources, defaults: UserDefaults? = nil) {
        self.sources = sources
        self.defaults = defaults
        isEnabled = defaults?.bool(forKey: Self.enabledKey) ?? false
    }

    /// The link changed: read this Mac's address again and, if on, ask for
    /// the internet address once on a network not asked about yet.
    public func networkDidChange(network id: String) {
        if id != network {
            network = id
            generation += 1
            askedHere = false
            // Whatever was asked, or is being asked, was about the last one.
            if case .found(let answer) = state, answer.isTheMacs {} else { state = .notAsked }
        }
        read()
        settle()
    }

    /// Whether the network is a hotspot changed, by hand or by the app: what
    /// may be asked changes with it.
    public func verdictDidChange() {
        settle()
    }

    /// Reads this Mac's address again, without asking anyone.
    public func read() {
        let first = sources.addresses().first
        if local != first { local = first }
        let own = sources.ownPublicAddress()
        guard own != mine else { return }
        mine = own
        if let own {
            found(own, isTheMacs: true)
        } else if case .found(let answer) = state, answer.isTheMacs {
            state = .notAsked
            settle()
        }
    }

    #if DEBUG
    /// For DesignShots' pictures: addresses that aren't this Mac's.
    public func showForPictures(local: String?, state: State) {
        generation += 1
        self.local = local
        self.state = state
    }
    #endif

    /// **Show**, and Try Again: turns the lookup on, and asks.
    public func show() {
        if isEnabled { ask(again: true) } else { isEnabled = true }
    }

    /// What should show now, asking once if it's on and may.
    private func settle() {
        if mine != nil { return }
        guard isEnabled else {
            state = .notAsked
            return
        }
        guard sources.mayAsk() else {
            state = .notHere
            return
        }
        if state == .notHere || state == .notAsked { ask() }
    }

    private func ask(again: Bool = false) {
        if let mine {
            found(mine, isTheMacs: true)
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
                guard let address = text.flatMap(Self.address(inTrace:)) else {
                    self.state = .failed
                    return
                }
                self.found(address, isTheMacs: false)
            }
        }
    }

    /// Shows an address at once, then where it is once the tables say.
    private func found(_ address: String, isTheMacs: Bool) {
        state = .found(Answer(address: address, country: nil, provider: nil, isTheMacs: isTheMacs))
        guard let parsed = IPAddress(address) else { return }
        let asked = generation
        let place = sources.place
        placing.async { [weak self] in
            let info = place(parsed)
            DispatchQueue.main.async {
                guard let self, self.generation == asked,
                      case .found(let shown) = self.state, shown.address == address else { return }
                self.state = .found(Answer(address: address, country: info?.country,
                                           provider: info?.owner?.company.name, isTheMacs: isTheMacs))
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
        Self(
            addresses: { MacAddresses.primaryAddresses() },
            ownPublicAddress: { MacAddresses.ownPublicIPv4() },
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
            place: { PlaceTables.shared.lookup($0) })
    }
}

/// The DB-IP tables the internet address is placed with: opened the first
/// time they're needed, and again after the monthly update (#121).
public final class PlaceTables {
    public static let shared = PlaceTables()
    private let lock = NSLock()
    private var directory: ServerDirectory?
    private var opened = false

    func lookup(_ address: IPAddress) -> ServerInfo? {
        lock.lock()
        defer { lock.unlock() }
        if !opened {
            opened = true
            directory = ServerDirectory.newest(downloaded: GeoDataUpdater.downloadedDirectory)?.directory
        }
        return directory?.lookup(address)
    }

    /// New tables arrived: open them next time.
    public func invalidate() {
        lock.lock()
        opened = false
        directory = nil
        lock.unlock()
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

    /// The public IPv4 address Wi-Fi or Ethernet holds, when the Mac is on
    /// the internet as itself, with no router translating.
    public static func ownPublicIPv4() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "NetworkMonitor" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let interface = global["PrimaryInterface"] as? String,
              LowDataMode.isPhysicalInterface(interface),
              let state = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(interface)/IPv4" as CFString)
                as? [String: Any],
              let addresses = state["Addresses"] as? [String] else { return nil }
        return addresses.first { IPAddress($0).map(isPublic) ?? false }
    }
}
