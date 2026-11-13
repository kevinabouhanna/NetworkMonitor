import Combine
import FirewallPolicy
import Foundation
import ServerDirectory

/// What one of your rules did in the window's period (#592): how many
/// connections it stopped, or how much it let through. Both Rules lists,
/// Connections' and Ads and Trackers', say it the same way.
public enum RuleActivity: Equatable {
    /// A block: connections stopped.
    case stopped(Int64)
    /// An allow: bytes let through.
    case letThrough(Int64)
    /// Nothing a period can count, such as a network where ad blocking is off.
    case uncounted

    /// "Stopped 52 times", "94.9 MB let through", "Not used"; nil when
    /// there's nothing to count.
    public var text: String? {
        switch self {
        case .stopped(0), .letThrough(0): return L("Not used")
        case .stopped(1):                 return L("Stopped 1 time")
        case .stopped(let count):         return L("Stopped %@ times", count.formatted())
        case .letThrough(let bytes):      return L("%@ let through", ByteFormat.bytes(bytes))
        case .uncounted:                  return nil
        }
    }
}

/// Which connections a rule covers, and so what it did: no AppKit and no
/// storage, so it's tested directly. The counts are what the record keeps:
/// a block counts every connection stopped to what it covers, whatever
/// stopped it, as Blocked does; an allow, the bytes let through to it.
public enum RuleCount {

    /// Whether a connection of `appKey` is the app `key`'s: the app itself,
    /// or a program it started, which Usage History lists under it.
    public static func isApp(_ appKey: String, _ key: String) -> Bool {
        appKey == key || appKey.hasPrefix(key + String(AppKey.separator))
    }

    /// Whether `rule` is about `connection`: the same company, app, country
    /// or server Connections groups it by, or a name under the rule's site,
    /// and the rule's one app when it has one.
    public static func covers(_ rule: FirewallRule, _ connection: Connection) -> Bool {
        if let app = rule.appKey, !isApp(connection.usage.appKey, app) { return false }
        switch rule.subject {
        case .company: return ConnectionsReport.key(of: connection, .company) == rule.key
        case .app:     return isApp(connection.usage.appKey, rule.key)
        case .country: return ConnectionsReport.key(of: connection, .country) == rule.key
        case .server:  return connection.usage.address == rule.key
        case .site:    return names(of: connection).contains { isUnder($0, site: rule.key) }
        }
    }

    /// What a Connections rule did: a block, the connections stopped; an
    /// allow, the bytes let through.
    public static func activity(of rule: FirewallRule, traffic: [Connection], blocked: [Connection]) -> RuleActivity {
        switch rule.action {
        case .block, .blockOnHotspots:
            // A blocked connection's count travels in `bytesIn`.
            return .stopped(blocked.filter { covers(rule, $0) }.reduce(0) { $0 + $1.usage.bytesIn })
        case .allow:
            return .letThrough(traffic.filter { covers(rule, $0) }.reduce(0) { $0 + $1.usage.total })
        }
    }

    /// Whether an ad-blocking rule is about a connection to `name` from
    /// `appKey`: a name under its site, in its one app if it has one; or,
    /// for an app it doesn't filter, any of the app's connections.
    public static func covers(_ rule: AdRule, name: String?, appKey: String) -> Bool {
        if let app = rule.appKey, !isApp(appKey, app) { return false }
        guard let site = rule.site else { return rule.skipsApp }
        return name.map { isUnder($0, site: site) } ?? false
    }

    /// What an ad-blocking rule did: a block, the connections it stopped
    /// (the record counts them as your own list's); a site always allowed,
    /// or an app not filtered, the bytes let through.
    public static func activity(of rule: AdRule, traffic: [Connection], listBlocks: [ListBlock]) -> RuleActivity {
        switch rule.kind {
        case .alwaysBlock:
            return .stopped(listBlocks.filter {
                $0.list == BlockReason.ownList && covers(rule, name: $0.name, appKey: $0.appKey)
            }.reduce(0) { $0 + $1.count })
        case .neverBlock:
            return .letThrough(traffic.filter { connection in
                rule.site == nil ? covers(rule, name: nil, appKey: connection.usage.appKey)
                    : names(of: connection).contains { covers(rule, name: $0, appKey: connection.usage.appKey) }
            }.reduce(0) { $0 + $1.usage.total })
        }
    }

    private static func names(of connection: Connection) -> [String] {
        (connection.usage.name.map { [$0] } ?? []) + connection.usage.otherNames
    }

    /// `name` is the site or a name under it: `stats.wp.com` is under `wp.com`.
    private static func isUnder(_ name: String, site: String) -> Bool {
        SiteName.domains(of: name).contains(site)
    }
}

/// The record a Rules list counts from, for one period (#592): traffic and
/// blocked connections, named as Connections names them, and what the lists
/// blocked. Read on History's queue, published on the main thread; an answer
/// overtaken by a newer question is dropped.
public final class RulesActivity: ObservableObject {
    @Published public private(set) var traffic: [Connection] = []
    @Published public private(set) var blocked: [Connection] = []
    @Published public private(set) var listBlocks: [ListBlock] = []
    private var generation = 0
    private var asked: Question?

    public init() {}

    private struct Question: Equatable {
        let interval: DateInterval
        let filter: HistoryFilter
    }

    /// Connections names each server from the month's data, opened once.
    private static let naming = DispatchQueue(label: "com.kevinabouhanna.NetworkMonitor.rules", // untranslated: a queue's identifier
                                              qos: .userInitiated)
    private static var directory: ServerDirectory?
    private static var directoryOpened = false

    /// Reads the period again, unless it's the one already read and
    /// `again` is false; the Rules lists ask again when their window
    /// reloads.
    func load(_ history: UsageHistory?, interval: DateInterval, filter: HistoryFilter = HistoryFilter(),
              again: Bool = false) {
        let question = Question(interval: interval, filter: filter)
        guard again || question != asked else { return }
        asked = question
        generation += 1
        let request = generation
        guard let history else { return }
        history.loadListBlocks(from: interval.start, to: interval.end) { [weak self] blocks in
            guard let self, request == self.generation else { return }
            self.listBlocks = blocks
        }
        for measure in [ServerMeasure.bytes, .blocked] {
            history.loadServers(in: interval, hoursOf: interval, filter: filter, measure: measure) { [weak self] report in
                Self.naming.async {
                    if !Self.directoryOpened {
                        Self.directory = ServerDirectory.newest(downloaded: GeoDataUpdater.downloadedDirectory)?.directory
                        Self.directoryOpened = true
                    }
                    let named = report.servers.map { Connection($0, directory: Self.directory) }
                    DispatchQueue.main.async {
                        guard let self, request == self.generation else { return }
                        if measure == .bytes { self.traffic = named } else { self.blocked = named }
                    }
                }
            }
        }
    }

    /// The record to count from in place of History's: for the tests and
    /// the pictures, which have none.
    public func show(traffic: [Connection], blocked: [Connection], listBlocks: [ListBlock]) {
        generation += 1
        self.traffic = traffic
        self.blocked = blocked
        self.listBlocks = listBlocks
    }

    func activity(of rule: FirewallRule) -> RuleActivity {
        RuleCount.activity(of: rule, traffic: traffic, blocked: blocked)
    }

    func activity(of rule: AdRule) -> RuleActivity {
        RuleCount.activity(of: rule, traffic: traffic, listBlocks: listBlocks)
    }
}
