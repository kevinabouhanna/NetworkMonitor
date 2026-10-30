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
        let verdict = Firewall.shared.verdict(for: socket, address: remote.hostname, port: port)
        AppLink.shared.report(FlowReport(address: remote.hostname, port: port,
                                         hostname: socket.remoteHostname,
                                         pid: FlowReport.pid(fromAuditToken: flow.sourceAppAuditToken),
                                         time: Date()))
        return verdict.allows ? .allow() : .drop()
    }
}
