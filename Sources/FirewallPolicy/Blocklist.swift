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
/// lists of names, and Adblock-style domain rules (`||ads.example.com^`, with
/// `@@||site^` exceptions, #254).
public enum BlocklistParser {

    public struct Parsed: Equatable {
        /// The names it blocks, each covering the names under it.
        public var names: [String] = []
        /// The names it lets through, under one it blocks: `@@||site^`. None
        /// at or under an `$important` block, which outranks them (#322).
        public var exceptions: [String] = []
        /// From its header, `# Title: …` or `! Title: …`.
        public var title: String?
        /// Lines it had that say more than a name: a path, a pattern, or a
        /// rule for one kind of request. A list of nothing else isn't a list
        /// of sites.
        public var skipped = 0
    }

    public static func names(in text: String) -> [String] { read(text).names }

    public static func read(_ text: String) -> Parsed {
        var parsed = Parsed()
        var important: [String] = []
        var cancelled: [Rule] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard let lead = trimmed.first else { continue }
            if lead == "#" || lead == "!" {
                if parsed.title == nil { parsed.title = title(inComment: trimmed) }
                continue
            }
            if lead == "[" { continue }
            // A trailing comment needs a space before it: `site##.ad` hides
            // part of a page, and isn't the site.
            var line = Substring(trimmed)
            if let comment = line.range(of: " #") ?? line.range(of: "\t#") { line = line[..<comment.lowerBound] }
            guard !line.contains("#") else { parsed.skipped += 1; continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = fields.first else { continue }
            if ["0.0.0.0", "127.0.0.1", "::", "::1"].contains(first) {
                for field in fields.dropFirst() {
                    if let name = name(field) { parsed.names.append(name) }
                }
                continue
            }
            guard fields.count == 1 else { parsed.skipped += 1; continue }
            if first.hasPrefix("||") || first.hasPrefix("@@||") {
                switch rule(first) {
                case .block(let name)?:      parsed.names.append(name)
                case .important(let name)?:  important.append(name)
                case .exception(let name)?:  parsed.exceptions.append(name)
                case .cancel(let rule)?:     cancelled.append(rule)
                case nil:                    parsed.skipped += 1
                }
            } else if let name = name(first) {
                parsed.names.append(name)
            } else {
                parsed.skipped += 1
            }
        }
        // `$badfilter` takes out the very rule it names, and nothing else (#322).
        if !cancelled.isEmpty {
            parsed.names.removeAll { cancelled.contains(.block($0)) }
            important.removeAll { cancelled.contains(.important($0)) }
            parsed.exceptions.removeAll { cancelled.contains(.exception($0)) }
        }
        // An important block wins over the list's exceptions (#322): those at or
        // under it go, so the block is what decides there.
        if !important.isEmpty {
            let outranking = Set(important)
            parsed.exceptions.removeAll { SiteName.domains(of: $0).contains(where: outranking.contains) }
            let named = Set(parsed.names)
            parsed.names += important.filter { !named.contains($0) }
        }
        return parsed
    }

    private indirect enum Rule: Equatable {
        case block(String), important(String), exception(String)
        /// `$badfilter`: the same rule without it doesn't count.
        case cancel(Rule)
    }

    /// Options that keep a rule about the whole site: `$important` raises a
    /// block over the list's exceptions, and DNS blockers treat the rest so.
    static let siteWideOptions: Set<String> = ["important", "all", "document", "doc", "popup"]

    private static func rule(_ text: Substring) -> Rule? {
        var text = text
        let isException = text.hasPrefix("@@")
        if isException { text = text.dropFirst(2) }
        text = text.dropFirst(2)
        var options: [Substring] = []
        if let dollar = text.firstIndex(of: "$") {
            options = text[text.index(after: dollar)...].split(separator: ",")
            text = text[..<dollar]
        }
        if text.hasSuffix("^|") { text = text.dropLast() }
        guard text.hasSuffix("^"), let name = name(text.dropLast()) else { return nil }
        guard options.allSatisfy({ $0 == "badfilter" || siteWideOptions.contains(String($0)) }) else { return nil }
        let rule: Rule = isException ? .exception(name) : options.contains("important") ? .important(name) : .block(name)
        // `$badfilter` cancels the same rule without it.
        return options.contains("badfilter") ? .cancel(rule) : rule
    }

