import Foundation

/// Where an internet address is, and whose network it belongs to, from data
/// shipped inside the app. Nothing is looked up online.
///
/// Its own target, with nothing but Foundation, because two very different
/// processes need it: the app, to name the servers in the Connections window,
/// and later the content filter, which decides rules by company and country
/// for every new connection and must not link a menu bar app's frameworks.
public final class ServerDirectory {

    /// Shown wherever the data is: CC BY 4.0 asks for credit.
    public static let credit = "IP geolocation by DB-IP"
    public static let creditURL = URL(string: "https://db-ip.com")!

    private let countries: RangeTable
    private let owners: RangeTable
    private var ownerCache: [UInt32: NetworkOwner] = [:]
    private let lock = NSLock()

    public init(countries: RangeTable, owners: RangeTable) {
        self.countries = countries
        self.owners = owners
    }

    /// Opens `countries.bin` and `owners.bin` in `directory`.
    public convenience init(directory: URL) throws {
        try self.init(countries: RangeTable(contentsOf: directory.appendingPathComponent("countries.bin")),
                      owners: RangeTable(contentsOf: directory.appendingPathComponent("owners.bin")))
    }

    /// The copy inside the app, in `Contents/Resources/Geo`.
    public static func bundled(in bundle: Bundle = .main) -> ServerDirectory? {
        guard let directory = bundle.url(forResource: "Geo", withExtension: nil) else { return nil }
        return try? ServerDirectory(directory: directory)
    }

    /// Everything known about `address`, or nothing if it isn't one.
    public func lookup(_ address: String) -> ServerInfo {
        guard let parsed = IPAddress(address) else { return ServerInfo(country: nil, owner: nil) }
        return lookup(parsed)
    }

    public func lookup(_ address: IPAddress) -> ServerInfo {
        ServerInfo(country: countries.label(for: address),
                   owner: owners.labelIndex(for: address).map(owner(at:)))
    }

    /// Owner labels are written `"<ASN>\t<registered name>"`. Parsing one and
    /// naming its company is string work worth doing once per network, not
    /// once per address.
    private func owner(at index: UInt32) -> NetworkOwner {
        lock.lock()
        defer { lock.unlock() }
        if let cached = ownerCache[index] { return cached }
        let label = owners.label(at: index)
        let parts = label.split(separator: "\t", maxSplits: 1)
        let asn = parts.first.flatMap { UInt32($0) } ?? 0
        let name = parts.count > 1 ? String(parts[1]) : label
        let owner = NetworkOwner(asn: asn, registeredName: name,
                                 company: Company.owning(asn: asn, registeredName: name))
        ownerCache[index] = owner
        return owner
    }
}

public struct ServerInfo: Equatable {
    /// ISO 3166-1 alpha-2, such as "DE". Nil when the data places it nowhere.
    public let country: String?
    public let owner: NetworkOwner?

    public init(country: String?, owner: NetworkOwner?) {
        self.country = country
        self.owner = owner
    }
}

/// The autonomous system an address is announced from: the network, and the
/// organisation that registered it.
public struct NetworkOwner: Hashable {
    public let asn: UInt32
    /// As registered, such as "Microsoft Corporation".
    public let registeredName: String
    public let company: Company

    public init(asn: UInt32, registeredName: String, company: Company) {
        self.asn = asn
        self.registeredName = registeredName
        self.company = company
    }
}
