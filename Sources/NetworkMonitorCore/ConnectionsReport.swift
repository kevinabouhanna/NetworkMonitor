import Foundation
import ServerDirectory

/// One app's traffic with one server, with the server named.
public struct Connection: Equatable {
    public let usage: ServerUsage
    /// ISO 3166-1 alpha-2, or nil when the data places the address nowhere.
    public let country: String?
    public let owner: NetworkOwner?

    public init(usage: ServerUsage, country: String?, owner: NetworkOwner?) {
        self.usage = usage
        self.country = country
        self.owner = owner
    }

    /// Names `usage` from `directory`.
    public init(_ usage: ServerUsage, directory: ServerDirectory?) {
        let info = usage.address == UsageHistory.otherServers ? nil : directory?.lookup(usage.address)
        self.init(usage: usage, country: info?.country, owner: info?.owner)
    }

    /// An app's servers past its hourly limit, added up as one.
    public var isOtherServers: Bool { usage.address == UsageHistory.otherServers }
}

/// The four things a connection can be grouped by.
public enum ConnectionsDimension: String, CaseIterable, Identifiable {
    case company, app, country, server

    public var id: String { rawValue }

    /// A section's heading inside a group.
    public var plural: String {
        switch self {
        case .company: return "Companies"
        case .app:     return "Apps"
        case .country: return "Countries"
        case .server:  return "Servers"
        }
    }
}

/// What the window's list is grouped by: Companies first, because which
/// companies get your data is the question it's there to answer.
public enum ConnectionsGrouping: String, CaseIterable, Identifiable {
    case companies, apps, countries

    public var id: String { rawValue }
    public var label: String { dimension.plural }

    public var dimension: ConnectionsDimension {
        switch self {
        case .companies: return .company
        case .apps:      return .app
        case .countries: return .country
        }
    }

    /// The sections inside each group, in order: the other two groupings, then
    /// the servers themselves.
    public var sections: [ConnectionsDimension] {
        switch self {
        case .companies: return [.app, .country, .server]
        case .apps:      return [.company, .country, .server]
        case .countries: return [.company, .app, .server]
        }
    }
}

/// One row of the list: a company, app, country or server, and what went to it.
public struct ConnectionsItem: Identifiable, Equatable {
    public let dimension: ConnectionsDimension
    public let key: String
    public let title: String
    public let subtitle: String?
    /// A network that carries other companies' traffic.
    public let isHost: Bool
    /// The flag for a country.
    public let symbol: String?
    /// For an app, to draw its icon and read who made it.
    public let bundlePath: String?
    public var bytesIn: Int64 = 0
    public var bytesOut: Int64 = 0

    public var id: String { "\(dimension.rawValue):\(key)" }
    public var total: Int64 { bytesIn + bytesOut }
}

/// A row of the list with the sections it opens into.
public struct ConnectionsGroup: Identifiable, Equatable {
    public struct Section: Identifiable, Equatable {
        public let dimension: ConnectionsDimension
        public let items: [ConnectionsItem]
        public var id: String { dimension.rawValue }
    }

    public let item: ConnectionsItem
    public let sections: [Section]
    public var id: String { item.id }
}

/// What the window is narrowed to, chosen from the list and undone from the
/// chips above it.
public struct ConnectionsFilter: Equatable {
    public var keys: [ConnectionsDimension: String] = [:]

    public init(keys: [ConnectionsDimension: String] = [:]) {
        self.keys = keys
    }

    public var isEmpty: Bool { keys.isEmpty }

    public func matches(_ connection: Connection) -> Bool {
        keys.allSatisfy { ConnectionsReport.key(of: connection, $0.key) == $0.value }
    }
}

/// The totals above the list.
public struct ConnectionsSummary: Equatable {
    public var bytesIn: Int64 = 0
    public var bytesOut: Int64 = 0
    public var companies = 0
    public var countries = 0
    public var apps = 0
    public var servers = 0

    public var total: Int64 { bytesIn + bytesOut }
}

/// What the map shades: bytes per country, and apart from them what went to
/// networks that answer from everywhere, which no one country can stand for.
public struct ConnectionsGeography: Equatable {
    public var countries: [String: Int64] = [:]
    public var everywhere: Int64 = 0
    /// Those networks, biggest first: "Cloudflare", "Fastly".
    public var everywhereCompanies: [String] = []

    public var largest: Int64 { countries.values.max() ?? 0 }
}

/// Groups named connections into the window's list. No AppKit and no storage,
/// so all of it is tested directly.
public enum ConnectionsReport {

    public static let unknownKey = "unknown"
    public static let otherKey = "other"

