import Foundation

/// A snapshot of one interface's lifetime byte counters.
public struct InterfaceSnapshot: Equatable {
    public let name: String
    public let bytesIn: UInt64
    public let bytesOut: UInt64

    public init(name: String, bytesIn: UInt64, bytesOut: UInt64) {
        self.name = name
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

/// Reads per-interface byte counters from the kernel.
///
/// Deliberately uses `sysctl(NET_RT_IFLIST2)` rather than `getifaddrs()`. The
/// `if_data` struct that `getifaddrs` hands back carries **32-bit** byte
/// counters (`u_int32_t ifi_ibytes`), which wrap every 4 GiB — en0 on the
/// development machine had already wrapped once, reporting 1.23 GB against a
/// true 5.52 GB. `NET_RT_IFLIST2` returns `if_msghdr2`, whose `if_data64`
/// payload has 64-bit counters. This is the same source `netstat -ib` uses.
public enum InterfaceCounters {

    /// Interfaces excluded by name even though the kernel classifies them
    /// identically to real hardware.
    ///
    /// `awdl0` (Apple Wireless Direct Link — AirDrop, Sidecar, Handoff,
    /// Continuity) reports `ifi_type = IFT_ETHER` and flags `0x8863`, byte for
    /// byte the same as `en0`, so type and flags cannot distinguish it. It must
    /// be excluded by name or peer-to-peer traffic inflates internet usage.
    public static let excludedPrefixes = [
        "awdl",    // AirDrop / Continuity / Sidecar — not internet
        "llw",     // low-latency WLAN, same peer-to-peer family
        "ap",      // Wi-Fi access-point mode
        "bridge",  // Internet Sharing / Thunderbolt Bridge — double-counts en*
        "bond",    // link aggregation — double-counts its members
        "vmenet",  // VM host networking — double-counts the physical NIC
        "anpi",    // Apple internal management NIC
        "XHC",     // USB host controller pseudo-interface
    ]

    /// True for interfaces whose traffic should count toward internet usage.
    ///
    /// Requiring `IFT_ETHER` excludes every `utun*`/`ipsec*` tunnel
    /// (`ifi_type = IFT_OTHER`). That is intentional and is what makes VPN
    /// traffic count exactly once: the plaintext bytes on `utun` are ignored
    /// and the encrypted bytes are counted as they leave the physical NIC.
    /// Summing both would double-count every VPN byte.
    public static func isCountable(name: String, ifiType: Int32, flags: Int32) -> Bool {
        guard flags & IFF_LOOPBACK == 0 else { return false }
        guard flags & IFF_UP != 0 else { return false }
        guard ifiType == Int32(IFT_ETHER) else { return false }
        return !excludedPrefixes.contains { name.hasPrefix($0) }
    }

    /// Every countable interface's current counters. Empty on sysctl failure,
    /// which the sampler treats as "no data this tick" rather than as zero.
    public static func read() -> [InterfaceSnapshot] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]

        var needed = 0
        guard sysctl(&mib, 6, nil, &needed, nil, 0) == 0, needed > 0 else { return [] }

        // The table can grow between sizing and reading (an interface appearing),
        // so retry a couple of times before giving up for this tick.
        for _ in 0..<3 {
            var length = needed
            var buffer = [UInt8](repeating: 0, count: length)
            if sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 {
                return parse(buffer, length: length)
            }
            guard errno == ENOMEM else { return [] }
            guard sysctl(&mib, 6, nil, &needed, nil, 0) == 0 else { return [] }
        }
        return []
    }

    private static func parse(_ buffer: [UInt8], length: Int) -> [InterfaceSnapshot] {
        var result: [InterfaceSnapshot] = []
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let message = base.advanced(by: offset)
                let header = message.assumingMemoryBound(to: if_msghdr.self).pointee
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0, offset + messageLength <= length else { break }
                defer { offset += messageLength }

                guard Int32(header.ifm_type) == RTM_IFINFO2,
                      messageLength >= MemoryLayout<if_msghdr2>.size + MemoryLayout<sockaddr_dl>.size
                else { continue }

                let header2 = message.assumingMemoryBound(to: if_msghdr2.self).pointee
                let link = message.advanced(by: MemoryLayout<if_msghdr2>.size)
                                  .assumingMemoryBound(to: sockaddr_dl.self)

                let name = interfaceName(link.pointee)
                guard !name.isEmpty,
                      isCountable(name: name,
                                  ifiType: Int32(header2.ifm_data.ifi_type),
                                  flags: header2.ifm_flags)
                else { continue }

                result.append(InterfaceSnapshot(name: name,
                                                bytesIn: header2.ifm_data.ifi_ibytes,
                                                bytesOut: header2.ifm_data.ifi_obytes))
            }
        }
        return result
    }

    /// `sdl_data` packs the interface name (length `sdl_nlen`) ahead of the
    /// link-layer address, and is `CChar` so it needs a signed→unsigned hop.
    private static func interfaceName(_ link: sockaddr_dl) -> String {
        let nameLength = Int(link.sdl_nlen)
        guard nameLength > 0 else { return "" }
        return withUnsafeBytes(of: link.sdl_data) { bytes in
            let clamped = min(nameLength, bytes.count)
            return String(decoding: bytes.prefix(clamped).map { UInt8($0) }, as: UTF8.self)
        }
    }
}
