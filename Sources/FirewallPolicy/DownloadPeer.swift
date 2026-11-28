import Foundation

/// Eligibility for the opt-in receive accounting. Firewall and LAN decisions
/// continue to use the socket address.
public enum DownloadPeer: String {
    case missing
    case otherPort = "other-port"
    case local
    case external = "external-443"
    case namedPlaceholder = "named-placeholder"

    public var isEligible: Bool { self == .external || self == .namedPlaceholder }

    public init(address: String?, port: String?, hostname: String?, outboundUDP: Bool,
                namedPlaceholderAtOpen: Bool = false) {
        guard let address, let port else { self = .missing; return }
        guard port == "443" else { self = .otherPort; return }
        guard FirewallPolicy.isLocal(address) else { self = .external; return }
        // macOS can represent a relayed, named flow with an unspecified
        // IPv6 peer. A concrete private or loopback address still means LAN.
        guard outboundUDP, address == "::",
              hostname.map(Self.hasPublicName) ?? namedPlaceholderAtOpen else {
            self = .local
            return
        }
        self = .namedPlaceholder
    }

    private static func hasPublicName(_ hostname: String) -> Bool {
        let name = hostname.hasSuffix(".") ? String(hostname.dropLast()) : hostname
        guard name.utf8.count <= 253 else { return false }
        let labels = name.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let suffix = labels.last,
              suffix != "arpa", suffix != "onion",
              SiteName.suffixes.rules.contains(String(suffix))
                || SiteName.suffixes.wildcards.contains(String(suffix)) else { return false }
        return labels.allSatisfy { label in
            (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
}
