import Foundation

// Trackers behind a site's own name (#255): `metrics.example.com` is an
// alias (a CNAME) of `example.com.sc.omtrdc.net`, so the connection names
// only the site's own name, which no list has. The lookup's answer names the
// alias's target. The content filter reads the answers to the Mac's DNS
// lookups as they come back, without changing them, and remembers each
// alias, so a connection to the name can be matched by what it stands for.

/// Reading a DNS answer (RFC 1035 §4): the name asked about and the aliases
/// it leads through.
public enum DNSAnswer {

    public struct Aliases: Equatable {
        /// The name asked about.
        public let name: String
        /// Each alias in turn, from the name to the last.
        public let chain: [String]
        /// The shortest time the answer said to keep them, in seconds.
        public let ttl: UInt32

        public init(name: String, chain: [String], ttl: UInt32) {
            self.name = name.lowercased()
            self.chain = chain
            self.ttl = ttl
        }
    }

    /// A response's alias chain, or nil when it isn't a response with one.
    public static func aliases(in data: Data) -> Aliases? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else { return nil }
        let flags = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        // A response, standard query, no error.
        guard flags & 0x8000 != 0, (flags >> 11) & 0xf == 0, flags & 0xf == 0 else { return nil }
        let questions = Int(bytes[4]) << 8 | Int(bytes[5])
        let answers = Int(bytes[6]) << 8 | Int(bytes[7])
        guard questions == 1, answers > 0, answers <= 64 else { return nil }
        var offset = 12
        guard let name = readName(bytes, &offset), offset + 4 <= bytes.count else { return nil }
        offset += 4
        var targets: [String: (target: String, ttl: UInt32)] = [:]
        for _ in 0..<answers {
            guard let owner = readName(bytes, &offset), offset + 10 <= bytes.count else { return nil }
            let type = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            let ttl = bytes[offset + 4..<offset + 8].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let length = Int(bytes[offset + 8]) << 8 | Int(bytes[offset + 9])
            offset += 10
            guard offset + length <= bytes.count else { return nil }
            if type == 5 {
                var at = offset
                guard let target = readName(bytes, &at) else { return nil }
                targets[owner] = (target, ttl)
            }
            offset += length
        }
        var chain: [String] = []
        var ttl = UInt32.max
        var current = name
        while let next = targets[current], chain.count < 16, !chain.contains(next.target), next.target != name {
            chain.append(next.target)
            ttl = min(ttl, next.ttl)
            current = next.target
        }
        return chain.isEmpty ? nil : Aliases(name: name, chain: chain, ttl: ttl)
    }

    /// A name at `offset`, following compression pointers, lowercased and
    /// without the trailing dot. Moves `offset` past it.
    static func readName(_ bytes: [UInt8], _ offset: inout Int) -> String? {
        var labels: [String] = []
        var at = offset
        var jumped = false
        var jumps = 0
        var length = 0
        while true {
            guard at < bytes.count else { return nil }
            let size = Int(bytes[at])
            if size & 0xc0 == 0xc0 {
                guard at + 1 < bytes.count, jumps < 32 else { return nil }
                let pointer = (size & 0x3f) << 8 | Int(bytes[at + 1])
                if !jumped { offset = at + 2 }
                jumped = true
                jumps += 1
                at = pointer
                continue
            }
            guard size & 0xc0 == 0 else { return nil }
            if size == 0 {
                if !jumped { offset = at + 1 }
                break
            }
            guard at + 1 + size <= bytes.count else { return nil }
            length += size + 1
            guard length <= 255 else { return nil }
            labels.append(String(decoding: bytes[at + 1...at + size], as: UTF8.self).lowercased())
            at += 1 + size
        }
        return labels.isEmpty ? nil : labels.joined(separator: ".")
    }
}

/// The aliases lately seen in lookups' answers, each kept a while (#255).
public struct AliasMemory {

    /// However short the answer said, an alias is kept this long: the
    /// connection it was looked up for may come a little later.
    public static let shortest: TimeInterval = 5 * 60
    public static let longest: TimeInterval = 60 * 60
    public static let capacity = 20_000

    private var entries: [String: (chain: [String], expires: Date)] = [:]

    public init() {}

    public var count: Int { entries.count }

    public mutating func learn(_ aliases: DNSAnswer.Aliases, now: Date = Date()) {
        let keep = min(max(TimeInterval(aliases.ttl), Self.shortest), Self.longest)
        entries[aliases.name] = (aliases.chain, now.addingTimeInterval(keep))
        if entries.count > Self.capacity { trim(now: now) }
    }

    /// The aliases `name` led through, while they're remembered.
    public func chain(of name: String, now: Date = Date()) -> [String] {
        guard let entry = entries[name.lowercased()], entry.expires > now else { return [] }
        return entry.chain
    }

    /// The expired first, then the soonest to expire, down to nine tenths.
    private mutating func trim(now: Date) {
        entries = entries.filter { $0.value.expires > now }
        let excess = entries.count - Self.capacity * 9 / 10
        guard excess > 0 else { return }
        for key in entries.sorted(by: { $0.value.expires < $1.value.expires }).prefix(excess).map(\.key) {
            entries[key] = nil
        }
    }
}
