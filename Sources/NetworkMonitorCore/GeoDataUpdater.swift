import CryptoKit
import Foundation
import ServerDirectory

/// Keeps the country and network-owner data current (#121): DB-IP publishes
/// a new month every month, and a workflow packages it, signed, as the
/// `geodata` release on GitHub. This downloads it, once a month.
///
/// The app's one network access of its own, so it's careful about it:
/// - the whole file, the same for everyone, which tells nobody which servers
///   this Mac talks to;
/// - never on a hotspot, a metered connection or in Low Data Mode;
/// - used only once the manifest's signature checks out against the key
///   below, each table's size and SHA-256 match, and the tables open;
/// - anything less keeps the copy already there, and the shipped copy is
///   always the fallback;
/// - on by default, with a switch in Settings › Connections.
public final class GeoDataUpdater: ObservableObject {

    @Published public var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled && !oldValue { checkSoon() }
        }
    }
    /// The month of the data in use, shipped or downloaded.
    @Published public private(set) var month: String?
    @Published public private(set) var lastChecked: Date?

    public static let enabledKey = "geoDataUpdates"
    public static let lastCheckedKey = "geoDataLastChecked"
    /// Where the workflow publishes each month. A development build can be
    /// pointed elsewhere with `-geoDataURL http://127.0.0.1:8765/`, and
    /// `-geoDataCheckNow YES` checks at once, due or not: launch arguments
    /// only, so neither outlives the run.
    public static var releaseURL: URL {
        launchArgument("geoDataURL").flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/kevinabouhanna/NetworkMonitor/releases/download/geodata/")!
    }

    private static func launchArgument(_ name: String) -> String? {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[name] as? String
    }
    /// The public half of the key the workflow signs with. The private half is
    /// in the repository's secrets and never in the repository.
    public static let publicKey = "DbqdwPBIq5LLPNirTZIwyAMXM3HuD0tsde3Rwc2kBaA="
    /// How long after a check, stale or not, before the next.
    static let checkEvery: TimeInterval = 20 * 60 * 60

    /// `~/Library/Application Support/NetworkMonitor/Geo`, which Uninstall
    /// removes with the rest.
    public static var downloadedDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NetworkMonitor/Geo", isDirectory: true)
    }

    /// Whether the connection may carry a download: not metered and not in
    /// Low Data Mode, as the app judges it.
    public var mayDownload: () -> Bool = { true }
    /// A new month is in place: for Connections and the content filter.
    public var onUpdate: ((URL, String) -> Void)?

    private let defaults: UserDefaults
    private var timer: Timer?
    private var checking = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        lastChecked = defaults.object(forKey: Self.lastCheckedKey) as? Date
        month = ServerDirectory.newest(downloaded: Self.downloadedDirectory)?.month
    }

    /// A minute after launch, then every few hours: a check only does
    /// anything once the data is from an earlier month.
    public func start() {
        if Self.launchArgument("geoDataCheckNow") == "YES" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.check(force: true) }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.checkIfDue() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            self?.checkIfDue()
        }
    }

    private func checkSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.checkIfDue() }
    }

    /// Stale, switched on, and not checked lately.
    public static func isDue(enabled: Bool, month: String?, lastChecked: Date?, now: Date = Date()) -> Bool {
        guard enabled else { return false }
        if let lastChecked, now.timeIntervalSince(lastChecked) < checkEvery, now >= lastChecked { return false }
        guard let month else { return true }
        return month < currentMonth(now)
    }

    /// The month in UTC, as DB-IP names them.
    public static func currentMonth(_ now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month], from: now)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    public func checkIfDue() {
        check(force: false)
    }

    private func check(force: Bool) {
        guard !checking, force || Self.isDue(enabled: isEnabled, month: month, lastChecked: lastChecked),
              mayDownload() else { return }
        checking = true
        let current = month
        // On the main actor, where the published state lives; the download
        // itself runs off it.
        Task { @MainActor [weak self] in
            let outcome = await Self.fetch(newerThan: current)
            guard let self else { return }
            self.checking = false
            self.lastChecked = Date()
            self.defaults.set(self.lastChecked, forKey: Self.lastCheckedKey)
            if case .updated(let month) = outcome {
                self.month = month
                self.onUpdate?(Self.downloadedDirectory, month)
            }
        }
    }

    public enum Outcome: Equatable {
        case updated(String)
        case current
        case failed(String)
    }

    /// The manifest and its signature, then each table, then into place.
    static func fetch(newerThan current: String?) async -> Outcome {
        do {
            let manifestData = try await download(GeoDataManifest.fileName)
            let signature = try await download(GeoDataManifest.signatureName)
            let manifest = try verify(manifestData, signature: signature)
            guard current.map({ manifest.month > $0 }) ?? true else { return .current }
            var tables: [String: Data] = [:]
            for file in manifest.files {
                tables[file.name] = try decompress(try await download(file.asset), as: file)
            }
            try install(tables, month: manifest.month, at: downloadedDirectory)
            return .updated(manifest.month)
        } catch {
            NSLog("NetworkMonitor: data refresh: \(error)")
            return .failed("\(error)")
        }
    }

    public enum RefreshError: Error {
        case badSignature, badManifest, wrongSize(String), wrongDigest(String), notDecompressed(String)
    }

    /// The manifest, only if the key above signed exactly these bytes.
    public static func verify(_ manifest: Data, signature: Data, publicKey: String = publicKey) throws -> GeoDataManifest {
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let text = String(data: signature, encoding: .utf8),
              let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              key.isValidSignature(raw, for: manifest)
        else { throw RefreshError.badSignature }
        guard let parsed = try? JSONDecoder().decode(GeoDataManifest.self, from: manifest), parsed.isWellFormed
        else { throw RefreshError.badManifest }
        return parsed
    }

    public static func decompress(_ data: Data, as file: GeoDataManifest.File) throws -> Data {
        guard let table = try? (data as NSData).decompressed(using: .lzfse) as Data else {
            throw RefreshError.notDecompressed(file.name)
        }
        guard table.count == file.size else { throw RefreshError.wrongSize(file.name) }
        let digest = SHA256.hash(data: table).map { String(format: "%02x", $0) }.joined()
        guard digest == file.sha256 else { throw RefreshError.wrongDigest(file.name) }
        _ = try RangeTable(data: table)
        return table
    }

    /// Written beside, opened to be sure, then swapped in whole.
    public static func install(_ tables: [String: Data], month: String, at destination: URL) throws {
        let manager = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent("Geo-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        for (name, data) in tables {
            try data.write(to: staging.appendingPathComponent(name), options: .atomic)
        }
        try Data((month + "\n").utf8).write(to: staging.appendingPathComponent(GeoData.monthFile))
        _ = try ServerDirectory(directory: staging)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: destination)
        }
    }

    /// Fetched fresh, with nothing kept or sent but the request, and never
    /// over a connection macOS knows to be expensive or constrained.
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
