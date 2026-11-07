import Foundation

// Encrypted lookups (#291): the system extension's DNS proxy sends each of the
// Mac's lookups over DNS over HTTPS to a resolver picked in Settings, so the
// internet provider and anyone on the network see neither the names nor,
// with ECH, the sites. Shared by the app, which configures it, and the
// extension, which does it.

public enum EncryptedDNS {

    /// A resolver that answers DNS over HTTPS at an address, so reaching it
    /// needs no lookup of its own.
    public struct Resolver: Equatable, Identifiable {
        public let id: String
        public let title: String
        public let url: URL
        /// Its policy, in a line, for the ⓘ.
        public let about: String
    }

    public static let resolvers: [Resolver] = [
        Resolver(id: "cloudflare", title: "Cloudflare", url: URL(string: "https://1.1.1.1/dns-query")!,
                 about: "1.1.1.1. Keeps no record of your address, and deletes its logs within a day."),
        Resolver(id: "quad9", title: "Quad9", url: URL(string: "https://9.9.9.9/dns-query")!,
                 about: "9.9.9.9. A Swiss non-profit; keeps no record of your address, and refuses known malware sites."),
        Resolver(id: "google", title: "Google", url: URL(string: "https://8.8.8.8/dns-query")!,
                 about: "8.8.8.8. Deletes your address from its logs within two days."),
    ]

    public static let defaultResolver = "cloudflare"

    public static func resolver(_ id: String?) -> Resolver {
        resolvers.first { $0.id == id } ?? resolvers[0]
    }

    /// The key in the DNS proxy's provider configuration naming the resolver.
    public static let resolverKey = "resolver"

    /// The answer, with the question's ID: a resolver may answer with 0.
    public static func answer(_ answer: Data, for question: Data) -> Data? {
        guard question.count >= 12, answer.count >= 12 else { return nil }
        var fixed = answer
        fixed.replaceSubrange(fixed.startIndex..<fixed.startIndex + 2,
                              with: question[question.startIndex..<question.startIndex + 2])
        return fixed
    }

    /// The name a query asks about, lowercased, without the final dot.
    public static func questionName(_ query: Data) -> String? {
        let bytes = [UInt8](query)
        guard bytes.count > 12, bytes[4] == 0, bytes[5] == 1 else { return nil }
        var labels: [String] = []
        var at = 12
        while at < bytes.count {
            let size = Int(bytes[at])
            if size == 0 { return labels.joined(separator: ".") }
            guard size < 64, at + 1 + size <= bytes.count else { return nil }
            labels.append(String(decoding: bytes[at + 1...at + size], as: UTF8.self).lowercased())
            at += 1 + size
        }
        return nil
    }

    /// Names only the network's own DNS servers know: the router, a printer,
    /// a work network's own names, and addresses on the local network looked
    /// up by number. They stay on the network, as they always went.
    public static func staysOnNetwork(_ name: String) -> Bool {
        if !name.contains(".") { return true }
        let local = ["local", "lan", "home", "internal", "intranet", "corp", "home.arpa", "localdomain"]
        if local.contains(where: { name == $0 || name.hasSuffix("." + $0) }) { return true }
        if name.hasSuffix(".in-addr.arpa") {
            let octets = name.dropLast(".in-addr.arpa".count).split(separator: ".").reversed().compactMap { Int($0) }
            guard let first = octets.first else { return true }
            let second = octets.dropFirst().first ?? -1
            return first == 10 || first == 127 || (first == 172 && (16...31).contains(second))
                || (first == 192 && second == 168) || (first == 169 && second == 254)
        }
        // Reverse lookups for IPv6 local addresses: fe80::/10 and fc00::/7.
        if name.hasSuffix(".ip6.arpa") {
            let nibbles = name.dropLast(".ip6.arpa".count).split(separator: ".").reversed()
            guard let first = nibbles.first else { return true }
            return first == "f" && ["e", "c", "d"].contains(nibbles.dropFirst().first.map(String.init) ?? "")
        }
        return false
    }

    /// Whether to try the encrypted resolver, or go straight to the network's
    /// own DNS servers for a while after it failed (#291). Pure, so it's
    /// tested on its own.
    public struct Fallback: Equatable {
        /// After this many failures in a row, the resolver is left alone…
        public static let failuresToPause = 3
        /// …for this long.
        public static let pause: TimeInterval = 60

        private var failures = 0
        private var pausedAt: Date?

        public init() {}

        public func triesEncrypted(now: Date = Date()) -> Bool {
            guard let pausedAt else { return true }
            return now.timeIntervalSince(pausedAt) >= Self.pause || now < pausedAt
        }

        public var isPaused: Bool { pausedAt != nil }

        public mutating func succeeded() {
            failures = 0
            pausedAt = nil
        }

        public mutating func failed(now: Date = Date()) {
            failures += 1
            if failures >= Self.failuresToPause {
                pausedAt = now
                failures = 0
            }
        }
    }
}
