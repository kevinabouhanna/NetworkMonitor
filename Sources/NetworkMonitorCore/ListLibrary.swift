import CryptoKit
import FirewallPolicy
import Foundation

/// What a downloaded list is about (#254), as the Lists tab groups them.
public enum ListTopic: String, Codable, CaseIterable {
    case ads, trackers, annoyances, malware, added

    public var title: String {
        switch self {
        case .ads:          return "More ad and tracker lists"
        case .trackers:     return "Trackers"
        case .annoyances:   return "Pop-ups"
        case .malware:      return "Malware and phishing"
        case .added:        return "Added by you"
        }
    }
}

/// A list the app can download on this Mac, from its source (#254).
public struct ListSource: Codable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let topic: ListTopic
    /// Who keeps it.
    public let source: String
    public let licence: String
    public let url: URL
    /// What it's for, in a line.
    public let about: String

    public init(id: String, title: String, topic: ListTopic, source: String, licence: String, url: URL,
                about: String) {
        self.id = id
        self.title = title
        self.topic = topic
        self.source = source
        self.licence = licence
        self.url = url
        self.about = about
    }

    public var isAdded: Bool { topic == .added }

    /// The id a list added by its address gets: the same address, the same id.
    public static func id(forURL url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return "url-" + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

/// Lists known to work by name, each downloaded from where its makers
/// publish it (#254). Downloaded on the Mac rather than republished, so the
/// GPL ones are fine to offer this way.
public enum ListCatalogue {

    private static func hagezi(_ file: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/\(file)-onlydomains.txt")!
    }

    /// No list that blocks encrypted DNS: it would stop Private Relay and
    /// browsers' own, and let the internet provider see the sites (#246, #287).
    public static let all: [ListSource] = [
        ListSource(id: "hagezi-light", title: "HaGeZi Light", topic: .ads, source: "HaGeZi", licence: "GPL-3.0",
                   url: hagezi("light"),
                   about: "Ads, trackers and metrics, from the sites people actually visit. Rarely breaks anything."),
        ListSource(id: "hagezi-normal", title: "HaGeZi Normal", topic: .ads, source: "HaGeZi", licence: "GPL-3.0",
                   url: hagezi("multi"),
                   about: "Ads, trackers, metrics and telemetry. A good everyday choice."),
        ListSource(id: "hagezi-pro", title: "HaGeZi Pro", topic: .ads, source: "HaGeZi", licence: "GPL-3.0",
                   url: hagezi("pro"),
                   about: "More thorough: blocks more, and now and then something a site needs to work."),
        ListSource(id: "oisd-small", title: "OISD Small", topic: .ads, source: "OISD", licence: "GPL-3.0",
                   url: URL(string: "https://small.oisd.nl/domainswild2")!,
                   about: "Ads and trackers, kept small so nothing breaks."),
        ListSource(id: "oisd-big", title: "OISD Big", topic: .ads, source: "OISD", licence: "GPL-3.0",
                   url: URL(string: "https://big.oisd.nl/domainswild2")!,
                   about: "Ads, trackers, malware and scams, made from dozens of other lists."),
        ListSource(id: "adguard-dns", title: "AdGuard DNS filter", topic: .ads, source: "AdGuard",
                   licence: "GPL-3.0",
                   url: URL(string: "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt")!,
                   about: "AdGuard's own ad and tracker lists, with EasyList and EasyPrivacy, as site names."),
        ListSource(id: "peter-lowe", title: "Peter Lowe's list", topic: .ads, source: "Peter Lowe",
                   licence: "Its own terms",
                   url: URL(string: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext")!,
                   about: "A small, careful list of ad and tracking servers, kept since 2001."),
        ListSource(id: "easylist-privacy", title: "EasyPrivacy", topic: .trackers, source: "EasyList, by Firebog",
                   licence: "GPL-3.0",
                   url: URL(string: "https://v.firebog.net/hosts/Easyprivacy.txt")!,
                   about: "The tracker sites from EasyPrivacy, which uBlock Origin uses, as Firebog extracts them."),
        ListSource(id: "hagezi-popups", title: "HaGeZi Pop-up Ads", topic: .annoyances, source: "HaGeZi",
                   licence: "GPL-3.0", url: hagezi("popupads"),
                   about: "Sites that open pop-ups and pop-unders."),
        ListSource(id: "hagezi-threats", title: "HaGeZi Threat Intelligence", topic: .malware, source: "HaGeZi",
                   licence: "GPL-3.0", url: hagezi("tif.mini"),
                   about: "Malware, phishing, scams and cryptojacking sites, seen recently."),
    ]

    public static func source(_ id: String) -> ListSource? { all.first { $0.id == id } }
}

/// How a downloaded list stands.
public struct ListStatus: Codable, Equatable {
    /// Names it blocks, in the copy kept.
    public var names: Int
    /// When the copy kept was downloaded.
    public var updated: Date?
    /// The last try, kept or not.
    public var checked: Date?
    /// Why the last try failed, in the person's terms.
    public var error: String?

    public init(names: Int = 0, updated: Date? = nil, checked: Date? = nil, error: String? = nil) {
        self.names = names
        self.updated = updated
        self.checked = checked
        self.error = error
    }
}

/// The lists downloaded on this Mac (#254): the catalogue's and any added by
/// address, which are switched on, and a copy of each, kept current.
///
/// Careful the way the shipped lists are (#176):
/// - downloaded from where its makers publish it, which tells them no more
///   than a browser fetching it would;
/// - only while it's switched on and ad blocking is on, weekly;
/// - never on a hotspot, a metered connection or in Low Data Mode;
/// - a download that fails or holds no site names keeps the copy there.
public final class ListLibrary: ObservableObject {

    /// Lists added by their address, newest last.
    @Published public private(set) var added: [ListSource]
    /// The lists switched on, by id, in the order they were.
    @Published public private(set) var enabled: [String]
    @Published public private(set) var status: [String: ListStatus]
    @Published public private(set) var downloading: Set<String> = []
    /// Switched on and with a copy: what the filter is told to use.
    @Published public private(set) var ready: [String] = []

    public static let enabledKey = "downloadedLists"
    public static let addedKey = "downloadedListsAdded"
    public static let statusKey = "downloadedListsStatus"

    /// Older than this is worth a check.
    static let staleAfter: TimeInterval = 7 * 24 * 60 * 60
    /// A failed try isn't repeated sooner than this.
    static let retryAfter: TimeInterval = 20 * 60 * 60
    /// Larger than any list worth having.
    static let sizeLimit = 40 * 1024 * 1024

    /// Whether ad blocking is on: lists are fetched only while it is.
    public var isWanted: () -> Bool = { false }
    /// Whether the connection may carry a download, as for the shipped lists.
    public var mayDownload: () -> Bool = { true }
    /// The lists in use changed: the file to send the filter, and a version.
    public var onChange: ((URL, String) -> Void)?

    private let defaults: UserDefaults
    private let directory: URL
    private var lists: [String: DownloadedList] = [:]
    private var timer: Timer?
    /// Names the Ads window and the log show for lists added by address.
    public private(set) static var titles: [String: String] = [:]

    public init(defaults: UserDefaults = .standard, directory: URL = ListLibrary.defaultDirectory) {
        self.defaults = defaults
        self.directory = directory
        added = (defaults.data(forKey: Self.addedKey))
            .flatMap { try? JSONDecoder().decode([ListSource].self, from: $0) } ?? []
        status = (defaults.data(forKey: Self.statusKey))
            .flatMap { try? JSONDecoder().decode([String: ListStatus].self, from: $0) } ?? [:]
        enabled = defaults.stringArray(forKey: Self.enabledKey) ?? []
        for id in enabled {
            if let data = try? Data(contentsOf: file(for: id)), let list = try? DownloadedList.decode(data).first {
                lists[id] = list
            }
        }
        enabled = enabled.filter { source($0) != nil }
        updateTitles()
        ready = enabled.filter { lists[$0] != nil }
    }

    /// `~/Library/Application Support/NetworkMonitor/Lists`, which Uninstall
    /// removes with the rest.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NetworkMonitor/Lists", isDirectory: true)
    }

    /// Every list there is to choose: the catalogue's, then the added ones.
    public var all: [ListSource] { ListCatalogue.all + added }

    public func source(_ id: String) -> ListSource? { ListCatalogue.source(id) ?? added.first { $0.id == id } }

    public func isEnabled(_ id: String) -> Bool { enabled.contains(id) }

    /// The switched-on lists, with a copy, that hold `name`.
    public func listed(_ name: String) -> [String] {
        ready.filter { lists[$0]?.lists(name) == true }
    }

    /// The name a list goes by, wherever it's shown.
    public static func title(of id: String) -> String? { ListCatalogue.source(id)?.title ?? titles[id] }

    // MARK: Choosing

    public func setEnabled(_ id: String, _ on: Bool) {
        guard source(id) != nil, on != isEnabled(id) else { return }
        if on {
            enabled.append(id)
        } else {
            enabled.removeAll { $0 == id }
        }
        defaults.set(enabled, forKey: Self.enabledKey)
        if on && lists[id] == nil { download(id) }
        publish()
    }

    public enum AddError: Error, Equatable {
        case notAnAddress, alreadyThere(String)
    }

    /// A list by its address, switched on and downloaded.
    @discardableResult
    public func add(_ text: String) -> Result<String, AddError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", let host = url.host,
              host.contains(".")
        else { return .failure(.notAnAddress) }
        if let existing = all.first(where: { $0.url == url }) { return .failure(.alreadyThere(existing.title)) }
        let id = ListSource.id(forURL: url)
        let list = ListSource(id: id, title: host, topic: .added, source: host, licence: "Its own terms",
                              url: url, about: url.absoluteString)
        added.append(list)
        saveAdded()
        setEnabled(id, true)
        return .success(id)
    }

    /// An added list, gone with its copy.
    public func remove(_ id: String) {
        guard added.contains(where: { $0.id == id }) else { return }
        setEnabled(id, false)
        added.removeAll { $0.id == id }
        status[id] = nil
        lists[id] = nil
        try? FileManager.default.removeItem(at: file(for: id))
        saveAdded()
        saveStatus()
        publish()
    }

    // MARK: Keeping them current

    public func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            self?.checkIfDue()
        }
    }

    /// Each switched-on list that's stale, or has no copy yet.
    public func checkIfDue(now: Date = Date()) {
        guard isWanted() else { return }
        for id in enabled where Self.isDue(status[id], hasCopy: lists[id] != nil, now: now) {
            download(id)
        }
    }

    public static func isDue(_ status: ListStatus?, hasCopy: Bool, now: Date = Date()) -> Bool {
        if let checked = status?.checked, now.timeIntervalSince(checked) < retryAfter, now >= checked,
           hasCopy || status?.error != nil {
            return false
        }
        guard hasCopy, let updated = status?.updated else { return true }
        return now.timeIntervalSince(updated) >= staleAfter
    }

    /// Now, unless it's already under way or the network may not carry it.
    public func download(_ id: String) {
        guard let source = source(id), !downloading.contains(id) else { return }
        guard mayDownload() else {
            if lists[id] == nil {
                record(id, error: "Waiting for a network that isn't a hotspot or metered.", tried: false)
            }
            return
        }
        downloading.insert(id)
        Task { @MainActor [weak self] in
            let outcome = await Self.fetch(source.url)
            self?.finish(id, outcome)
        }
    }

    public enum Fetched {
        case list(BlocklistParser.Parsed)
        case failed(String)
    }

    private func finish(_ id: String, _ outcome: Fetched) {
        downloading.remove(id)
        guard source(id) != nil else { return }
        switch outcome {
        case .failed(let reason):
            record(id, error: reason)
        case .list(let parsed):
            let list = DownloadedList(id: id, parsed: parsed)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try DownloadedList.encode([list]).write(to: file(for: id), options: .atomic)
            } catch {
                record(id, error: "Couldn't keep a copy: \(error.localizedDescription)")
                return
            }
            lists[id] = list
            status[id] = ListStatus(names: list.blocks.count, updated: Date(), checked: Date())
            if let index = added.firstIndex(where: { $0.id == id }), let title = parsed.title,
               added[index].title == added[index].source {
                let old = added[index]
                added[index] = ListSource(id: id, title: title, topic: .added, source: old.source,
                                          licence: old.licence, url: old.url, about: old.about)
                saveAdded()
            }
            saveStatus()
            publish()
        }
    }

    private func record(_ id: String, error: String, tried: Bool = true) {
        var entry = status[id] ?? ListStatus()
        if tried { entry.checked = Date() }
        entry.error = error
        status[id] = entry
        saveStatus()
    }

    /// Downloaded and read, off the main queue.
    static func fetch(_ url: URL) async -> Fetched {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.allowsExpensiveNetworkAccess = false
        request.allowsConstrainedNetworkAccess = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { return .failed("The site answered \(code).") }
            return read(data)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// What a download holds, if it's a list of sites.
    public static func read(_ data: Data) -> Fetched {
        guard data.count <= sizeLimit else { return .failed("It's larger than 40 MB.") }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return .failed("It isn't text.")
        }
        if text.drop(while: \.isWhitespace).hasPrefix("<") { return .failed("It's a web page, not a list.") }
        let parsed = BlocklistParser.read(text)
        guard !parsed.names.isEmpty else {
            return .failed(parsed.skipped > 0
                ? "It has no rules about whole sites. Rules about parts of pages need the Chrome extension."
                : "It has no site names in it.")
        }
        return .list(parsed)
    }

    // MARK: The filter's copy

    /// The file the filter is sent: every list in use, in one.
    public var bundleURL: URL { directory.appendingPathComponent("Enabled.nmdl") }

    /// Writes the lists in use to one file, and says so.
    private func publish() {
        updateTitles()
        let now = enabled.filter { lists[$0] != nil }
        if ready != now { ready = now }
        let bundle = DownloadedList.encode(now.compactMap { lists[$0] })
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try bundle.write(to: bundleURL, options: .atomic)
        } catch {
            NSLog("NetworkMonitor: couldn't write the downloaded lists: \(error)")
            return
        }
        let version = SHA256.hash(data: bundle).prefix(6).map { String(format: "%02x", $0) }.joined()
        onChange?(bundleURL, version)
    }

    /// The file the filter's copy is sent from, if there's one to send.
    public var currentBundle: URL? {
        FileManager.default.fileExists(atPath: bundleURL.path) ? bundleURL : nil
    }

    private func file(for id: String) -> URL { directory.appendingPathComponent(id + ".nmdl") }

    private func updateTitles() {
        Self.titles = Dictionary(added.map { ($0.id, $0.title) }, uniquingKeysWith: { _, last in last })
    }

    private func saveAdded() {
        if let data = try? JSONEncoder().encode(added) { defaults.set(data, forKey: Self.addedKey) }
    }

    private func saveStatus() {
        if let data = try? JSONEncoder().encode(status) { defaults.set(data, forKey: Self.statusKey) }
    }
}
