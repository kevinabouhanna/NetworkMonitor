import Foundation
import PacketUsage

struct NettopUDPSocket: Equatable {
    let port: Int
    /// `udp4 *:4000<->*:*`: nettop doesn't say where its bytes went.
    let hasWildcardPeer: Bool
    let bytesIn: Int64
    let bytesOut: Int64

    var hasTrafficWithoutPeer: Bool { hasWildcardPeer && (bytesIn > 0 || bytesOut > 0) }
}

/// Keeps your own network's traffic out of the internet figures when nettop
/// can't say where it went (#753).
///
/// An unconnected UDP socket, as NoMachine's and many calls' are, shows as
/// `udp4 *:4000<->*:*`: a byte count and no other end, which counts as
/// internet. The helper, when it's allowed, counts what each socket moved
/// between two addresses on your own network, and that much comes off. What it
/// didn't see stays internet.
///
/// Sockets are matched by process and port, not by family or interface: nettop
/// calls a dual-stack socket `udp6` while its packets are IPv4, and names no
/// interface for one that only receives.
///
/// The two counts are taken a moment apart, so what was seen on your own
/// network and not matched yet waits for the next sample, and no longer. What
/// comes off is never more than was seen, nor than the socket moved.
public struct UDPUsageCredit {
    /// Less than this in a sample isn't worth starting the capture for.
    public static let worthAsking: Int64 = 16 * 1024

    private struct Key: Hashable {
        let pid: Int32
        let port: Int
    }

    private var lastSnapshot: UDPUsageSnapshot?
    private var waiting: [Key: ByteCounts] = [:]
    private var carriers: [Int32: Bool] = [:]
    private let isCarrier: (Int32, String) -> Bool

    /// - Parameter isCarrier: a VPN or a proxy. Its socket to a gateway on your own
    ///   network carries the other apps' internet traffic, so it's left alone.
    public init(isCarrier: @escaping (Int32, String) -> Bool = { pid, name in
        TunnelCarrier.isCarrier(processName: name, path: AppIdentityResolver.executablePath(pid: pid))
    }) {
        self.isCarrier = isCarrier
    }

    /// The sample with what stayed on your own network marked so. `snapshot`
    /// asks the helper, and is only called when there's traffic it could place.
    public mutating func apply(to sample: [NettopRow], interfaces: () -> Set<String>,
                               snapshot: () -> UDPUsageSnapshot?) -> [NettopRow] {
        let unplaced = sample.reduce(Int64(0)) { total, row in
            row.udpSockets.reduce(total) { $0 + ($1.hasTrafficWithoutPeer ? $1.bytesIn + $1.bytesOut : 0) }
        }
        guard unplaced >= Self.worthAsking || (unplaced > 0 && lastSnapshot != nil) else { return sample }
        guard let latest = snapshot() else {
            lastSnapshot = nil
            waiting = [:]
            return sample
        }
        let seen = added(by: latest, interfaces: interfaces())
        var pool = waiting
        for (key, bytes) in seen { pool[key, default: ByteCounts(bytesIn: 0, bytesOut: 0)] += bytes }
        waiting = [:]
        guard !pool.isEmpty else { return sample }

        var corrected = sample
        var left = pool
        for index in corrected.indices {
            let row = corrected[index]
            guard row.udpSockets.contains(where: \.hasTrafficWithoutPeer), !carries(row) else { continue }
            for (port, sockets) in Dictionary(grouping: row.udpSockets, by: \.port) {
                let key = Key(pid: row.pid, port: port)
                // A connected socket on the same port is placed by its address
                // already, and which of the two a datagram was for can't be told.
                guard let bytes = pool[key], sockets.allSatisfy(\.hasWildcardPeer) else { continue }
                let incoming = min(bytes.bytesIn, sockets.reduce(0) { $0 + $1.bytesIn }, corrected[index].internetBytesIn)
                let outgoing = min(bytes.bytesOut, sockets.reduce(0) { $0 + $1.bytesOut }, corrected[index].internetBytesOut)
                corrected[index].localBytesIn += incoming
                corrected[index].localBytesOut += outgoing
                corrected[index].subtractableLocalIn += incoming
                corrected[index].subtractableLocalOut += outgoing
                left[key] = ByteCounts(bytesIn: bytes.bytesIn - incoming, bytesOut: bytes.bytesOut - outgoing)
            }
        }
        // One sample's worth at most, so bytes nettop never reports can't build
        // up and come off the internet's later.
        for (key, recent) in seen {
            guard let rest = left[key] else { continue }
            let kept = ByteCounts(bytesIn: min(rest.bytesIn, recent.bytesIn), bytesOut: min(rest.bytesOut, recent.bytesOut))
            if kept.bytesIn > 0 || kept.bytesOut > 0 { waiting[key] = kept }
        }
        return corrected
    }

    private mutating func added(by latest: UDPUsageSnapshot, interfaces: Set<String>) -> [Key: ByteCounts] {
        defer { lastSnapshot = latest }
        // Counts that started again can't be compared with the last ones.
        guard let previous = lastSnapshot, previous.epoch == latest.epoch else { return [:] }
        let before = Dictionary(previous.sockets.map { ($0.socket, $0) }, uniquingKeysWith: { first, _ in first })
        var added: [Key: ByteCounts] = [:]
        for usage in latest.sockets where interfaces.contains(usage.socket.interface) {
            let old = before[usage.socket]
            let bytes = ByteCounts(bytesIn: max(0, usage.bytesIn - (old?.bytesIn ?? 0)),
                                   bytesOut: max(0, usage.bytesOut - (old?.bytesOut ?? 0)))
            guard bytes.bytesIn > 0 || bytes.bytesOut > 0 else { continue }
            added[Key(pid: usage.socket.pid, port: usage.socket.port), default: ByteCounts(bytesIn: 0, bytesOut: 0)] += bytes
        }
        return added
    }

    private mutating func carries(_ row: NettopRow) -> Bool {
        if let known = carriers[row.pid] { return known }
        let answer = isCarrier(row.pid, row.processName)
        if carriers.count > 1024 { carriers = [:] }
        carriers[row.pid] = answer
        return answer
    }
}
