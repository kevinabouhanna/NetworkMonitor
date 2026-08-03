import Foundation
import SystemConfiguration

/// Decides whether the connection currently carrying the default route costs
/// money by the gigabyte.
///
/// `NWPath.isExpensive` is the signal macOS provides, and it works — the
/// persisted store on the development machine holds a bucket
/// `gw:9a:50:2e:c2:af:64` recorded as `kind = hotspot`, a locally administered
/// MAC of the kind iOS randomises for Personal Hotspot. But it only fires when
/// macOS *recognises* the link, and the feature has to behave identically for
/// USB tethering and for a stranger's Android phone. So `isExpensive` is one
/// signal of six rather than the definition.
///
/// The ranks are ordered by how much they can be trusted, and the first one that
/// answers wins. Everything below rank 2 is convention rather than guarantee: a
/// vendor is free to hand out a different subnet tomorrow. That is acceptable
/// because of which way they fail — a missed signal means metering does not
/// engage, never that an ordinary home network is wrongly suppressed — and
/// because rank 1 lets the user settle any case the rest gets wrong.
public enum MeteredHeuristic {

    /// Everything the verdict is computed from. A plain value so the decision is
    /// testable without a network.
    public struct Signals: Equatable {
        /// The user's per-network decision, if they have made one. `true` forces
        /// metered, `false` forces unmetered; `nil` leaves it to the heuristic.
        public var userOverride: Bool?
        /// `NWPath.isExpensive`.
        public var isExpensive: Bool
        /// `NWPath.isConstrained` — the link is in Low Data Mode.
        public var isConstrained: Bool
        /// IPv4 address of the default gateway, e.g. `172.20.10.1`.
        public var gatewayIP: String?
        /// Localised name of the interface carrying the default route, as macOS
        /// shows it in Network settings — `"iPhone USB"`, `"Wi-Fi"`.
        public var interfaceDisplayName: String?

        public init(userOverride: Bool? = nil,
                    isExpensive: Bool = false,
                    isConstrained: Bool = false,
                    gatewayIP: String? = nil,
                    interfaceDisplayName: String? = nil) {
            self.userOverride = userOverride
            self.isExpensive = isExpensive
            self.isConstrained = isConstrained
            self.gatewayIP = gatewayIP
            self.interfaceDisplayName = interfaceDisplayName
        }
    }

    /// Why the verdict came out the way it did. Carried rather than reduced to a
    /// `Bool` so the popover can say *why* a connection is being metered, which
    /// is the difference between a feature the user trusts and one that seems to
    /// act at random.
    public enum Verdict: String, Codable, Equatable {
        /// Rank 1 — the user marked this network metered.
        case userMarked
        /// Rank 1 — the user marked this network *not* metered.
        case userCleared
        /// Rank 2 — `NWPath.isExpensive`.
        case expensive
        /// Rank 3 — gateway inside iOS Personal Hotspot's fixed range.
        case iOSHotspotSubnet
        /// Rank 4 — gateway inside a conventional Android tethering range.
        case androidTetherSubnet
        /// Rank 5 — the default route runs over an interface named like a tether.
        case tetherInterface
        /// Rank 6 — the link is already in Low Data Mode, which is a statement
        /// about cost that someone has made deliberately.
        case constrained
        /// Nothing fired.
        case unmetered

        public var isMetered: Bool {
            switch self {
            case .userCleared, .unmetered: return false
            default: return true
            }
        }

        /// Shown in the popover next to the METERED badge.
        public var explanation: String {
            switch self {
            case .userMarked:          return "You marked this network as metered."
            case .userCleared:         return "You marked this network as not metered."
            case .expensive:           return "macOS reports this connection as a hotspot."
            case .iOSHotspotSubnet:    return "This looks like an iPhone Personal Hotspot."
            case .androidTetherSubnet: return "This looks like a phone sharing its connection."
            case .tetherInterface:     return "You're tethered through a phone."
            case .constrained:         return "This network is in Low Data Mode."
            case .unmetered:           return "This connection isn't metered."
            }
        }
    }