    /// What `connection` is, along `dimension`. Two connections with the same
    /// key share a row.
    public static func key(of connection: Connection, _ dimension: ConnectionsDimension) -> String {
        switch dimension {
        case .company:
            if connection.isOtherServers { return otherKey }
            guard let company = connection.owner?.company else { return unknownKey }
            // Google's own network and Google Cloud are different answers.
            return (company.isHost ? "host:" : "") + company.name
        case .app:
            return connection.usage.appKey
        case .country:
            if connection.isOtherServers { return otherKey }
            return connection.country ?? unknownKey
        case .server:
            return connection.usage.address
        }
    }

    /// The row `connection` belongs to along `dimension`, with no bytes yet.
    public static func item(for connection: Connection, _ dimension: ConnectionsDimension,
                            locale: Locale = .current) -> ConnectionsItem {
        let key = key(of: connection, dimension)
        switch dimension {
        case .company:
            if connection.isOtherServers {
                return ConnectionsItem(dimension: dimension, key: key, title: "Other servers",
                                       subtitle: "Past an app's \(UsageHistory.serversPerAppPerHour) in an hour",
                                       isHost: false, symbol: nil, bundlePath: nil)
            }
            guard let owner = connection.owner else {
                return ConnectionsItem(dimension: dimension, key: key, title: "Unknown network",
                                       subtitle: "A private, carrier or VPN address, or one the data doesn't list",
                                       isHost: false, symbol: nil, bundlePath: nil)
            }
            if owner.company.isHost {
                return ConnectionsItem(dimension: dimension, key: key,
                                       title: "Hosted on \(owner.company.name)",
                                       subtitle: "Company unknown",
                                       isHost: true, symbol: nil, bundlePath: nil)
            }
            return ConnectionsItem(dimension: dimension, key: key, title: owner.company.name,
                                   subtitle: nil, isHost: false, symbol: nil, bundlePath: nil)
        case .app:
            let usage = connection.usage
            return ConnectionsItem(dimension: dimension, key: key, title: usage.appName,
                                   subtitle: usage.parentName.map { "Started by \($0)" },
                                   isHost: false, symbol: nil, bundlePath: usage.bundlePath)
        case .country:
            guard let code = connection.country else {
                return ConnectionsItem(dimension: dimension, key: key, title: "Unknown country",
                                       subtitle: nil, isHost: false, symbol: nil, bundlePath: nil)
            }
            return ConnectionsItem(dimension: dimension, key: key,
                                   title: countryName(code, locale: locale),
                                   subtitle: nil, isHost: false, symbol: flag(code), bundlePath: nil)
        case .server:
            if connection.isOtherServers {
                return ConnectionsItem(dimension: dimension, key: key, title: "Other servers",
                                       subtitle: nil, isHost: false, symbol: nil, bundlePath: nil)
            }
            let place = connection.country.map { countryName($0, locale: locale) }
            let owner = connection.owner.map { "\($0.registeredName) · AS\($0.asn)" }
            return ConnectionsItem(dimension: dimension, key: key, title: connection.usage.address,
                                   subtitle: [owner, place].compactMap { $0 }.joined(separator: " · "),
                                   isHost: false, symbol: nil, bundlePath: nil)
        }
    }

    /// The list: `connections` narrowed by `filter` and `search`, grouped, each
    /// group and each section biggest first.
    public static func groups(_ connections: [Connection], by grouping: ConnectionsGrouping,
                              filter: ConnectionsFilter = ConnectionsFilter(),
                              search: String = "", locale: Locale = .current) -> [ConnectionsGroup] {
        let shown = narrowed(connections, filter: filter, search: search, locale: locale)
        var order: [String] = []
        var heads: [String: ConnectionsItem] = [:]
        var sections: [String: [ConnectionsDimension: [String: ConnectionsItem]]] = [:]

        for connection in shown {
            let key = key(of: connection, grouping.dimension)
            if heads[key] == nil {
                heads[key] = item(for: connection, grouping.dimension, locale: locale)
                order.append(key)
            }
            heads[key]?.add(connection.usage)
            for dimension in grouping.sections {
                let child = self.key(of: connection, dimension)
                if sections[key, default: [:]][dimension, default: [:]][child] == nil {
                    sections[key, default: [:]][dimension, default: [:]][child]
                        = item(for: connection, dimension, locale: locale)
                }
                sections[key]?[dimension]?[child]?.add(connection.usage)
            }
        }

        return order.compactMap { key -> ConnectionsGroup? in
            guard let head = heads[key] else { return nil }
            let groupSections = grouping.sections.map { dimension in
                ConnectionsGroup.Section(
                    dimension: dimension,
                    items: (sections[key]?[dimension] ?? [:]).values.sorted(by: biggestFirst))
            }
            return ConnectionsGroup(item: head, sections: groupSections)
        }
        .sorted { biggestFirst($0.item, $1.item) }
    }

