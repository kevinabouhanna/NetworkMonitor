import Foundation
import LowDataMode
import ServerDirectory
import SystemConfiguration

/// The Mac's country: where the Connections map's lines start (#231).
///
/// The Region setting alone put a Mac in Lebanon set to United States in the
/// USA. So it's the first of three that knows, none of which sends anything
/// new off the Mac:
///
/// 1. **Location**, only when the app already has it for Wi-Fi names. It never
///    asks for it for this. The fix is turned into a country at once with the
///    map's own outlines (`WorldMap.country`), not Apple's reverse geocoding,
///    which would send the coordinates to Apple, and only the country is kept.
/// 2. **The Mac's internet address**, when the Mac itself holds one: an IPv6
///    address, or an IPv4 one with no router translating it. Placed with the
///    DB-IP data already in the app. Behind a home router, the usual case, the
///    address the internet sees is the router's, which only an outside service
///    could tell, so this step finds nothing rather than ask one.
/// 3. **The Region setting**, as before.
public struct HomeCountry: Equatable {

    public enum Source: Equatable {
        case location
        case internetAddress
        case region
    }

    /// ISO 3166-1 alpha-2, such as "LB".
    public let code: String
    public let source: Source

    public init(code: String, source: Source) {
        self.code = code
        self.source = source
    }

    /// The first source that names a country, in their order. A Region of
    /// "001" (the world) or "150" (Europe) names none.
    public static func first(location: String?, internetAddress: String?, region: String?) -> HomeCountry? {
        let sources: [(String?, Source)] = [(location, .location),
                                            (internetAddress, .internetAddress),
                                            (region, .region)]
        for case let (code?, source) in sources where isCountryCode(code) {
            return HomeCountry(code: code.uppercased(), source: source)
        }
        return nil
    }

    static func isCountryCode(_ code: String) -> Bool {
        code.count == 2 && code.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) && $0.isASCII }
    }

    /// On hovering the starting point, and what VoiceOver reads: *Your Mac,
    /// in Lebanon (from Location)*.
    public func description(locale: Locale = .current) -> String {
        let name = ConnectionsReport.countryName(code, locale: locale)
        switch source {
        case .location:        return L("Your Mac, in %@ (from Location)", name)
        case .internetAddress: return L("Your Mac, in %@ (from its internet address)", name)
        case .region:          return L("Your Mac, in %@ (from your Mac's Region setting)", name)
        }
    }
}

/// Asks the sources and publishes the first that knows. The Region setting
/// answers at once, so the map has a starting point straight away; Location
/// and the address follow, and replace it when they know better.
public final class HomeCountryFinder: ObservableObject {

    /// Each answers on the main thread, once per call. Injected, so tests
    /// never touch Location.
    public struct Sources {
        /// The country Location places the Mac in, or nil when Location isn't
        /// allowed (it is never asked for) or can't tell.
        public var location: (@escaping (String?) -> Void) -> Void
        /// The country of an internet address the Mac itself holds, or nil.
        public var internetAddress: (@escaping (String?) -> Void) -> Void
        public var region: () -> String?

        public init(location: @escaping (@escaping (String?) -> Void) -> Void,
                    internetAddress: @escaping (@escaping (String?) -> Void) -> Void,
                    region: @escaping () -> String?) {
            self.location = location
            self.internetAddress = internetAddress
            self.region = region
        }
    }

    @Published public private(set) var home: HomeCountry?

    private let sources: Sources
    private let now: () -> Date
    private var location: String?
    private var internetAddress: String?
    private var asked: Date?

    /// A Mac moves between countries only with its owner, so asking once in a
    /// while is enough: here, each time the map is shown, at most every ten
    /// minutes.
    public static let interval: TimeInterval = 10 * 60

    public init(sources: Sources, now: @escaping () -> Date = Date.init) {
        self.sources = sources
        self.now = now
        publish()
    }

    /// Asks every source again, unless it was asked within `interval`. What
    /// they last said stands until they answer.
    public func refresh() {
        let time = now()
        if let asked, time.timeIntervalSince(asked) < Self.interval {
            publish()
            return
        }
        asked = time
        publish()
        sources.location { [weak self] code in
            self?.location = code
            self?.publish()
        }
        sources.internetAddress { [weak self] code in
            self?.internetAddress = code
            self?.publish()
        }
    }

    private func publish() {
        let found = HomeCountry.first(location: location, internetAddress: internetAddress,
                                      region: sources.region())
        if found != home { home = found }
    }
}

/// The Mac's own internet addresses: those of the interfaces carrying its
/// traffic, when the internet sees them as they are.
public enum MacAddresses {

    /// Public addresses on the primary interfaces, IPv6 first, from configd.
    /// Only Ethernet and Wi-Fi: a VPN's address says where the VPN is.
    public static func publicAddresses() -> [IPAddress] {
        guard let store = SCDynamicStoreCreate(nil, "NetworkMonitor" as CFString, nil, nil) else { return [] }
        var found: [IPAddress] = []
        for family in ["IPv6", "IPv4"] {
            guard let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/\(family)" as CFString)
                    as? [String: Any],
                  let interface = global["PrimaryInterface"] as? String,
                  LowDataMode.isPhysicalInterface(interface),
                  let state = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(interface)/\(family)" as CFString)
                    as? [String: Any],
                  let addresses = state["Addresses"] as? [String] else { continue }
            found += addresses.compactMap(IPAddress.init).filter(isPublic)
        }
        return found
    }

    /// Whether the internet would see this address as it is: not private,
    /// shared by a carrier's NAT, link-local, loopback or reserved.
    public static func isPublic(_ address: IPAddress) -> Bool {
        switch address {
        case .v4(let value):
            let notPublic: [(UInt32, Int)] = [
                (0x0000_0000, 8),    // 0.0.0.0/8, this network
                (0x0A00_0000, 8),    // 10.0.0.0/8, private
                (0x6440_0000, 10),   // 100.64.0.0/10, a carrier's NAT
                (0x7F00_0000, 8),    // 127.0.0.0/8, loopback
                (0xA9FE_0000, 16),   // 169.254.0.0/16, link-local
                (0xAC10_0000, 12),   // 172.16.0.0/12, private
                (0xC000_0000, 24),   // 192.0.0.0/24, protocol assignments
                (0xC0A8_0000, 16),   // 192.168.0.0/16, private
                (0xC612_0000, 15),   // 198.18.0.0/15, benchmarking
                (0xE000_0000, 3),    // 224.0.0.0/3, multicast and reserved
            ]
            return !notPublic.contains { prefix, length in
                value >> (32 - length) == prefix >> (32 - length)
            }
        case .v6(let value):
            let top = value.high >> 48
            // Global unicast is 2000::/3. Within it, Teredo (2001::/32),
            // documentation (2001:db8::/32) and 6to4 (2002::/16) say nothing
            // about where the Mac is.
            guard top >> 13 == 1 else { return false }
            let first32 = value.high >> 32
            return first32 != 0x2001_0000 && first32 != 0x2001_0DB8 && top != 0x2002
        }
    }
}
