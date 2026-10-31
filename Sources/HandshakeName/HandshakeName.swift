import Foundation

// The site a connection is for, read from the first thing its client sends
// (#196). Chrome and other Chromium apps connect by address, so the content
// filter gets no name for their connections, and on a Mac whose DNS is
// 1.1.1.1 or 8.8.8.8 Chrome looks names up encrypted, so DNS replies don't
// show them either. The handshake still carries the name: the TLS
// ClientHello's server_name over TCP, and the same field inside QUIC's
// Initial packet, which is protected with keys anyone can derive (RFC 9001
// §5.2) so that the network can read it.
//
// Only that name is read. Pure Foundation (and the system's crypto), like
// FilterProtocol, so the system extension links none of the app and the
// parsing is tested on its own.

public enum HandshakeName {

    /// What reading the bytes so far found.
    public enum Outcome: Equatable {
        case name(String)
        /// The handshake has started and the name isn't in the bytes yet.
        case needMore
        /// Not a handshake this reads, or one without a name.
        case none
    }

    /// TLS over TCP: the client's bytes from the start of the connection.
    public static func tls(_ stream: [UInt8]) -> Outcome {
        var handshake: [UInt8] = []
        var index = 0
        while index < stream.count {
            // A record: type 22 (handshake), version 3.x, a 16-bit length.
            guard stream[index] == 22 else { return handshake.isEmpty ? .none : settled(handshake) }
            guard index + 5 <= stream.count else { break }
            guard stream[index + 1] == 3, stream[index + 2] <= 4 else { return .none }
            let length = Int(stream[index + 3]) << 8 | Int(stream[index + 4])
            guard length > 0, length <= 18_432 else { return .none }
            let start = index + 5
            let end = start + length
            handshake += stream[start..<min(end, stream.count)]
            guard end <= stream.count else { break }
            index = end
            let outcome = ClientHello.serverName(inHandshake: handshake)
            if outcome != .needMore { return outcome }
        }
        return ClientHello.serverName(inHandshake: handshake)
    }

    /// QUIC: the client's datagrams from the start of the connection, one
    /// after another.
    public static func quic(_ datagrams: [UInt8]) -> Outcome {
        QUICInitial.serverName(in: datagrams)
    }

    /// A ClientHello cut short by something that isn't more of it.
    private static func settled(_ handshake: [UInt8]) -> Outcome {
        let outcome = ClientHello.serverName(inHandshake: handshake)
        return outcome == .needMore ? .none : outcome
    }
}

/// Reads one connection's opening bytes as the filter hands them over, and
/// says when it's seen enough.
///
/// The filter passes nothing on while it reads, so every call starts from the
/// beginning of the flow whichever way the system counts its offsets, and then
/// lets the whole flow go with one verdict (#196).
public struct HandshakeReader {

    public enum Transport: Equatable {
        /// TCP, carrying TLS.
        case stream
        /// UDP, carrying QUIC.
        case datagram
    }

    public enum Step: Equatable {
        /// Show the reader this many bytes from the start of the flow.
        case peek(Int)
        /// Finished: the name, or nil if there wasn't one to read.
        case done(String?)
    }

    /// The first look. A ClientHello with a post-quantum key share is about
    /// 1.8 KB; QUIC's first flight is one or two datagrams of about 1.25 KB.
    public static let firstPeek = 8_192
    /// Past this, it's not a handshake worth waiting for.
    public static let limit = 65_536
    public static let maxReads = 8

    public let transport: Transport
    private var bytes: [UInt8] = []
    private var reads = 0

    public init(_ transport: Transport) {
        self.transport = transport
    }

    /// The bytes at `offset` from the start of the flow's outbound data.
    public mutating func read(at offset: Int, _ data: Data) -> Step {
        reads += 1
        // A gap means something was let through unread: stop reading.
        guard offset >= 0, offset <= bytes.count else { return .done(nil) }
        let overlap = bytes.count - offset
        if data.count > overlap {
            bytes += data.dropFirst(overlap)
        }
        let outcome = transport == .stream ? HandshakeName.tls(bytes) : HandshakeName.quic(bytes)
        switch outcome {
        case .name(let name):
            return .done(name)
        case .none:
            return .done(nil)
        case .needMore:
            guard bytes.count < Self.limit, reads < Self.maxReads else { return .done(nil) }
            return .peek(min(Self.limit, bytes.count + Self.firstPeek))
        }
    }
}