    /// The totals for the same narrowing.
    public static func summary(_ connections: [Connection], filter: ConnectionsFilter = ConnectionsFilter(),
                               search: String = "", locale: Locale = .current) -> ConnectionsSummary {
        let shown = narrowed(connections, filter: filter, search: search, locale: locale)
        var summary = ConnectionsSummary()
        var seen: [ConnectionsDimension: Set<String>] = [:]
        for connection in shown {
            summary.bytesIn += connection.usage.bytesIn
            summary.bytesOut += connection.usage.bytesOut
            for dimension in ConnectionsDimension.allCases {
                seen[dimension, default: []].insert(key(of: connection, dimension))
            }
        }
        // Rows that stand for no one company or country aren't counted as one.
        let placeholders: Set<String> = [unknownKey, otherKey]
        summary.companies = seen[.company, default: []].subtracting(placeholders).count
        summary.countries = seen[.country, default: []].subtracting(placeholders).count
        summary.apps = seen[.app, default: []].count
        summary.servers = seen[.server, default: []].subtracting([UsageHistory.otherServers]).count
        return summary
    }

    /// The map's shading for the same narrowing. Addresses the data places
    /// nowhere, and an app's servers past its hourly limit, aren't on it.
    public static func geography(_ connections: [Connection], filter: ConnectionsFilter = ConnectionsFilter(),
                                 search: String = "", locale: Locale = .current) -> ConnectionsGeography {
        var geography = ConnectionsGeography()
        var everywhere: [String: Int64] = [:]
        for connection in narrowed(connections, filter: filter, search: search, locale: locale) {
            if let company = connection.owner?.company, company.answersEverywhere {
                geography.everywhere += connection.usage.total
                everywhere[company.name, default: 0] += connection.usage.total
            } else if let country = connection.country, !connection.isOtherServers {
                geography.countries[country, default: 0] += connection.usage.total
            }
        }
        geography.everywhereCompanies = everywhere.sorted { $0.value > $1.value }.map(\.key)
        return geography
    }

    /// The companies with servers in `country`, biggest first, for the map's card.
    public static func companies(inCountry country: String, _ connections: [Connection],
                                 filter: ConnectionsFilter = ConnectionsFilter(), search: String = "",
                                 locale: Locale = .current) -> [(item: ConnectionsItem, bytes: Int64)] {
        var totals: [String: (item: ConnectionsItem, bytes: Int64)] = [:]
        for connection in narrowed(connections, filter: filter, search: search, locale: locale)
        where connection.country == country && connection.owner?.company.answersEverywhere != true {
            let key = key(of: connection, .company)
            totals[key, default: (item(for: connection, .company, locale: locale), 0)].bytes += connection.usage.total
        }
        return totals.values.sorted { $0.bytes > $1.bytes }
    }

    /// The companies an app talks to that aren't hosts: whose traffic it is, as
    /// far as the network's owner can tell.
    public static func companies(ofApp appKey: String, in connections: [Connection]) -> Set<String> {
        Set(connections.compactMap { connection -> String? in
            guard connection.usage.appKey == appKey, let company = connection.owner?.company,
                  !company.isHost else { return nil }
            return company.name
        })
    }

    static func narrowed(_ connections: [Connection], filter: ConnectionsFilter,
                         search: String, locale: Locale) -> [Connection] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return connections.filter { connection in
            filter.matches(connection) && (query.isEmpty || matches(connection, query, locale: locale))
        }
    }

    /// True when anything shown about `connection` contains `query`.
    static func matches(_ connection: Connection, _ query: String, locale: Locale) -> Bool {
        var fields = [connection.usage.appName, connection.usage.address]
        if let parent = connection.usage.parentName { fields.append(parent) }
        if let owner = connection.owner {
            fields += [owner.company.name, owner.registeredName, "AS\(owner.asn)"]
        }
        if let code = connection.country { fields += [code, countryName(code, locale: locale)] }
        return fields.contains { $0.lowercased().contains(query) }
    }

    private static func biggestFirst(_ lhs: ConnectionsItem, _ rhs: ConnectionsItem) -> Bool {
        lhs.total != rhs.total ? lhs.total > rhs.total : lhs.title < rhs.title
    }

    public static func countryName(_ code: String, locale: Locale = .current) -> String {
        locale.localizedString(forRegionCode: code) ?? code
    }

    /// 🇱🇧 for "LB": each letter as its regional indicator symbol.
    public static func flag(_ code: String) -> String? {
        let letters = code.uppercased().unicodeScalars
        guard letters.count == 2, letters.allSatisfy({ $0.value >= 65 && $0.value <= 90 }) else { return nil }
        return String(String.UnicodeScalarView(letters.compactMap { UnicodeScalar(127_397 + $0.value) }))
    }
}

private extension ConnectionsItem {
    mutating func add(_ usage: ServerUsage) {
        bytesIn += usage.bytesIn
        bytesOut += usage.bytesOut
    }
}
