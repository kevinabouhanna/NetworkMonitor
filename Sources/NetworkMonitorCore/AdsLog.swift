import Combine
import FilterProtocol
import FirewallPolicy
import Foundation

/// One connection the filter decided, as the Ads window's log shows it (#252).
public struct AdsLogEntry: Equatable, Identifiable {
    public let id: Int
    public let time: Date
    public let appKey: String?
    public let appName: String
    public let bundlePath: String?
    public let address: String
    public let port: Int
    /// The site's name, from the app or the connection's handshake; nil when
    /// it had none anyone could read.
    public let name: String?
    /// What blocked it, as the filter reports it (`list:ads`, a rule's id,
    /// `mode`), or nil when it went through.
    public let blockedBy: String?
    /// The lists holding its name, by id, whether or not they blocked it.
    public let lists: [String]

    public init(id: Int, time: Date, appKey: String?, appName: String, bundlePath: String?, address: String,
                port: Int, name: String?, blockedBy: String?, lists: [String]) {
        self.id = id
        self.time = time
        self.appKey = appKey
        self.appName = appName
        self.bundlePath = bundlePath
        self.address = address
        self.port = port
        self.name = name
        self.blockedBy = blockedBy
        self.lists = lists
    }

    public var isBlocked: Bool { blockedBy != nil }
    public var isUnnamed: Bool { name == nil }
}

/// The last few thousand connections the filter decided, newest first, kept
/// in memory only (#252). History keeps the counts (#250); this keeps each
/// decision for as long as someone might look for one they just saw.
public final class AdsLog: ObservableObject {

    public enum Show: String, CaseIterable, Identifiable {
        case all, blocked, listed, unnamed

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .all:     return L("All")
            case .blocked: return L("Blocked")
            case .listed:  return L("On a List")
            case .unnamed: return L("No Name")
            }
        }

        public func includes(_ entry: AdsLogEntry) -> Bool {
            switch self {
            case .all:     return true
            case .blocked: return entry.isBlocked
            case .listed:  return !entry.lists.isEmpty
            case .unnamed: return entry.isUnnamed
            }
        }
    }

    @Published public private(set) var entries: [AdsLogEntry] = []

    public static let limit = 5_000
    private var nextID = 0
    private let limit: Int

    public init(limit: Int = AdsLog.limit) {
        self.limit = limit
    }

    /// New decisions, oldest first as the filter sent them.
    public func append(_ new: [(time: Date, appKey: String?, appName: String, bundlePath: String?, address: String,
                                port: Int, name: String?, blockedBy: String?, lists: [String])]) {
        guard !new.isEmpty else { return }
        var added: [AdsLogEntry] = []
        for item in new {
            added.append(AdsLogEntry(id: nextID, time: item.time, appKey: item.appKey, appName: item.appName,
                                     bundlePath: item.bundlePath, address: item.address, port: item.port,
                                     name: item.name, blockedBy: item.blockedBy, lists: item.lists))
            nextID += 1
        }
        var updated = added.reversed() + entries
        if updated.count > limit { updated.removeLast(updated.count - limit) }
        entries = updated
    }

    public func clear() { entries = [] }

    /// The entries shown for a choice and a search, which matches the app,
    /// the name, the address and the reason.
    public static func filtered(_ entries: [AdsLogEntry], show: Show, search: String,
                                reason: (AdsLogEntry) -> String) -> [AdsLogEntry] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.filter { entry in
            guard show.includes(entry) else { return false }
            guard !query.isEmpty else { return true }
            return [entry.appName, entry.name ?? "", entry.address, reason(entry)]
                .contains { $0.lowercased().contains(query) }
        }
    }

    /// Why it was blocked or let through, in plain words.
    public static func reason(for entry: AdsLogEntry, rules: [FirewallRule], adRules: [AdRule] = []) -> String {
        guard let blockedBy = entry.blockedBy else {
            guard !entry.lists.isEmpty else { return L("Let through") }
            // Your own rule said never (#253).
            if let rule = AdRule.deciding(adRules, name: entry.name, appKeys: entry.appKey.map { [$0] } ?? []),
               rule.kind == .neverBlock {
                return L("Your rule: %@", rule.shownSummary.lowercasedFirst)
            }
            return L("Let through, though it's on a list")
        }
        if let id = BlockReason.adRuleID(inReport: blockedBy) {
            return adRules.first { $0.id == id }.map { L("Your rule: %@", $0.shownSummary.lowercasedFirst) } ?? L("Your rule")
        }
        if let list = BlockReason.list(inReport: blockedBy) {
            // A downloaded list goes by its own name (#254).
            if let title = ListLibrary.title(of: list) { return L("On %@", title) }
            return L("On the %@ list", AdsReport.title(ofList: list).lowercased())
        }
        switch blockedBy {
        case "mode":            return L("Only where you allow")
        case "everything":      return L("Block Everything")
        case "ask":             return L("Ask Me")
        case "hotspot-updates": return L("An update, on a hotspot")
        default:
            guard let rule = rules.first(where: { $0.id == blockedBy }) else { return L("A rule") }
            return rule.appTitle.map { L("Your rule: %@ in %@", rule.title, $0) } ?? L("Your rule: %@", rule.title)
        }
    }

    /// The log as text, for a file: one line per entry, oldest first.
    public static func text(_ entries: [AdsLogEntry], reason: (AdsLogEntry) -> String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = [L("time\tapp\tname\taddress\tport\tdecision\twhy\tlists")]
        for entry in entries.reversed() {
            lines.append([formatter.string(from: entry.time), entry.appName, entry.name ?? L("(no name)"),
                          entry.address, String(entry.port), entry.isBlocked ? L("blocked") : L("let through"),
                          reason(entry), entry.lists.joined(separator: ",")].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

extension String {
    /// "Never block x" as it reads mid-sentence: "never block x".
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
