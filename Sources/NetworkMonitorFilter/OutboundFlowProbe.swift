import Darwin
import FilterProtocol
import FirewallPolicy
import Foundation
import NetworkExtension
import os

/// An opt-in comparison with NEFilterReport for outbound UDP (#799).
/// Only records lengths and offsets. A flow must already be allowed by the
/// firewall before it can be watched.
enum OutboundFlowProbe {
    private struct Measurement {
        let started: TimeInterval
        var count = OutboundByteCount()
        var callbacks = 0
    }

    private enum End: String {
        case complete, gap, disabled, expired, limit
        case noData = "no-data"
        case noProgress = "no-progress"
    }

    private static let log = Logger(subsystem: FilterIdentity.extensionIdentifier, category: "flow-outbound-bytes")
    private static let lock = NSLock()
    private static var measurements: [UUID: Measurement] = [:]
    private static let flowLimit = 32
    private static let byteLimit = 16 * 1_024 * 1_024
    private static let lifetime: TimeInterval = 90
    // One full UDP datagram. Smaller peeks could give only part of a packet.
    private static let peekBytes = 65_536

    static func newFlow(_ flow: NEFilterFlow, allowed verdict: NEFilterNewFlowVerdict) -> NEFilterNewFlowVerdict {
        guard start(flow) else { return verdict }
        let peek = NEFilterNewFlowVerdict.filterDataVerdict(withFilterInbound: false, peekInboundBytes: 0,
                                                           filterOutbound: true, peekOutboundBytes: peekBytes)
        peek.shouldReport = true
        return peek
    }

    /// Called when the handshake's final decision is allow. A timeout or
    /// a paused question is left on the normal firewall path.
    static func afterHandshake(_ flow: NEFilterFlow, offset: Int, count: Int) -> NEFilterDataVerdict {
        guard start(flow) else { return .allow() }
        return pass(flow, offset: offset, count: count)
    }

    static func pass(_ flow: NEFilterFlow, offset: Int, count: Int) -> NEFilterDataVerdict {
        let id = flow.identifier
        let enabled = Firewall.shared.measuresOutboundFlowBytes
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard var measurement = measurements[id] else {
            lock.unlock()
            return .allow()
        }
        let end: End
        if !enabled {
            end = .disabled
        } else if now - measurement.started >= lifetime {
            end = .expired
        } else {
            let previous = measurement.count
            if let added = measurement.count.advance(offset: offset, count: count) {
                if added > 0, measurement.count.bytes <= byteLimit {
                    measurement.callbacks += 1
                    measurements[id] = measurement
                    lock.unlock()
                    let verdict = NEFilterDataVerdict(passBytes: added, peekBytes: peekBytes)
                    verdict.shouldReport = true
                    return verdict
                }
                measurement.count = previous
                end = added == 0 ? .noProgress : .limit
            } else {
                end = .gap
            }
        }
        measurements.removeValue(forKey: id)
        lock.unlock()
        recordEnd(id, measurement, end)
        return .allow()
    }

    static func complete(_ flow: NEFilterFlow) {
        let id = flow.identifier
        lock.lock()
        let measurement = measurements.removeValue(forKey: id)
        lock.unlock()
        guard let measurement else { return }
        let end: End
        if !Firewall.shared.measuresOutboundFlowBytes {
            end = .disabled
        } else {
            end = measurement.callbacks == 0 ? .noData : .complete
        }
        recordEnd(id, measurement, end)
    }

    static func reset() {
        lock.lock()
        measurements.removeAll()
        lock.unlock()
    }

    private static func start(_ flow: NEFilterFlow) -> Bool {
        guard let socket = flow as? NEFilterSocketFlow, socket.socketType == SOCK_DGRAM,
              Firewall.shared.measuresOutboundFlowBytes else { return false }
        if let peer = socket.remoteEndpoint as? NWHostEndpoint,
           !peer.port.isEmpty, peer.port != "0" {
            guard peer.port == "443", !FirewallPolicy.isLocal(peer.hostname) else { return false }
        }
        let app = FlowReport.pid(fromAuditToken: flow.sourceAppAuditToken)
        let process = FlowReport.pid(fromAuditToken: flow.sourceProcessAuditToken)
        guard (app > 0 || process > 0), app != getpid(), process != getpid() else { return false }

        let id = flow.identifier
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let expired = measurements.filter { now - $0.value.started >= lifetime }
        for id in expired.keys { measurements.removeValue(forKey: id) }
        let added = measurements[id] == nil && measurements.count < flowLimit
        if added { measurements[id] = Measurement(started: now) }
        lock.unlock()
        for (id, measurement) in expired { recordEnd(id, measurement, .expired) }
        if added {
            log.notice("open flow=\(id.uuidString, privacy: .public) app=\(app, privacy: .public) process=\(process, privacy: .public)")
        }
        return added
    }

    private static func recordEnd(_ id: UUID, _ measurement: Measurement, _ end: End) {
        log.notice("""
            end flow=\(id.uuidString, privacy: .public) reason=\(end.rawValue, privacy: .public)             out=\(measurement.count.bytes, privacy: .public) callbacks=\(measurement.callbacks, privacy: .public)
            """)
    }
}
