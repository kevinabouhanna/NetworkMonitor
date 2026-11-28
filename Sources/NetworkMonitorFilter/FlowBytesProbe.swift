import Darwin
import FilterProtocol
import FirewallPolicy
import Foundation
import NetworkExtension
import os

/// Requests periodic receive counters through the same verdicts as the
/// firewall. The diagnostic log and #799's accounting trial are opt-in.
enum FlowBytesProbe {
    static let log = Logger(subsystem: "com.kevinabouhanna.NetworkMonitor.Filter", category: "flow-bytes")
    /// The open lines' process paths are looked up here, off the verdict's way.
    private static let queue = DispatchQueue(label: "com.kevinabouhanna.NetworkMonitor.Filter.flow-bytes", qos: .utility) // untranslated: queue label
    private static let lock = NSLock()
    private struct Watch {
        let owner: String?
        let namedPlaceholderAtOpen: Bool
        var through: Date
        var bytes: Int64 = 0
    }

    private static var watched: [UUID: Watch] = [:]
    /// How long a flow stays watched without a report. One whose bytes are
    /// credited (#799) keeps reporting while it's open and leaves at its
    /// close, so it stays far longer: only a flow that was dropped, and so
    /// never closes, outlives it.
    private static let keep: TimeInterval = 120
    private static let keepCredited: TimeInterval = 30 * 60
    private static let limit = 4_096
    private static var full = false
    private static var nextPrune = Date.distantPast

    /// The new flow's verdict, asking for statistics too when the flow is
    /// one the probe watches.
    static func observe(_ flow: NEFilterFlow, verdict: NEFilterNewFlowVerdict) -> NEFilterNewFlowVerdict {
        let diagnostics = Firewall.shared.measuresFlowBytes
        let accounting = Firewall.shared.creditsFilterDownloads
        guard diagnostics || accounting, let socket = flow as? NEFilterSocketFlow, let kind = kind(of: socket),
              let observed = verdict.copy() as? NEFilterNewFlowVerdict else { return verdict }
        let owner = accounting ? Firewall.shared.downloadOwner(of: flow) : nil
        guard diagnostics || owner != nil else { return verdict }
        let namedPlaceholder = owner != nil && (socket.remoteEndpoint as? NWHostEndpoint)?.hostname == "::"
            && downloadPeer(of: socket) == .namedPlaceholder
        let now = Date()
        lock.lock()
        if watched.count >= limit / 2, now >= nextPrune {
            nextPrune = now.addingTimeInterval(5)
            watched = watched.filter {
                now.timeIntervalSince($0.value.through) < ($0.value.owner == nil ? keep : keepCredited)
            }
        }
        guard watched.count < limit else {
            let first = !full
            full = true
            lock.unlock()
            if first { log.notice("watching \(limit, privacy: .public) flows: new ones aren't watched until some close") }
            return verdict
        }
        full = false
        watched[flow.identifier] = Watch(owner: owner, namedPlaceholderAtOpen: namedPlaceholder, through: now)
        lock.unlock()
        observed.shouldReport = true
        observed.statisticsReportFrequency = .low
        guard diagnostics else { return observed }
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
        let accounting = Firewall.shared.creditsFilterDownloads
        let diagnostics = Firewall.shared.measuresFlowBytes
        guard accounting || diagnostics, report.event == .statistics || report.event == .flowClosed,
              let flow = report.flow else { return }
        let closed = report.event == .flowClosed
        let now = Date()
        lock.lock()
        let previous = watched[flow.identifier]
        if closed {
            watched.removeValue(forKey: flow.identifier)
        } else if var current = previous, let count = Int64(exactly: report.bytesInboundCount),
                  count >= current.bytes, now >= current.through {
            current.through = now
            current.bytes = count
            watched[flow.identifier] = current
        }
        lock.unlock()

        if accounting, let previous, let count = Int64(exactly: report.bytesInboundCount), count > previous.bytes {
            let endpoint = downloadPeer(of: flow, namedPlaceholderAtOpen: previous.namedPlaceholderAtOpen)
            let clockValid = now >= previous.through
            let dropped = report.action == .drop
            let delta = count - previous.bytes
            if diagnostics {
                let owner = previous.owner == nil ? "missing" : "resolved"
                log.notice("download flow=\(flow.identifier.uuidString, privacy: .public) delta=\(delta, privacy: .public) owner=\(owner, privacy: .public) endpoint=\(endpoint.rawValue, privacy: .public) drop=\(dropped, privacy: .public) clockValid=\(clockValid, privacy: .public)")
            }
            if let owner = previous.owner, clockValid, !dropped, endpoint.isEligible {
                AppLink.shared.report(FilterDownload(appKey: owner, from: previous.through,
                                                    through: now, bytes: delta))
            }
        } else if accounting && diagnostics, previous == nil, report.bytesInboundCount > 0 {
            log.notice("download flow=\(flow.identifier.uuidString, privacy: .public) reason=not-watched")
        }
        if diagnostics {
            log.notice("""
                \(closed ? "close" : "statistics", privacy: .public) flow=\(flow.identifier.uuidString, privacy: .public) \
                in=\(report.bytesInboundCount, privacy: .public) out=\(report.bytesOutboundCount, privacy: .public)
                """)
        }
    }

    static func reset() {
        lock.lock()
        watched.removeAll()
        lock.unlock()
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

    private static func downloadPeer(of flow: NEFilterFlow, namedPlaceholderAtOpen: Bool = false) -> DownloadPeer {
        guard let socket = flow as? NEFilterSocketFlow,
              let peer = socket.remoteEndpoint as? NWHostEndpoint else { return .missing }
        let placeholder = peer.hostname == "::" && socket.socketType == SOCK_DGRAM && socket.direction == .outbound
        return DownloadPeer(address: peer.hostname, port: peer.port,
                            hostname: placeholder ? socket.remoteHostname : nil, outboundUDP: placeholder,
                            namedPlaceholderAtOpen: namedPlaceholderAtOpen)
    }

    private static func path(of pid: Int32) -> String {
        guard pid > 0 else { return "-" }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "-" }
        return String(cString: buffer)
    }
}
