import Foundation

/// One UDP datagram on your own network, as macOS's PKTAP interface reports it
/// (#753). Only these fields are kept, never the packet's contents.
public struct UDPObservation: Equatable {
    public struct Socket: Codable, Hashable {
        public let pid: Int32
        public let interface: String
        public let family: Int
        public let port: Int

        public init(pid: Int32, interface: String, family: Int, port: Int) {
            self.pid = pid
            self.interface = interface
            self.family = family
            self.port = port
        }
    }

    /// `tcpdump`'s filter: UDP whose two ends are both on your own network, so
    /// the kernel hands over nothing else. A datagram to or from the internet
    /// is never looked at, nor is multicast.
    ///
    /// The ranges `RemoteEndpoint` calls `localUnicast`, without loopback, which
    /// PKTAP sees too and the app doesn't count.
    public static let filter: String = {
        func both(_ ranges: [String]) -> String {
            let ends = ["src", "dst"].map { end in
                "(" + ranges.map { "\(end) net \($0)" }.joined(separator: " or ") + ")"
            }
            return "(" + ends.joined(separator: " and ") + ")"
        }
        return "udp and (" + both(["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16"])
            + " or " + both(["fe80::/10", "fc00::/7"]) + ")"
    }()

    public let socket: Socket
    public let remoteAddress: String
    public let bytes: Int64
    public let inbound: Bool

    /// One line of tcpdump's numeric, quiet PKTAP output.
    public init?(line: String) {
        guard let start = line.firstIndex(of: "("),
              let end = line.range(of: ") IP", range: start..<line.endIndex),
              let udp = line.range(of: ": UDP, length ", range: end.upperBound..<line.endIndex),
              let bytes = Int64(line[udp.upperBound...]), bytes > 0 else { return nil }
        let metadata = line[line.index(after: start)..<end.lowerBound].components(separatedBy: ", ")
        guard let interface = metadata.first, let direction = metadata.last,
              direction == "in" || direction == "out",
              let process = metadata.first(where: { $0.hasPrefix("proc ") }),
              let colon = process.lastIndex(of: ":"),
              let pid = Int32(process[process.index(after: colon)...]), pid > 0 else { return nil }

        let endpoints = line[end.upperBound..<udp.lowerBound]
        let ipv6 = endpoints.hasPrefix("6 ")
        guard ipv6 || endpoints.hasPrefix(" "),
              let arrow = endpoints.range(of: " > ") else { return nil }
        let source = endpoints[..<arrow.lowerBound].dropFirst(ipv6 ? 2 : 1)
        let destination = endpoints[arrow.upperBound...]
        let inbound = direction == "in"
        let local = inbound ? destination : source
        let remote = inbound ? source : destination
        guard let localDot = local.lastIndex(of: "."),
              let remoteDot = remote.lastIndex(of: "."),
              let port = Int(local[local.index(after: localDot)...]),
              (1...65535).contains(port), remoteDot != remote.startIndex else { return nil }
        let remoteHost = remote[..<remoteDot].split(separator: "%", maxSplits: 1).first
        guard let remoteHost else { return nil }
        self.socket = Socket(pid: pid, interface: interface, family: ipv6 ? 6 : 4, port: port)
        self.remoteAddress = String(remoteHost)
        self.bytes = bytes
        self.inbound = inbound
    }
}

/// What one socket moved on your own network since the capture started.
public struct UDPSocketUsage: Codable, Equatable {
    public let socket: UDPObservation.Socket
    public var bytesIn: Int64
    public var bytesOut: Int64

    public init(socket: UDPObservation.Socket, bytesIn: Int64 = 0, bytesOut: Int64 = 0) {
        self.socket = socket
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

/// The helper's answer: running counts, so that asking takes nothing away from
/// the next ask, or from another account's copy of the app.
public struct UDPUsageSnapshot: Codable {
    /// New whenever the counts start again from zero.
    public let epoch: UUID
    public let sockets: [UDPSocketUsage]

    public init(epoch: UUID, sockets: [UDPSocketUsage]) {
        self.epoch = epoch
        self.sockets = sockets
    }
}

/// The running counts behind a snapshot.
public struct UDPUsageCounts {
    /// Past this many the counts start again, under a new epoch, which costs
    /// one sample's correction.
    public static let maximumSockets = 4096
    /// A socket this long without a packet is left out, and counted from zero
    /// if it's seen again: longer than any two questions are apart.
    public static let forgetAfter: TimeInterval = 60

    public private(set) var epoch = UUID()
    private var sockets: [UDPObservation.Socket: (usage: UDPSocketUsage, seen: Date)] = [:]

    public init() {}

    public mutating func record(_ packet: UDPObservation, now: Date = Date()) {
        if sockets[packet.socket] == nil, sockets.count >= Self.maximumSockets {
            sockets = [:]
            epoch = UUID()
        }
        var usage = sockets[packet.socket]?.usage ?? UDPSocketUsage(socket: packet.socket)
        if packet.inbound { usage.bytesIn += packet.bytes } else { usage.bytesOut += packet.bytes }
        sockets[packet.socket] = (usage, now)
    }

    public mutating func snapshot(now: Date = Date()) -> UDPUsageSnapshot {
        sockets = sockets.filter { now.timeIntervalSince($0.value.seen) < Self.forgetAfter }
        return UDPUsageSnapshot(epoch: epoch, sockets: sockets.values.map(\.usage))
    }
}