    /// iOS Personal Hotspot hands out `172.20.10.1` and a /28, over Wi-Fi *and*
    /// over USB, and has done so across every iOS version this has been seen on.
    /// It is the one signal that catches a hotspot from a phone macOS has never
    /// been introduced to, which is exactly the case `isExpensive` misses.
    public static let iOSHotspotRange = IPv4Range(prefix: "172.20.10.0", bits: 28)

    /// Android's long-standing defaults: `192.168.42.0/24` for USB tethering and
    /// `192.168.43.0/24` for Wi-Fi. Vendors do override these, so this rank is
    /// the weakest of the automatic ones and is expected to drift.
    public static let androidTetherRanges = [
        IPv4Range(prefix: "192.168.42.0", bits: 24),
        IPv4Range(prefix: "192.168.43.0", bits: 24),
    ]

    /// Interface-name fragments that mean "this is a phone", matched
    /// case-insensitively against the localised display name.
    ///
    /// **`"usb"` is deliberately not in this list.** The development machine has
    /// a wired adapter called `USB 10/100 LAN`, and matching the bare word would
    /// meter an Ethernet dongle — the one failure direction that actually harms
    /// the user, since it would suppress updates on an unmetered connection.
    public static let tetherNameFragments = ["iphone", "ipad", "usb tether", "rndis", "android"]

    public static func verdict(for signals: Signals) -> Verdict {
        // Rank 1. An explicit decision outranks every inference, in both
        // directions — the point of the override is to end the argument.
        if let override = signals.userOverride {
            return override ? .userMarked : .userCleared
        }

        // Rank 2.
        if signals.isExpensive { return .expensive }

        // Ranks 3 and 4.
        if let gateway = signals.gatewayIP, let address = IPv4Address(gateway) {
            if iOSHotspotRange.contains(address) { return .iOSHotspotSubnet }
            if androidTetherRanges.contains(where: { $0.contains(address) }) {
                return .androidTetherSubnet
            }
        }

        // Rank 5.
        if let name = signals.interfaceDisplayName?.lowercased(),
           tetherNameFragments.contains(where: { name.contains($0) }) {
            return .tetherInterface
        }

        // Rank 6.
        if signals.isConstrained { return .constrained }

        return .unmetered
    }
}

// MARK: - Minimal IPv4 arithmetic

/// Just enough of an IPv4 address to test subnet membership.
///
/// `inet_pton` would do this, but a four-byte integer keeps the range check
/// pure, allocation-free and trivially testable, and the parsing rules here are
/// stricter than `inet_aton`'s — which accepts `10.1` and octal octets, both of
/// which would make the subnet ranks match things they should not.
public struct IPv4Address: Equatable {
    public let raw: UInt32

    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            // Reject "01", "+1", "" and anything non-decimal: a leading zero
            // means octal to some parsers and this one should not guess.
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part.count == 1 || part.first != "0",
                  let octet = UInt32(part), octet <= 255
            else { return nil }
            value = (value << 8) | octet
        }
        self.raw = value
    }
}

/// A CIDR range, held as a base address and a mask.
public struct IPv4Range {
    public let base: UInt32
    public let mask: UInt32

    public init(prefix: String, bits: UInt32) {
        precondition(bits <= 32)
        // `<<` by 32 is undefined for a 32-bit value, so the all-ones mask is
        // special-cased rather than computed.
        let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << (32 - bits)
        self.mask = mask
        self.base = (IPv4Address(prefix)?.raw ?? 0) & mask
    }

    public func contains(_ address: IPv4Address) -> Bool {
        address.raw & mask == base
    }
}

// MARK: - Live signal collection

/// Reads the two signals that do not come from `NWPath`.
public enum InterfaceNaming {

    /// Localised display name for a BSD interface — `en5` → `"iPhone USB"`.
    ///
    /// `SCNetworkInterfaceCopyAll` is a public, unprivileged API and needs no
    /// entitlement, which is why this is preferred over parsing
    /// `/Library/Preferences/SystemConfiguration/preferences.plist` even though
    /// that file is world-readable and holds the same information.
    public static func displayName(forBSDName bsdName: String) -> String? {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
            return nil
        }
        for interface in interfaces
        where SCNetworkInterfaceGetBSDName(interface) as String? == bsdName {
            return SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
        }
        return nil
    }
}
