import Foundation

/// Which copy of the country and owner tables to use, and what a monthly
/// refresh carries (#121). DB-IP publishes a new month every month; the app
/// ships one, downloads the next, and the newest wins.
public enum GeoData {

    /// The tables a copy is made of, and the file saying which month it is.
    public static let tables = ["countries.bin", "owners.bin"]
    public static let monthFile = "MONTH"
    /// A shipped copy whose MONTH can't be read (#209): older than any
    /// month, so a download replaces it, but used rather than nothing.
    public static let unknownMonth = "0000-00"

    /// "2026-10", from a copy's MONTH file. Months written this way sort as
    /// text.
    public static func month(in directory: URL) -> String? {
        guard let text = try? String(contentsOf: directory.appendingPathComponent(monthFile), encoding: .utf8)
        else { return nil }
        let month = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return isMonth(month) ? month : nil
    }

    public static func isMonth(_ text: String) -> Bool {
        text.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil
    }

    /// The copy with the latest month, of those that have the tables. The
    /// first listed wins a tie, so list the shipped copy first.
    public static func newest(_ directories: [URL]) -> URL? {
        let usable = directories.filter { directory in
            month(in: directory) != nil && tables.allSatisfy {
                FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
            }
        }
        return usable.reduce(nil) { best, next in
            guard let best, let bestMonth = month(in: best) else { return next }
            return (month(in: next) ?? "") > bestMonth ? next : best
        }
    }
}

extension ServerDirectory {
    /// The newest of the shipped copy and one downloaded since, and its month.
    public static func newest(bundle: Bundle = .main, downloaded: URL?) -> (directory: ServerDirectory, month: String)? {
        newest(shipped: bundle.url(forResource: "Geo", withExtension: nil), downloaded: downloaded)
    }

    public static func newest(shipped: URL?, downloaded: URL?) -> (directory: ServerDirectory, month: String)? {
        for candidate in [GeoData.newest([shipped, downloaded].compactMap { $0 }), shipped].compactMap({ $0 }) {
            if let directory = try? ServerDirectory(directory: candidate), let month = GeoData.month(in: candidate) {
                return (directory, month)
            }
        }
        // The tables without their MONTH are still the data (#209): the
        // content filter had none at all until a month was downloaded.
        if let shipped, let directory = try? ServerDirectory(directory: shipped) {
            return (directory, GeoData.unknownMonth)
        }
        return nil
    }
}

/// What a month's refresh is made of, signed as a whole: each table's name,
/// the compressed file it travels as, and its size and SHA-256 once
/// decompressed.
public struct GeoDataManifest: Codable, Equatable {
    public struct File: Codable, Equatable {
        public let name: String
        public let asset: String
        public let size: Int
        public let sha256: String

        public init(name: String, asset: String, size: Int, sha256: String) {
            self.name = name
            self.asset = asset
            self.size = size
            self.sha256 = sha256
        }
    }

    public let month: String
    public let files: [File]

    public init(month: String, files: [File]) {
        self.month = month
        self.files = files
    }

    /// Exactly the tables, each once, with safe names: a manifest is only
    /// trusted after its signature, but it still never names a path.
    public var isWellFormed: Bool {
        GeoData.isMonth(month)
            && Set(files.map(\.name)) == Set(GeoData.tables) && files.count == GeoData.tables.count
            && files.allSatisfy { !$0.asset.contains("/") && !$0.asset.hasPrefix(".") && $0.size > 0 }
    }

    public static let fileName = "manifest.json"
    public static let signatureName = "manifest.json.sig"
}
