/// Packet lengths for one peer in a short capture bucket. Whole buckets can
/// use their totals. On a nettop sampling boundary, keep each datagram on
/// exactly one side instead of dropping the whole bucket.
public struct TimedUDPCounts {
    private struct Packet {
        let timestamp: Double
        let signedBytes: Int64
    }

    private var packets: [Packet] = []
    public private(set) var bytesIn: Int64 = 0
    public private(set) var bytesOut: Int64 = 0
    public var count: Int { packets.count }

    public init() {}

    public mutating func record(timestamp: Double, bytes: Int64, inbound: Bool) {
        packets.append(Packet(timestamp: timestamp, signedBytes: inbound ? bytes : -bytes))
        if inbound { bytesIn += bytes } else { bytesOut += bytes }
    }

    public func bytes(in interval: Range<Double>) -> (incoming: Int64, outgoing: Int64) {
        var incoming: Int64 = 0
        var outgoing: Int64 = 0
        for packet in packets where interval.contains(packet.timestamp) {
            if packet.signedBytes > 0 {
                incoming += packet.signedBytes
            } else {
                outgoing -= packet.signedBytes
            }
        }
        return (incoming, outgoing)
    }
}
