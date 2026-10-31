import FilterProtocol
import FirewallPolicy
import Foundation
import HandshakeName
import NetworkExtension
import os

/// Names a connection that arrived without one (#196), from the site name in
/// its opening handshake.
///
/// Only a new, allowed connection to port 443 with no name of its own is
/// watched. Its first outbound bytes are held while they're read, nothing is
/// passed on piecemeal, and then the whole flow is let go with one verdict.
/// Whatever happens, it's let go: on the name, on finding there isn't one, on
/// the flow closing, and after `timeout` if the handshake never completes.
final class HandshakeWatch {

    static let shared = HandshakeWatch()

    /// The longest a connection's first bytes are held. A client writes its
    /// whole first flight at once, so this only matters if something is wrong.
    static let timeout: TimeInterval = 2
    /// Flows read at once. Past this, new ones go unnamed rather than queue.
    static let limit = 1_024

    /// Set by the provider when it starts: an expired flow is let go through it.
    weak var provider: NEFilterDataProvider?

    private struct Watch {
        var reader: HandshakeReader
        let flow: NEFilterSocketFlow
        let report: FlowReport
    }

    private let lock = NSLock()
    private var watches: [UUID: Watch] = [:]
    private let log = Logger(subsystem: FilterIdentity.extensionIdentifier, category: "handshake")

    /// Whether to read this flow's handshake, and how.
    static func transport(of flow: NEFilterSocketFlow, address: String, port: Int) -> HandshakeReader.Transport? {
        guard port == 443, flow.remoteHostname?.isEmpty ?? true, !FirewallPolicy.isLocal(address) else { return nil }
        switch flow.socketType {
        case SOCK_STREAM: return .stream
        case SOCK_DGRAM: return .datagram
        default: return nil
        }
    }

    /// Starts watching an allowed flow: the verdict asks to see its first
    /// outbound bytes, and nothing inbound.
    func watch(_ flow: NEFilterSocketFlow, transport: HandshakeReader.Transport,
               report: FlowReport) -> NEFilterNewFlowVerdict {
        let id = flow.identifier
        lock.lock()
        guard watches.count < Self.limit else {
            lock.unlock()
            return .allow()
        }
        watches[id] = Watch(reader: HandshakeReader(transport), flow: flow, report: report)
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
            self?.expire(id)
        }
        return .filterDataVerdict(withFilterInbound: false, peekInboundBytes: 0,
                                  filterOutbound: true, peekOutboundBytes: HandshakeReader.firstPeek)
    }

    /// The flow's outbound bytes from `offset`. Holds them while there's more
    /// to read, and otherwise lets the flow go.
    func read(_ flow: NEFilterFlow, offset: Int, bytes: Data) -> NEFilterDataVerdict {
        lock.lock()
        guard var watch = watches[flow.identifier] else {
            lock.unlock()
            return .allow()
        }
        let step = watch.reader.read(at: offset, bytes)
        switch step {
        case .peek(let count):
            watches[flow.identifier] = watch
            lock.unlock()
            // Pass nothing yet, so the next look starts from the beginning
            // again, and see further.
            return NEFilterDataVerdict(passBytes: 0, peekBytes: count)
        case .done(let name):
            watches.removeValue(forKey: flow.identifier)
            lock.unlock()
            if let name { named(watch.report, name) }
            return .allow()
        }
    }

    /// The flow closed, or its outbound side finished.
    func finished(_ flow: NEFilterFlow) {
        lock.lock()
        watches.removeValue(forKey: flow.identifier)
        lock.unlock()
    }

    /// A flow still held after `timeout`: let it go unnamed.
    private func expire(_ id: UUID) {
        lock.lock()
        guard let watch = watches.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        lock.unlock()
        log.debug("let \(watch.report.address, privacy: .public) go unnamed after \(Self.timeout) s")
        provider?.update(watch.flow, using: .allow(), for: .any)
    }

    /// Reported as a connection with a name, the way one the app named is.
    private func named(_ report: FlowReport, _ name: String) {
        AppLink.shared.report(FlowReport(address: report.address, port: report.port, hostname: name,
                                         pid: report.pid, time: Date()))
    }
}
