import Foundation

/// An internet address as a number, so it can be found in a sorted list of
/// ranges.
public enum IPAddress: Hashable {
    case v4(UInt32)
    case v6(IPv6Value)

    /// Parses `142.250.180.14` or `2a00:1450:4001:82b::200e`.
    ///
    /// An IPv4 address written as IPv6 is read as the IPv4 address it carries,
    /// because DB-IP lists it only under IPv4. That's an IPv4-mapped address
    /// (`::ffff:142.250.180.14`), as a dual-stack socket reports one, or NAT64's
    /// well-known prefix (`64:ff9b::142.250.180.14`), which is how a Mac on an
    /// IPv6-only network reaches an IPv4 server.
    public init?(_ text: String) {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            self = .v4(UInt32(bigEndian: v4.s_addr))
            return
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, text, &v6) == 1 else { return nil }
        let value = withUnsafeBytes(of: &v6) { bytes -> IPv6Value in
            var high: UInt64 = 0, low: UInt64 = 0
            for index in 0..<8 { high = high << 8 | UInt64(bytes[index]) }
            for index in 8..<16 { low = low << 8 | UInt64(bytes[index]) }
            return IPv6Value(high: high, low: low)
        }
        let mapped = value.high == 0 && value.low >> 32 == 0xFFFF
        let nat64 = value.high == 0x0064_FF9B_0000_0000 && value.low >> 32 == 0
        if mapped || nat64 {
            self = .v4(UInt32(truncatingIfNeeded: value.low))
        } else {
            self = .v6(value)
        }
    }
}

/// A 128-bit address. Swift's own `UInt128` needs macOS 15, and the app
/// supports 13.
public struct IPv6Value: Hashable, Comparable {
    public var high: UInt64
    public var low: UInt64

    public init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    public static let max = IPv6Value(high: .max, low: .max)

    public static func < (lhs: IPv6Value, rhs: IPv6Value) -> Bool {
        lhs.high != rhs.high ? lhs.high < rhs.high : lhs.low < rhs.low
    }

    /// The next address up. Not defined for `max`, which callers check first.
    var successor: IPv6Value {
        low == .max ? IPv6Value(high: high + 1, low: 0) : IPv6Value(high: high, low: low + 1)
    }
}