    private static func name(_ candidate: Substring) -> String? {
        guard let name = SiteName.normalized(String(candidate)), !ignored.contains(name),
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }),
              name.unicodeScalars.allSatisfy(\.isASCII)
        else { return nil }
        return name
    }

    private static func title(inComment line: String) -> String? {
        let body = line.drop(while: { $0 == "#" || $0 == "!" || $0 == " " })
        guard body.lowercased().hasPrefix("title:") else { return nil }
        let title = body.dropFirst(6).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : String(title.prefix(80))
    }

    /// Lines hosts files carry for the machine itself.
    static let ignored: Set<String> = ["localhost.localdomain", "local", "broadcasthost", "ip6-localhost",
                                       "ip6-loopback", "0.0.0.0"]
}

/// A list downloaded on this Mac from its source (#254), rather than in the
/// signed `blocklists` release: what it blocks, and its exceptions, each
/// covering the names under it. The most specific name decides, so
/// `@@||cdn.example.com^` lets `img.cdn.example.com` through while
/// `||example.com^` still blocks `ads.example.com`.
public struct DownloadedList: Equatable {
    /// `hagezi-pro`, or `url-…` for one added by its address.
    public let id: String
    public let blocks: BlocklistTable
    public let exceptions: BlocklistTable

    public init(id: String, blocks: BlocklistTable, exceptions: BlocklistTable = BlocklistTable(names: [String]())) {
        self.id = id
        self.blocks = blocks
        self.exceptions = exceptions
    }

    public init(id: String, parsed: BlocklistParser.Parsed) {
        self.init(id: id, blocks: BlocklistTable(names: parsed.names),
                  exceptions: BlocklistTable(names: parsed.exceptions))
    }

    public func lists(_ name: String) -> Bool {
        for domain in SiteName.domains(of: name) {
            let hash = BlocklistTable.hash(domain)
            if exceptions.contains(hash: hash) { return false }
            if blocks.contains(hash: hash) { return true }
        }
        return false
    }

    // MARK: On disk and on the way to the filter

    static let magic = Array("NMDL".utf8)
    static let version: UInt8 = 1

    public enum FormatError: Error { case notLists }

    /// Several lists in one file, as the app hands them to the filter: "NMDL",
    /// a version, three zero bytes, a 32-bit count, then each list's id
    /// (16-bit length, UTF-8), and its two tables (32-bit length, then the
    /// table), little-endian.
    public static func encode(_ lists: [DownloadedList]) -> Data {
        var data = Data(magic + [version, 0, 0, 0])
        append(UInt32(lists.count), to: &data)
        for list in lists {
            let id = Data(list.id.utf8)
            data.append(contentsOf: (0..<2).map { UInt8(truncatingIfNeeded: id.count >> (8 * $0)) })
            data.append(id)
            for table in [list.blocks, list.exceptions] {
                let bytes = table.encoded()
                append(UInt32(bytes.count), to: &data)
                data.append(bytes)
            }
        }
        return data
    }

    public static func decode(_ data: Data) throws -> [DownloadedList] {
        let bytes = [UInt8](data)
        var offset = 0
        func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, offset + count <= bytes.count else { throw FormatError.notLists }
            defer { offset += count }
            return bytes[offset..<offset + count]
        }
        func number(_ width: Int) throws -> Int {
            Int(try take(width).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) })
        }
        guard Array(try take(4)) == magic, try take(4).first == version else { throw FormatError.notLists }
        let count = try number(4)
        var lists: [DownloadedList] = []
        for _ in 0..<count {
            guard let id = String(bytes: try take(try number(2)), encoding: .utf8), isID(id) else {
                throw FormatError.notLists
            }
            let blocks = try BlocklistTable(data: Data(try take(try number(4))))
            let exceptions = try BlocklistTable(data: Data(try take(try number(4))))
            lists.append(DownloadedList(id: id, blocks: blocks, exceptions: exceptions))
        }
        guard offset == bytes.count else { throw FormatError.notLists }
        return lists
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
    }

    /// Lowercase letters, digits and dashes: safe as a file name, and never
    /// one of the shipped lists' or `mine`, which have no dash.
    public static func isID(_ id: String) -> Bool {
        id.contains("-") && id.count <= 64
            && id.allSatisfy { ($0.isLetter && $0.isLowercase && $0.isASCII) || $0.isNumber || $0 == "-" }
    }
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
