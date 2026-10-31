import Darwin
import FilterProtocol
import Foundation
import NetworkExtension

/// Sees every new outbound connection, decides it by the person's rules
/// (#114), and reports it to the app.
///
/// Named `FilterDataProvider` for the Objective-C runtime, which is how the
/// extension's Info.plist (`NEProviderClasses`) names it.
@objc(FilterDataProvider)
final class FilterDataProvider: NEFilterDataProvider {

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        // Ask Me resumes held flows through the provider (#129), and a
        // handshake that never completes is let go through it (#196).
        Firewall.shared.provider = self
        HandshakeWatch.shared.provider = self
        // Every outbound flow, so each one passes through `handleNewFlow`.
        let everything = NENetworkRule(remoteNetwork: nil, remotePrefix: 0, localNetwork: nil,
                                       localPrefix: 0, protocol: .any, direction: .outbound)
        let settings = NEFilterSettings(rules: [NEFilterRule(networkRule: everything, action: .filterData)],
                                        defaultAction: .allow)
        apply(settings) { error in
            completionHandler(error)
        }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    /// Blocks only what a rule or the mode says to. Whatever goes wrong in
    /// here, the answer is allow: a filter that fails must never cut the Mac
    /// off.
    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        guard let socket = flow as? NEFilterSocketFlow,
              let remote = socket.remoteEndpoint as? NWHostEndpoint else { return .allow() }
        let port = Int(remote.port) ?? 0
        let pid = FlowReport.pid(fromAuditToken: flow.sourceAppAuditToken)
        // The system resolver's flows carry the name being looked up, not the
        // server's: 1.1.1.1 read as whatever was last resolved (#196).
        let fromResolver = Self.isResolver(pid)
        let hostname = fromResolver ? nil : socket.remoteHostname
        let report = FlowReport(address: remote.hostname, port: port, hostname: hostname, pid: pid, time: Date())
        let decision = Firewall.shared.decide(socket, address: remote.hostname, port: port, report: report)
        // Nameless, and not held for Ask Me: read the name from its handshake
        // (#196), and decide again with it (#197). Its report waits for that.
        let paused = !decision.allows && decision.blockedBy == nil
        if !paused, !fromResolver,
           let transport = HandshakeWatch.transport(of: socket, address: remote.hostname, port: port) {
            return HandshakeWatch.shared.watch(socket, transport: transport, report: report, decision: decision)
        }
        AppLink.shared.report(FlowReport(address: report.address, port: port, hostname: report.hostname,
                                         pid: report.pid, time: report.time, blockedBy: decision.blockedBy,
                                         appKey: decision.blockedBy == nil ? nil : decision.appKey))
        return decision.verdict
    }

    /// macOS's DNS resolver, by its process.
    private static func isResolver(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return String(cString: buffer) == "/usr/sbin/mDNSResponder"
    }

    // Data is asked for only by `HandshakeWatch`, and only outbound (#196).

    override func handleOutboundData(from flow: NEFilterFlow, readBytesStartOffset offset: Int,
                                     readBytes: Data) -> NEFilterDataVerdict {
        HandshakeWatch.shared.read(flow, offset: offset, bytes: readBytes)
    }

    override func handleOutboundDataComplete(for flow: NEFilterFlow) -> NEFilterDataVerdict {
        HandshakeWatch.shared.finished(flow)
        return .allow()
    }

    override func handleInboundData(from flow: NEFilterFlow, readBytesStartOffset offset: Int,
                                    readBytes: Data) -> NEFilterDataVerdict {
        .allow()
    }

    override func handleInboundDataComplete(for flow: NEFilterFlow) -> NEFilterDataVerdict {
        HandshakeWatch.shared.finished(flow)
        return .allow()
    }
}
