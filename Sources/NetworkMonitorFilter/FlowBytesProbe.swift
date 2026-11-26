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
/// macOS for statistics every few seconds and at the close. Every later
/// verdict for the flow (after its handshake, after Ask Me, after a
/// handshake that never ends) asks again, since macOS stops the statistics
/// otherwise. No verdict changes, no packet is read, and nothing reaches
/// Usage History.
enum FlowBytesProbe {
    private static let log = Logger(subsystem: "com.kevinabouhanna.NetworkMonitor.Filter", category: "flow-bytes")
    /// The open lines' process paths are looked up here, off the verdict's way.
    private static let queue = DispatchQueue(label: "com.kevinabouhanna.NetworkMonitor.Filter.flow-bytes", qos: .utility) // untranslated: queue label
    private static let lock = NSLock()
    /// Flows whose later verdicts ask for statistics again, by when they
    /// opened. They're only needed until their verdict is final, which
    /// comes within seconds, so entries past `keep` go: a flow that was
    /// dropped never reports a close.
    private static var watched: [UUID: Date] = [:]
    private static let keep: TimeInterval = 120
    private static let limit = 4_096
    private static var full = false

    /// The new flow's verdict, asking for statistics too when the flow is
    /// one the probe watches.
    static func observe(_ flow: NEFilterFlow, verdict: NEFilterNewFlowVerdict) -> NEFilterNewFlowVerdict {
        guard let socket = flow as? NEFilterSocketFlow, let kind = kind(of: socket),
              let observed = verdict.copy() as? NEFilterNewFlowVerdict else { return verdict }
        let now = Date()
        lock.lock()
        if watched.count >= limit / 2 { watched = watched.filter { now.timeIntervalSince($0.value) < keep } }
        guard watched.count < limit else {
            let first = !full
            full = true
            lock.unlock()
            if first { log.notice("watching \(limit, privacy: .public) flows: new ones aren't watched until some close") }
            return verdict
        }
        full = false
        watched[flow.identifier] = now
        lock.unlock()
        observed.shouldReport = true
        observed.statisticsReportFrequency = .low
        let id = flow.identifier.uuidString
        let app = FlowReport.pid(fromAuditToken: flow.sourceAppAuditToken)
        let process = FlowReport.pid(fromAuditToken: flow.sourceProcessAuditToken)
        let host = (socket.remoteEndpoint as? NWHostEndpoint)?.hostname ?? "-" // untranslated: log
        let name = socket.remoteHostname ?? "-" // untranslated: log
        queue.async {
            log.notice("""
                open flow=\(id, privacy: .public) \(kind, privacy: .public) \
                app=\(app, privacy: .public) \(path(of: app), privacy: .public) \
                process=\(process, privacy: .public) \(path(of: process), privacy: .public) \
                peer=\(host, privacy: .private) name=\(name, privacy: .private)
                """)
        }
        return observed
    }

    /// A later verdict for a watched flow: asks for statistics again.
    static func observe(_ flow: NEFilterFlow, verdict: NEFilterDataVerdict) -> NEFilterDataVerdict {
        guard isWatched(flow), let observed = verdict.copy() as? NEFilterDataVerdict else { return verdict }
        observed.shouldReport = true
        observed.statisticsReportFrequency = .low
        return observed
    }

    /// A paused new flow, resumed after Ask Me: asks for statistics again.
    static func resumed(_ flow: NEFilterFlow, verdict: NEFilterNewFlowVerdict) -> NEFilterNewFlowVerdict {
        guard isWatched(flow), let observed = verdict.copy() as? NEFilterNewFlowVerdict else { return verdict }
        observed.shouldReport = true
        observed.statisticsReportFrequency = .low
        return observed
    }

    static func handle(_ report: NEFilterReport) {
        guard report.event == .statistics || report.event == .flowClosed, let flow = report.flow else { return }
        let closed = report.event == .flowClosed
        if closed {
            lock.lock()
            watched.removeValue(forKey: flow.identifier)
            lock.unlock()
        }
        log.notice("""
            \(closed ? "close" : "statistics", privacy: .public) flow=\(flow.identifier.uuidString, privacy: .public) \
            in=\(report.bytesInboundCount, privacy: .public) out=\(report.bytesOutboundCount, privacy: .public)
            """)
    }

    private static func isWatched(_ flow: NEFilterFlow) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return watched[flow.identifier] != nil
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
