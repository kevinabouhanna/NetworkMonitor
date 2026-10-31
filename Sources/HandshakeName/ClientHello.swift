import Foundation

/// Bounds-checked reading of network byte order. A read past what's here
/// fails rather than traps.
struct ByteReader {
    let bytes: [UInt8]
    var index: Int
    /// Where the structure being read ends, which may lie past what has
    /// arrived so far.
    let end: Int

    init(_ bytes: [UInt8], from start: Int = 0, end: Int? = nil) {
        self.bytes = bytes
        index = start
        self.end = end ?? bytes.count
    }

    private var limit: Int { min(end, bytes.count) }

    /// What a failed read means: the structure is all here, so it's
    /// malformed, or the rest hasn't arrived.
    var shortfall: HandshakeName.Outcome { end <= bytes.count ? .none : .needMore }

    mutating func u8() -> Int? {
        guard index + 1 <= limit else { return nil }
        defer { index += 1 }
        return Int(bytes[index])
    }

    mutating func u16() -> Int? {
        guard index + 2 <= limit else { return nil }
        defer { index += 2 }
        return Int(bytes[index]) << 8 | Int(bytes[index + 1])
    }

    mutating func u24() -> Int? {
        guard index + 3 <= limit else { return nil }
        defer { index += 3 }
        return Int(bytes[index]) << 16 | Int(bytes[index + 1]) << 8 | Int(bytes[index + 2])
    }

    mutating func u32() -> UInt32? {
        guard index + 4 <= limit else { return nil }
        defer { index += 4 }
        return bytes[index..<index + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// A QUIC variable-length integer (RFC 9000 §16).
    mutating func varint() -> Int? {
        guard index < limit else { return nil }
        let length = 1 << (bytes[index] >> 6)
        guard index + length <= limit else { return nil }
        var value = UInt64(bytes[index] & 0x3f)
        for offset in 1..<length { value = value << 8 | UInt64(bytes[index + offset]) }
        index += length
        return value <= UInt64(Int.max) ? Int(value) : nil
    }

    mutating func take(_ count: Int) -> ArraySlice<UInt8>? {
        guard count >= 0, index + count <= limit else { return nil }
        defer { index += count }
        return bytes[index..<index + count]
    }

    mutating func skip(_ count: Int) -> Bool {
        take(count) != nil
    }
}

/// The server_name in a TLS ClientHello (RFC 8446 §4.1.2, RFC 6066 §3).
enum ClientHello {

    static let maxLength = 65_536

    /// Handshake bytes that should begin with a ClientHello: no record layer,
    /// as QUIC carries it and as TLS records unwrap to.
    static func serverName(inHandshake bytes: [UInt8]) -> HandshakeName.Outcome {
        var header = ByteReader(bytes)
        guard let type = header.u8() else { return .needMore }
        guard type == 1 else { return .none }
        guard let length = header.u24() else { return .needMore }
        guard length >= 38, length <= maxLength else { return .none }

        var hello = ByteReader(bytes, from: 4, end: 4 + length)
        // legacy_version and random
        guard hello.skip(34) else { return hello.shortfall }
        guard let session = hello.u8(), hello.skip(session) else { return hello.shortfall }
        guard let suites = hello.u16(), hello.skip(suites) else { return hello.shortfall }
        guard let methods = hello.u8(), hello.skip(methods) else { return hello.shortfall }
        // No extensions at all: no name.
        guard hello.index < hello.end else { return .none }
        guard let extensionsLength = hello.u16() else { return hello.shortfall }

        var extensions = ByteReader(bytes, from: hello.index, end: min(hello.end, hello.index + extensionsLength))
        while extensions.index < extensions.end {
            guard let type = extensions.u16(), let size = extensions.u16() else { return extensions.shortfall }
            if type == 0 {
                guard let body = extensions.take(size) else { return extensions.shortfall }
                return hostName(in: Array(body))
            }
            guard extensions.skip(size) else { return extensions.shortfall }
        }
        return .none
    }

    /// The first host_name in a server_name extension's list.
    private static func hostName(in body: [UInt8]) -> HandshakeName.Outcome {
        var list = ByteReader(body)
        guard let listLength = list.u16() else { return .none }
        var entries = ByteReader(body, from: 2, end: min(body.count, 2 + listLength))
        while let kind = entries.u8(), let size = entries.u16(), let name = entries.take(size) {
            if kind == 0 { return validated(name).map(HandshakeName.Outcome.name) ?? .none }
        }
        return .none
    }

    /// A DNS name as servers are keyed: lowercase, no trailing dot, letters,
    /// digits, hyphens and underscores between dots.
    static func validated(_ raw: ArraySlice<UInt8>) -> String? {
        guard !raw.isEmpty, raw.count <= 254 else { return nil }
        var name = raw
        if name.last == UInt8(ascii: ".") { name = name.dropLast() }
        guard !name.isEmpty, name.first != UInt8(ascii: "."), name.count <= 253 else { return nil }
        var previousDot = false
        for byte in name {
            let isDot = byte == UInt8(ascii: ".")
            if isDot && previousDot { return nil }
            previousDot = isDot
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."):
                continue
            default:
                return nil
            }
        }
        return String(decoding: name, as: UTF8.self).lowercased()
    }
}
