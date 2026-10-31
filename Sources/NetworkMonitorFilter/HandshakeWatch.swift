import FilterProtocol
import FirewallPolicy
import Foundation
import HandshakeName
import NetworkExtension
import os

/// Names a connection that arrived without one (#196), from the site name in
/// its opening handshake, and decides it again with that name (#197).
///
/// Only a new connection to port 443 with no name of its own, and not held
/// for Ask Me, is watched. Its first outbound bytes are held while they're
/// read, nothing is passed on piecemeal, and then one verdict decides the
/// whole flow: the rules' answer with the name, or without one, the answer it
/// had when it opened. That's also what happens after `timeout` if the
/// handshake never completes, and an allowed flow is never held longer.
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
        /// The decision without a name, and what it was decided on.
        let decision: Firewall.Decision
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

    /// Starts watching a flow: the verdict asks to see its first outbound
    /// bytes, and nothing inbound. Past `limit`, the flow gets its decision
    /// without a name, as before #196.
    func watch(_ flow: NEFilterSocketFlow, transport: HandshakeReader.Transport,
               report: FlowReport, decision: Firewall.Decision) -> NEFilterNewFlowVerdict {
        let id = flow.identifier
        lock.lock()
        guard watches.count < Self.limit else {
            lock.unlock()
            _ = conclude(report, decision: decision, name: nil)
            return decision.verdict
        }
        watches[id] = Watch(reader: HandshakeReader(transport), flow: flow, report: report, decision: decision)
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
            if watch.decision.asks, let asked = ask(flow, watch, name: name) { return asked }
            return conclude(watch.report, decision: watch.decision, name: name) ? .allow() : .drop()
        }
    }

    /// The flow closed, or its outbound side finished.
    func finished(_ flow: NEFilterFlow) {
        lock.lock()
        watches.removeValue(forKey: flow.identifier)
        lock.unlock()
    }

    /// A flow still held after `timeout`: decided without a name.
    private func expire(_ id: UUID) {
        lock.lock()
        guard let watch = watches.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        lock.unlock()
        log.debug("decided \(watch.report.address, privacy: .public) unnamed after \(Self.timeout) s")
        // A question can't be held from here: like an unanswered one, it goes
        // ahead (#199). Only a handshake that never completes gets here.
        let allows = watch.decision.asks || conclude(watch.report, decision: watch.decision, name: nil)
        if watch.decision.asks { AppLink.shared.report(watch.report) }
        provider?.update(watch.flow, using: allows ? .allow() : .drop(), for: .any)
    }

    /// Ask Me, now that the site has a name (#199): unless a rule decides it
    /// by name, the app asks, and the flow's first bytes wait in the filter
    /// for the answer. Nil when a rule decided it after all.
    private func ask(_ flow: NEFilterFlow, _ watch: Watch, name: String?) -> NEFilterDataVerdict? {
        guard let facts = watch.decision.facts, let appKey = watch.decision.appKey else { return nil }
        var named = facts
        if let name {
            switch Firewall.shared.verdict(for: facts, named: name) {
            case .allow, .block: return nil
            case .ask: break
            }
            named.hostname = name
        }
        let company = name.map { Firewall.shared.company(named: $0, otherwise: watch.decision.company) }
            ?? watch.decision.company
        let report = FlowReport(address: watch.report.address, port: watch.report.port,
                                hostname: name ?? watch.report.hostname, pid: watch.report.pid, time: watch.report.time)
        // Named now, whatever the answer: the name goes to Connections.
        AppLink.shared.report(report)
        return Firewall.shared.askNamed(flow, appKey: appKey, facts: named, company: company, report: report)
    }

    /// The final word on a watched flow, and its one report: its name if it
    /// has one, and what blocked it if anything did. True to let it through.
    private func conclude(_ report: FlowReport, decision: Firewall.Decision, name: String?) -> Bool {
        var blockedBy = decision.blockedBy
        if let name, let facts = decision.facts {
            switch Firewall.shared.verdict(for: facts, named: name) {
            case .allow:             blockedBy = nil
            case .block(let reason): blockedBy = reason.id
            // Nothing decided it by name: it stays as it was decided.
            case .ask:               break
            }
        }
        AppLink.shared.report(FlowReport(address: report.address, port: report.port, hostname: name ?? report.hostname,
                                         pid: report.pid, time: report.time, blockedBy: blockedBy,
                                         appKey: blockedBy == nil ? nil : decision.appKey))
        return blockedBy == nil
    }
}
