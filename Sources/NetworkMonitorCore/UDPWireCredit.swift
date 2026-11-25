import PacketUsage

/// Covers UDP/QUIC bytes nettop misses on a socket it does show. Over the
/// lifetime of a matched flow we bill the larger cumulative measurement, so
/// delayed socket counters can catch up without charging the same bytes again.
public struct UDPWireCredit {
    private struct Counter {
        var socket: Int64 = 0
        var wire: Int64 = 0

        mutating func add(socket delta: Int64, wire observed: Int64) -> Int64 {
            let before = max(socket, wire)
            let delta = max(0, delta)
            socket += delta
            wire += max(0, observed)
            return max(socket, wire) - before - delta
        }
    }

    private struct FlowCounters {
        var incoming = Counter()
        var outgoing = Counter()
    }

    private var flows: [UDPObservation.Flow: FlowCounters] = [:]

    public init() {}

    public mutating func apply(to sample: [NettopRow], peers: [UDPPeerUsage], interfaces: Set<String>,
                               canAttributeTo: (Int32) -> Bool = { $0 > 0 }) -> [NettopRow] {
        let byFlow = Dictionary(grouping: peers.compactMap { usage in
            usage.flow.map { ($0, usage) }
        }, by: { $0.0 })
        let sockets = sample.flatMap(\.udpSockets).compactMap(\.flow)
        let socketCounts = Dictionary(grouping: sockets, by: { $0 }).mapValues(\.count)
        var next: [UDPObservation.Flow: FlowCounters] = [:]
        var additions: [Int32: NettopRow] = [:]
        var adjusted = sample.map { row in
            var result = row
            for connection in row.udpSockets {
                guard let flow = connection.flow, socketCounts[flow] == 1,
                      interfaces.contains(flow.socket.interface) else { continue }
                let sightings = byFlow[flow]?.map { $0.1 } ?? []
                guard !sightings.isEmpty || flows[flow] != nil else { continue }
                var counters = flows[flow] ?? FlowCounters()
                let incoming = counters.incoming.add(socket: connection.bytesIn,
                                                      wire: sightings.reduce(0) { $0 + $1.bytesIn })
                let outgoing = counters.outgoing.add(socket: connection.bytesOut,
                                                      wire: sightings.reduce(0) { $0 + $1.bytesOut })
                next[flow] = counters

                let subtractIn = min(result.internetBytesIn, max(0, -incoming))
                let subtractOut = min(result.internetBytesOut, max(0, -outgoing))
                result.bytesIn -= subtractIn
                result.bytesOut -= subtractOut
                Self.debit(inbound: subtractIn, outbound: subtractOut, address: flow.remoteAddress, from: &result)

                let chargeIn = max(0, incoming), chargeOut = max(0, outgoing)
                guard chargeIn > 0 || chargeOut > 0 else { continue }
                let responsible = Set(sightings.compactMap(\.effectivePID).filter { $0 > 0 })
                if responsible.count == 1, let pid = responsible.first, pid != row.pid, canAttributeTo(pid) {
                    var owner = additions[pid] ?? NettopRow(pid: pid, processName: "", bytesIn: 0, bytesOut: 0)
                    Self.credit(inbound: chargeIn, outbound: chargeOut, address: flow.remoteAddress, to: &owner)
                    additions[pid] = owner
                } else {
                    Self.credit(inbound: chargeIn, outbound: chargeOut, address: flow.remoteAddress, to: &result)
                }
            }
            return result
        }
        for (pid, supplement) in additions {
            if let index = adjusted.firstIndex(where: { $0.pid == pid }) {
                adjusted[index].bytesIn += supplement.bytesIn
                adjusted[index].bytesOut += supplement.bytesOut
                for (address, bytes) in supplement.servers {
                    adjusted[index].servers[address, default: ByteCounts(bytesIn: 0, bytesOut: 0)] += bytes
                }
            } else {
                adjusted.append(supplement)
            }
        }
        flows = next
        return adjusted
    }

    private static func credit(inbound: Int64, outbound: Int64, address: String, to row: inout NettopRow) {
        row.bytesIn += inbound
        row.bytesOut += outbound
        row.servers[address, default: ByteCounts(bytesIn: 0, bytesOut: 0)]
            += ByteCounts(bytesIn: inbound, bytesOut: outbound)
    }

    private static func debit(inbound: Int64, outbound: Int64, address: String, from row: inout NettopRow) {
        guard var server = row.servers[address] else { return }
        server.bytesIn = max(0, server.bytesIn - inbound)
        server.bytesOut = max(0, server.bytesOut - outbound)
        row.servers[address] = server
    }
}
