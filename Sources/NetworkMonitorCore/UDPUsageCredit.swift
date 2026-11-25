import Foundation
import PacketUsage

struct NettopUDPSocket: Equatable {
    let socket: UDPObservation.Socket
    let hasWildcardPeer: Bool
    let bytesIn: Int64
    let bytesOut: Int64
    let flow: UDPObservation.Flow?

    var hasTrafficWithoutPeer: Bool {
        hasWildcardPeer && (bytesIn > 0 || bytesOut > 0)
    }
}

/// nettop gives unconnected UDP sockets a byte count and no remote address.
/// Correct that count only with traffic observed at the matching physical
/// socket. A socket can talk to a LAN peer and an internet peer in the same
/// interval, and packets missing from the capture stay in internet usage.
public enum UDPUsageCredit {
    public static func apply(to sample: [NettopRow], peers: [UDPPeerUsage], interfaces: Set<String>) -> [NettopRow] {
        guard !peers.isEmpty else { return sample }
        let counts = Dictionary(grouping: peers, by: \.socket)
        return sample.map { row in
            guard row.udpSockets.contains(where: \.hasTrafficWithoutPeer) else { return row }
            var result = row
            let sockets = Dictionary(grouping: row.udpSockets, by: \.socket)
            for (socket, candidates) in sockets {
                guard candidates.count == 1, let flow = candidates.first, flow.hasTrafficWithoutPeer,
                      interfaces.contains(socket.interface), let observations = counts[socket] else { continue }
                let local = observations.filter { scope($0) == .localUnicast }
                let internet = observations.filter { scope($0) == .internet }
                let incoming = min(local.reduce(0) { $0 + $1.bytesIn },
                                   max(0, flow.bytesIn - internet.reduce(0) { $0 + $1.bytesIn }),
                                   result.internetBytesIn)
                let outgoing = min(local.reduce(0) { $0 + $1.bytesOut },
                                   max(0, flow.bytesOut - internet.reduce(0) { $0 + $1.bytesOut }),
                                   result.internetBytesOut)
                result.localBytesIn += incoming
                result.localBytesOut += outgoing
                result.subtractableLocalIn += incoming
                result.subtractableLocalOut += outgoing
            }
            return result
        }
    }

    /// The physical capture must cover the exact nettop interval, including
    /// the first delta whose starting timestamp comes from the priming sample.
    public static func captureInterval(for sample: [NettopRow], near now: Date) -> Range<Date>? {
        guard let first = sample.first, let started = first.captureStartTime, let finished = first.captureTime,
              let end = timestamp(finished, near: now, limit: 2),
              let start = timestamp(started, near: end, limit: 12), start < end else { return nil }
        return start..<end
    }

    /// nettop prints local clock time without a date. Choose the occurrence
    /// nearest receipt, including the other side of midnight or a DST change.
    private static func timestamp(_ value: String, near now: Date, limit: TimeInterval) -> Date? {
        let fields = value.split(separator: ":")
        guard fields.count == 3, let hour = Int(fields[0]), let minute = Int(fields[1]),
              let second = Double(fields[2]), (0...23).contains(hour), (0...59).contains(minute),
              (0..<60).contains(second) else { return nil }
        let current = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: now)
        guard let h = current.hour, let m = current.minute, let s = current.second else { return nil }
        let localNow = Double(h * 3600 + m * 60 + s) + Double(current.nanosecond ?? 0) / 1e9
        let difference = Double(hour * 3600 + minute * 60) + second - localNow
        let nearest = (difference + 43200).truncatingRemainder(dividingBy: 86400)
        let offset = (nearest < 0 ? nearest + 86400 : nearest) - 43200
        guard abs(offset) <= limit else { return nil }
        return now.addingTimeInterval(offset)
    }

    private static func scope(_ observation: UDPPeerUsage) -> TrafficScope {
        let address = observation.address
        if observation.socket.family == 4 { return RemoteEndpoint.scopeOfIPv4(address) }
        if let mapped = RemoteEndpoint.ipv4Mapped(address) { return RemoteEndpoint.scopeOfIPv4(mapped) }
        return RemoteEndpoint.scopeOfIPv6(address)
    }
}
