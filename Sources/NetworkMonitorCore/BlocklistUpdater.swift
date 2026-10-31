import CryptoKit
import FirewallPolicy
import Foundation

/// Keeps the ad, tracker and malware lists current (#176). A workflow builds
/// them each week and publishes them, signed, as the `blocklists` release on
/// GitHub; the app ships a copy and downloads newer ones.
///
/// Careful the way the country data is (#121):
/// - the whole file, the same for everyone, which tells nobody what this Mac
///   connects to;
/// - only while the lists are switched on, and at most once a day;
/// - never on a hotspot, a metered connection or in Low Data Mode;
/// - used only once the manifest's signature checks out against the key the
///   country data is signed with, and each table's size and SHA-256 match;
/// - anything less keeps the copy already there, and the shipped copy is
///   always the fallback;
/// - on by default, with a switch in Settings › Connections.
public final class BlocklistUpdater: ObservableObject {

    @Published public var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled && !oldValue { checkSoon() }
        }
    }
    /// The lists in use, shipped or downloaded.
    @Published public private(set) var lists: Blocklists?
    @Published public private(set) var lastChecked: Date?

    public static let enabledKey = "blocklistUpdates"
    public static let lastCheckedKey = "blocklistsLastChecked"
    /// Where the workflow publishes each week. A development build can be
    /// pointed elsewhere with `-blocklistsURL http://127.0.0.1:8765/`.
    public static var releaseURL: URL {
        launchArgument("blocklistsURL").flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/kevinabouhanna/NetworkMonitor/releases/download/blocklists/")!
    }

    private static func launchArgument(_ name: String) -> String? {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[name] as? String
    }
    /// Lists older than this are worth a check.
    static let staleAfter: TimeInterval = 7 * 24 * 60 * 60
    static let checkEvery: TimeInterval = 20 * 60 * 60

    /// `~/Library/Application Support/NetworkMonitor/Blocklists`, which
    /// Uninstall removes with the rest.
    public static var downloadedDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NetworkMonitor/Blocklists", isDirectory: true)
    }

    /// The copy inside the app.
    public static var shippedDirectory: URL? {
        Bundle.main.url(forResource: "Blocklists", withExtension: nil)
    }

    /// Whether the lists are switched on: they're only fetched when they are.
    public var isWanted: () -> Bool = { false }
    /// Whether the connection may carry a download: not metered and not in
    /// Low Data Mode, as the app judges it.
    public var mayDownload: () -> Bool = { true }
    /// Newer lists are in place: for the content filter.
    public var onUpdate: ((URL, String) -> Void)?

    private let defaults: UserDefaults
    private var timer: Timer?
    private var checking = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        lastChecked = defaults.object(forKey: Self.lastCheckedKey) as? Date
        lists = Self.newest()?.lists
    }

    /// The newest copy on this Mac, shipped or downloaded.
    public static func newest() -> (directory: URL, lists: Blocklists)? {
        Blocklists.newest([shippedDirectory, downloadedDirectory].compactMap { $0 })
    }

    public func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            self?.checkIfDue()
        }
    }

    /// Soon after the lists are switched on, if they're stale.
    public func checkSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.checkIfDue() }
    }

    /// Switched on, stale, and not checked lately.
    public static func isDue(enabled: Bool, wanted: Bool, version: String?, lastChecked: Date?,
                             now: Date = Date()) -> Bool {
        guard enabled, wanted else { return false }
        if let lastChecked, now.timeIntervalSince(lastChecked) < checkEvery, now >= lastChecked { return false }
        guard let version, let built = dateFormatter.date(from: version) else { return true }
        return now.timeIntervalSince(built) >= staleAfter
    }

    public static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// "31 Oct 2026", from a version.
    public static func displayDate(_ version: String?) -> String? {
        guard let version, let date = dateFormatter.date(from: version) else { return nil }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    public func checkIfDue() {
        guard !checking,
              Self.isDue(enabled: isEnabled, wanted: isWanted(), version: lists?.version, lastChecked: lastChecked),
              mayDownload() else { return }
        checking = true
        let current = lists?.version
        Task { @MainActor [weak self] in
            let outcome = await Self.fetch(newerThan: current)
            guard let self else { return }
            self.checking = false
            self.lastChecked = Date()
            self.defaults.set(self.lastChecked, forKey: Self.lastCheckedKey)
            if case .updated(let version) = outcome, let newest = Self.newest() {
                self.lists = newest.lists
                self.onUpdate?(newest.directory, version)
            }
        }
    }

    public enum Outcome: Equatable {
        case updated(String)
        case current
        case failed(String)
    }

    static func fetch(newerThan current: String?) async -> Outcome {
        do {
            let manifestData = try await download(BlocklistManifest.fileName)
            let signature = try await download(BlocklistManifest.signatureName)
            let manifest = try verify(manifestData, signature: signature)
            guard current.map({ manifest.version > $0 }) ?? true else { return .current }
            var tables: [String: Data] = [:]
            for file in manifest.files {
                tables[file.name] = try decompress(try await download(file.asset), as: file)
            }
            try install(tables, version: manifest.version, at: downloadedDirectory)
            return .updated(manifest.version)
        } catch {
            NSLog("NetworkMonitor: list refresh: \(error)")
            return .failed("\(error)")
        }
    }

    public enum RefreshError: Error {
        case badSignature, badManifest, wrongSize(String), wrongDigest(String), notDecompressed(String), notAList(String)
    }

    /// The manifest, only if the key the country data is signed with signed
    /// exactly these bytes, and only if it's a manifest of lists.
    public static func verify(_ manifest: Data, signature: Data,
                              publicKey: String = GeoDataUpdater.publicKey) throws -> BlocklistManifest {
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let text = String(data: signature, encoding: .utf8),
              let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              key.isValidSignature(raw, for: manifest)
        else { throw RefreshError.badSignature }
        guard let parsed = try? JSONDecoder().decode(BlocklistManifest.self, from: manifest), parsed.isWellFormed
        else { throw RefreshError.badManifest }
        return parsed
    }

    public static func decompress(_ data: Data, as file: BlocklistManifest.File) throws -> Data {
        guard let table = try? (data as NSData).decompressed(using: .lzfse) as Data else {
            throw RefreshError.notDecompressed(file.name)
        }
        guard table.count == file.size else { throw RefreshError.wrongSize(file.name) }
        let digest = SHA256.hash(data: table).map { String(format: "%02x", $0) }.joined()
        guard digest == file.sha256 else { throw RefreshError.wrongDigest(file.name) }
        guard (try? BlocklistTable(data: table)) != nil else { throw RefreshError.notAList(file.name) }
        return table
    }

    /// Written beside, opened to be sure, then swapped in whole.
    public static func install(_ tables: [String: Data], version: String, at destination: URL) throws {
        let manager = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent("Blocklists-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        for (name, data) in tables {
            try data.write(to: staging.appendingPathComponent(name), options: .atomic)
        }
        try Data((version + "\n").utf8).write(to: staging.appendingPathComponent(Blocklists.versionFile))
        guard Blocklists(directory: staging) != nil else { throw RefreshError.badManifest }
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: destination)
        }
    }

    private static func download(_ name: String) async throws -> Data {
        var request = URLRequest(url: releaseURL.appendingPathComponent(name), timeoutInterval: 60)
        request.allowsExpensiveNetworkAccess = false
        request.allowsConstrainedNetworkAccess = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}

/// How many connections the lists blocked today (#176), for the popover and
/// Settings. Counted from the filter's reports, and kept per day.
public final class ListBlockCount: ObservableObject {
    @Published public private(set) var today: Int

    public static let countKey = "listBlocksToday"
    public static let dayKey = "listBlocksDay"

    private let defaults: UserDefaults
    private let calendar: Calendar

    public init(defaults: UserDefaults = .standard, calendar: Calendar = .current, now: Date = Date()) {
        self.defaults = defaults
        self.calendar = calendar
        let sameDay = (defaults.object(forKey: Self.dayKey) as? Date).map { calendar.isDate($0, inSameDayAs: now) }
        today = sameDay == true ? defaults.integer(forKey: Self.countKey) : 0
    }

    public func add(_ count: Int, now: Date = Date()) {
        let day = defaults.object(forKey: Self.dayKey) as? Date
        if day.map({ !calendar.isDate($0, inSameDayAs: now) }) ?? true {
            today = 0
            defaults.set(calendar.startOfDay(for: now), forKey: Self.dayKey)
        }
        guard count > 0 else { return }
        today += count
        defaults.set(today, forKey: Self.countKey)
    }
}
