import Foundation

/// A physical UDP datagram as reported by macOS's PKTAP interface. The
/// capture backend keeps just these fields, never the packet contents.
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

    public let timestamp: Double?
    public let socket: Socket
    public let remoteAddress: String
    public let bytes: Int64
    public let inbound: Bool

    /// Parses tcpdump's numeric, quiet PKTAP output. The timestamp and any
    /// effective process label are immaterial to identifying the socket.
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
        timestamp = Double(line.prefix(while: { !$0.isWhitespace }))
        self.socket = Socket(pid: pid, interface: interface, family: ipv6 ? 6 : 4, port: port)
        self.remoteAddress = String(remoteHost)
        self.bytes = bytes
        self.inbound = inbound
    }
}

/// Counters for one socket and peer during a capture interval.
public struct UDPPeerUsage: Codable, Equatable {
    public let socket: UDPObservation.Socket
    public let address: String
    public var bytesIn: Int64
    public var bytesOut: Int64

    public init(socket: UDPObservation.Socket, address: String, bytesIn: Int64 = 0, bytesOut: Int64 = 0) {
        self.socket = socket
        self.address = address
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

public struct UDPUsageSnapshot: Codable {
    public let start: Date
    public let end: Date
    public let peers: [UDPPeerUsage]

    public init(start: Date, end: Date, peers: [UDPPeerUsage]) {
        self.start = start
        self.end = end
        self.peers = peers
    }
}
