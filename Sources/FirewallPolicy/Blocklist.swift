import Foundation

// Lists of ad, tracker and malware sites (#176), matched by name in the
// content filter. A workflow builds them each week from public lists, signs
// them, and publishes them as the `blocklists` release; the app ships a copy
// and downloads newer ones. Shared by the app, the filter and the builder, so
// the three read the same format the same way.

/// What a list is for, as Settings and Connections name it.
public enum BlocklistTopic: String, Codable, CaseIterable, Comparable {
    case ads, malware

    public var title: String {
        switch self {
        case .ads:     return "Ads and trackers"
        case .malware: return "Malware and phishing"
        }
    }

    /// The tag a blocked row carries in Connections.
    public var tag: String {
        switch self {
        case .ads:     return "ADS"
        case .malware: return "MALWARE"
        }
    }

    /// Where it comes from, and on what terms.
    public var source: String {
        switch self {
        case .ads:     return "StevenBlack"
        case .malware: return "URLhaus, by malware-filter"
        }
    }

    public var licence: String {
        switch self {
        case .ads:     return "MIT"
        case .malware: return "CC0"
        }
    }

    public var sourceURL: URL {
        switch self {
        case .ads:     return URL(string: "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts")!
        // URLhaus's own hosts file is gone (410 since 2026); malware-filter
        // publishes the same data as one, minus popular sites.
        case .malware: return URL(string: "https://malware-filter.gitlab.io/malware-filter/urlhaus-filter-hosts.txt")!
        }
    }

    public var fileName: String { rawValue + ".bin" }

    /// Malware first: when both lists hold a name, that's the one to say.
    public static func < (lhs: BlocklistTopic, rhs: BlocklistTopic) -> Bool {
        lhs == .malware && rhs != .malware
    }
}

/// One list, as the names' 64-bit hashes, sorted: about 8 bytes a name, and a
/// binary search to look one up. Two names sharing a hash is a chance of one
/// in about 2^64 / 100,000.
public struct BlocklistTable: Equatable {
    public let hashes: [UInt64]

    public var count: Int { hashes.count }

    public init<S: Sequence>(names: S) where S.Element == String {
        hashes = Array(Set(names.map(Self.hash))).sorted()
    }

    static let magic = Array("NMBL".utf8)
    static let version: UInt8 = 1

    public enum FormatError: Error { case notAList, unsorted }

