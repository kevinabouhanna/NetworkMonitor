import Foundation

/// Whether traffic left the building, and if not, whether the figure can be
/// trusted well enough to subtract from the kernel's own count.
public enum TrafficScope: Equatable {
    /// A named LAN peer: an Apple TV being mirrored to, a NAS, the router. The
    /// socket belongs to one interface, so nettop's byte count for it is sound.
    case localUnicast
    /// Multicast and broadcast discovery — mDNS, SSDP, NetBIOS.
    ///
    /// Local beyond doubt, but the *quantity* is not trustworthy: these sockets
    /// are multi-homed, and nettop bills the socket's full byte count under every
    /// interface type it matches. Measured over 45 s, nettop reported 0.841 MB
    /// against the kernel's 0.506 MB for the same interfaces — the difference
    /// being multicast that went out over `awdl0`, which the interface counters
    /// deliberately exclude. Scoping nettop with `-t wifi -t wired` does not fix
    /// it, because the inflation is in the socket's own accounting.
    case localMulticast
    /// Crossed the internet, and is therefore what the app reports.
    case internet

    /// Everything except `internet` is kept out of the app rows.
    public var isLocal: Bool { self != .internet }

    /// Only unicast LAN traffic may be taken off the kernel's total. Subtracting
    /// an inflated multicast figure produced a headline smaller than the rows
    /// beneath it — see `NetworkBucket.internetBytesIn`.
    public var isSubtractable: Bool { self == .localUnicast }
}

/// Classifies the far end of one `nettop` connection row.
///
/// This is what makes "how much internet did this app use" mean what it says.
/// Screen mirroring to an Apple TV on the same Wi-Fi runs at 10–30 Mbps through
/// the router — 4–13 GB an hour — and every byte of it crosses `en0`, so the
/// kernel's interface counters see it and cannot tell it apart from a download.
/// Peer-to-peer AirPlay is already excluded because it uses `awdl0`
/// (`InterfaceCounters.excludedPrefixes`), but the router path is not, and neither
/// is Time Machine to a NAS, Apple content caching between your own devices, a
/// Plex stream from a home server, or an SMB copy.
///
/// Only `nettop`'s per-connection rows carry a remote address, which is why the
/// stream no longer passes `-P`: the per-socket rows it collapses are the only
/// place this information exists.
public enum RemoteEndpoint {

    /// Ports whose wildcard sockets are local by definition. A multicast listener
    /// has no fixed peer, so the row reads `udp4 *:5353<->*:*` and only the local
    /// port identifies it. mDNS alone was 73.6% of all connection bytes when
    /// measured on the development machine — misfiling it as internet would swamp
    /// the figure it is meant to protect.
    public static let localWildcardPorts: Set<Int> = [
        5353,          // mDNS / Bonjour
        5355,          // LLMNR
        1900,          // SSDP / UPnP discovery
        5350, 5351,    // NAT-PMP
        137, 138,      // NetBIOS name and datagram service
        67, 68,        // DHCP
        547, 546,      // DHCPv6
    ]

    /// Classifies one label, e.g. `tcp4 192.168.1.107:54524<->142.251.173.188:443`.
    ///
    /// **Anything not provably local counts as internet.** An unparseable row must
    /// never quietly disappear from the total: under-reporting usage is the one
    /// error this app cannot afford, and a row it cannot read is not evidence of
    /// staying on the LAN.
    public static func scope(connectionLabel label: String) -> TrafficScope {
        guard let separator = label.range(of: "<->") else { return .internet }
        let isIPv6 = label.hasPrefix("tcp6") || label.hasPrefix("udp6")
        let remote = String(label[separator.upperBound...])
            .trimmingCharacters(in: .whitespaces)

        // A wildcard remote means a socket with no fixed peer; the local port is
        // the only clue to what it is.
        if remote.hasPrefix("*") {
            let local = String(label[..<separator.lowerBound])
            return localWildcardPorts.contains(port(of: local, isIPv6: isIPv6) ?? -1)
                ? .localMulticast : .internet
        }

        guard let host = host(of: remote, isIPv6: isIPv6) else { return .internet }
        return isIPv6 ? scopeOfIPv6(host) : scopeOfIPv4(host)
    }

    /// Strips the port, and an IPv6 zone such as `%en0`.
    ///
    /// The two families are punctuated differently — `192.168.1.1:443` against
    /// `fe80::1c98:eeba:57c2:d2da%en0.54527` — so the protocol token decides
    /// whether the port hangs off the last colon or the last dot. Splitting an
    /// IPv6 address on its last colon would silently truncate the address.
    public static func host(of endpoint: String, isIPv6: Bool) -> String? {
        var value = endpoint
        if let space = value.lastIndex(of: " ") { value = String(value[value.index(after: space)...]) }
        let cut = isIPv6 ? value.lastIndex(of: ".") : value.lastIndex(of: ":")
        guard let cut else { return nil }
        var host = String(value[..<cut])
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        return host.isEmpty ? nil : host
    }

    public static func port(of endpoint: String, isIPv6: Bool) -> Int? {
        let cut = isIPv6 ? endpoint.lastIndex(of: ".") : endpoint.lastIndex(of: ":")
        guard let cut else { return nil }
        return Int(endpoint[endpoint.index(after: cut)...])
    }

    /// - Note: carrier-grade NAT (`100.64/10`) is deliberately **internet**. It is
    ///   private by RFC 6598 and most address libraries report it as such, but it
    ///   is what Tailscale hands out and what mobile carriers NAT behind — traffic
    ///   there really does leave the building, and hiding it would under-report.
    public static func scopeOfIPv4(_ host: String) -> TrafficScope {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else {
            return .internet
        }
        switch (parts[0], parts[1]) {
        case (10, _):                     return .localUnicast    // 10/8
        case (127, _):                    return .localUnicast    // loopback
        case (169, 254):                  return .localUnicast    // link-local
        case (172, 16...31):              return .localUnicast    // 172.16/12
        case (192, 168):                  return .localUnicast    // 192.168/16
        case (224...239, _):              return .localMulticast
        case (255, 255) where parts[2] == 255 && parts[3] == 255:
                                          return .localMulticast  // broadcast
        default:                          return .internet
        }
    }

    public static func scopeOfIPv6(_ host: String) -> TrafficScope {
        let value = host.lowercased()
        if value == "::1" { return .localUnicast }
        if value.hasPrefix("ff") { return .localMulticast }
        if value.hasPrefix("fe8") || value.hasPrefix("fe9")
            || value.hasPrefix("fea") || value.hasPrefix("feb") {
            return .localUnicast                                      // fe80::/10
        }
        if value.hasPrefix("fc") || value.hasPrefix("fd") { return .localUnicast }  // ULA
        return .internet
    }
}
