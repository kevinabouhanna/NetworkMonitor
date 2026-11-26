import Darwin
import FilterProtocol
import Foundation
import NetworkExtension
import os

/// What macOS counts for each connection the filter lets through, written to
/// the filter's log, and nothing else (#754, #786). Off unless the app's
/// `flowBytesProbe` default is set by hand: it's there to find out whether
/// these counts could give an app the bytes nettop leaves out, as with
/// Safari over iCloud Private Relay, before anything is built on them.
///
/// With it on, HTTPS flows, and UDP ones whose peer isn't known yet, ask
/// macOS for statistics every few seconds and at the close. The verdict
/// after a handshake asks again, since macOS stops the statistics there
/// otherwise. No verdict changes, no packet is read, and nothing reaches
/// Usage History.
enum FlowBytesProbe {
    private static let log = Logger(subsystem: "com.kevinabouhanna.NetworkMonitor.Filter", category: "flow-bytes")
    private static let lock = NSLock()
    private static var watched = Set<UUID>()
    /// Flows at once: past it, new ones aren't watched until some close.
    private static let limit = 4_096

    /// The new flow's verdict, asking for statistics too when the flow is
    /// one the probe watches.
    static func observe(_ flow: NEFilterFlow, verdict: NEFilterNewFlowVerdict) -> NEFilterNewFlowVerdict {
        guard let socket = flow as? NEFilterSocketFlow, let kind = kind(of: socket),
              let observed = verdict.copy() as? NEFilterNewFlowVerdict else { return verdict }
        lock.lock()
        guard watched.count < limit else {
            lock.unlock()
            return verdict
        }
        watched.insert(flow.identifier)
        lock.unlock()
        observed.shouldReport = true
        observed.statisticsReportFrequency = .low
        let app = FlowReport.pid(fromAuditToken: flow.sourceAppAuditToken)
        let process = FlowReport.pid(fromAuditToken: flow.sourceProcessAuditToken)
        let host = (socket.remoteEndpoint as? NWHostEndpoint)?.hostname ?? "-" // untranslated: log
        let name = socket.remoteHostname ?? "-" // untranslated: log
        log.notice("""
            open flow=\(flow.identifier.uuidString, privacy: .public) \(kind, privacy: .public) \
            app=\(app, privacy: .public) \(path(of: app), privacy: .public) \
            process=\(process, privacy: .public) \(path(of: process), privacy: .public) \
            peer=\(host, privacy: .private) name=\(name, privacy: .private)
            """)
        return observed
    }

    /// The verdict after a handshake was read: asks for statistics again.
    static func observe(_ flow: NEFilterFlow, verdict: NEFilterDataVerdict) -> NEFilterDataVerdict {
        lock.lock()
        let watching = watched.contains(flow.identifier)
        lock.unlock()
        guard watching, let observed = verdict.copy() as? NEFilterDataVerdict else { return verdict }
        observed.shouldReport = true
        observed.statisticsReportFrequency = .low
        return observed
    }

    static func handle(_ report: NEFilterReport) {
        guard report.event == .statistics || report.event == .flowClosed, let flow = report.flow else { return }
        let closed = report.event == .flowClosed
        if closed {
            lock.lock()
            watched.remove(flow.identifier)
            lock.unlock()
        }
        log.notice("""
            \(closed ? "close" : "statistics", privacy: .public) flow=\(flow.identifier.uuidString, privacy: .public) \
            in=\(report.bytesInboundCount, privacy: .public) out=\(report.bytesOutboundCount, privacy: .public)
            """)
    }

    /// "tcp 443", "udp 443" or "udp, no peer": the flows worth watching.
    private static func kind(of socket: NEFilterSocketFlow) -> String? {
        let udp = socket.socketType == SOCK_DGRAM
        guard udp || socket.socketType == SOCK_STREAM else { return nil }
        guard let remote = socket.remoteEndpoint as? NWHostEndpoint else { return udp ? "udp, no peer" : nil }
        return remote.port == "443" ? (udp ? "udp 443" : "tcp 443") : nil
    }

    private static func path(of pid: Int32) -> String {
        guard pid > 0 else { return "-" }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "-" }
        return String(cString: buffer)
    }
}