    /// A table as written by `encoded()`: "NMBL", a version, three zero bytes,
    /// a 32-bit count, then the hashes, little-endian.
    public init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, Array(bytes[0..<4]) == Self.magic, bytes[4] == Self.version else {
            throw FormatError.notAList
        }
        let count = Int(bytes[8..<12].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) })
        guard bytes.count == 12 + count * 8 else { throw FormatError.notAList }
        var hashes = [UInt64]()
        hashes.reserveCapacity(count)
        for index in 0..<count {
            let start = 12 + index * 8
            hashes.append(bytes[start..<start + 8].enumerated().reduce(UInt64(0)) {
                $0 | UInt64($1.element) << (8 * UInt64($1.offset))
            })
        }
        guard zip(hashes, hashes.dropFirst()).allSatisfy({ $0 < $1 }) else { throw FormatError.unsorted }
        self.hashes = hashes
    }

    public func encoded() -> Data {
        var data = Data(Self.magic + [Self.version, 0, 0, 0])
        let count = UInt32(hashes.count)
        data.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: count >> (8 * $0)) })
        data.reserveCapacity(12 + hashes.count * 8)
        for hash in hashes {
            data.append(contentsOf: (0..<8).map { UInt8(truncatingIfNeeded: hash >> (8 * UInt64($0))) })
        }
        return data
    }

    public func contains(_ name: String) -> Bool {
        contains(hash: Self.hash(name))
    }

    func contains(hash: UInt64) -> Bool {
        var low = 0
        var high = hashes.count
        while low < high {
            let middle = (low + high) / 2
            if hashes[middle] < hash { low = middle + 1 } else { high = middle }
        }
        return low < hashes.count && hashes[low] == hash
    }

    /// FNV-1a, 64 bits, over the name's UTF-8: stable across runs and
    /// machines, as the table on disk needs.
    public static func hash(_ name: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

/// The lists in use, by topic.
public struct Blocklists {
    public let tables: [BlocklistTopic: BlocklistTable]
    /// "2026-10-31": when they were built.
    public let version: String

    public init(tables: [BlocklistTopic: BlocklistTable], version: String) {
        self.tables = tables
        self.version = version
    }

    /// The lists holding `name`, or a domain above it down to its site. Never
    /// a bare suffix, so a list naming `com` would block nothing.
    public func topics(listing name: String) -> Set<BlocklistTopic> {
        let hashes = SiteName.domains(of: name).map(BlocklistTable.hash)
        guard !hashes.isEmpty else { return [] }
        return Set(tables.filter { _, table in hashes.contains(where: table.contains(hash:)) }.keys)
    }

    /// The files a copy is made of, and the file saying when it was built.
    public static let versionFile = "VERSION"

    /// A copy on disk: every topic's table and its VERSION, or nil.
    public init?(directory: URL) {
        guard let version = Self.version(in: directory) else { return nil }
        var tables: [BlocklistTopic: BlocklistTable] = [:]
        for topic in BlocklistTopic.allCases {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(topic.fileName)),
                  let table = try? BlocklistTable(data: data)
            else { return nil }
            tables[topic] = table
        }
        self.init(tables: tables, version: version)
    }

    public static func version(in directory: URL) -> String? {
        guard let text = try? String(contentsOf: directory.appendingPathComponent(versionFile), encoding: .utf8)
        else { return nil }
        let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return isVersion(version) ? version : nil
    }

    /// A date, "2026-10-31", which sorts as text.
    public static func isVersion(_ text: String) -> Bool {
        text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    /// The newest of several copies; the first listed wins a tie, so list the
    /// shipped copy first.
    public static func newest(_ directories: [URL]) -> (directory: URL, lists: Blocklists)? {
        var best: (directory: URL, lists: Blocklists)?
        for directory in directories {
            guard let lists = Blocklists(directory: directory) else { continue }
            if best == nil || lists.version > best!.lists.version { best = (directory, lists) }
        }
        return best
    }
}

/// Reading a published list: hosts files (`0.0.0.0 ads.example.com`), plain
/// lists of names, and Adblock-style domain rules (`||ads.example.com^`).
public enum BlocklistParser {

    public static func names(in text: String) -> [String] {
        var names: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = fields.first, !first.hasPrefix("!"), !first.hasPrefix("[") else { continue }
            var candidates: [Substring]
            if ["0.0.0.0", "127.0.0.1", "::", "::1"].contains(first) {
                candidates = Array(fields.dropFirst())
            } else {
                candidates = [first]
            }
            for var candidate in candidates {
                if candidate.hasPrefix("||") {
                    candidate = candidate.dropFirst(2)
                    guard let end = candidate.firstIndex(of: "^") else { continue }
                    guard candidate.index(after: end) == candidate.endIndex else { continue }
                    candidate = candidate[..<end]
                }
                guard let name = SiteName.normalized(String(candidate)), !ignored.contains(name),
                      name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }),
                      name.unicodeScalars.allSatisfy(\.isASCII)
                else { continue }
                names.append(name)
            }
        }
        return names
    }

    /// Lines hosts files carry for the machine itself.
    static let ignored: Set<String> = ["localhost.localdomain", "local", "broadcasthost", "ip6-localhost",
                                       "ip6-loopback", "0.0.0.0"]
}

/// What a week's lists are made of, signed as a whole: each table's name, the
/// compressed file it travels as, and its size and SHA-256 once decompressed.
/// Its `kind` keeps a signed country-data manifest from passing for one.
public struct BlocklistManifest: Codable, Equatable {
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

    public let kind: String
    public let version: String
    public let files: [File]

    public static let expectedKind = "blocklists"

    public init(version: String, files: [File]) {
        kind = Self.expectedKind
        self.version = version
        self.files = files
    }

    /// Exactly the tables, each once, with safe names.
    public var isWellFormed: Bool {
        kind == Self.expectedKind && Blocklists.isVersion(version)
            && Set(files.map(\.name)) == Set(BlocklistTopic.allCases.map(\.fileName))
            && files.count == BlocklistTopic.allCases.count
            && files.allSatisfy { !$0.asset.contains("/") && !$0.asset.hasPrefix(".") && $0.size >= 12 }
    }

    public static let fileName = "manifest.json"
    public static let signatureName = "manifest.json.sig"
}
