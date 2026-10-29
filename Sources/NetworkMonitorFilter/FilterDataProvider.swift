import Foundation
import FilterProtocol
import NetworkExtension

/// Sees every new outbound connection, allows it, and reports it to the app.
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

    /// Always allows. Whatever goes wrong in here, the answer is still allow:
    /// a filter that fails must never cut the Mac off.
    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        guard let socket = flow as? NEFilterSocketFlow,
              let remote = socket.remoteEndpoint as? NWHostEndpoint else { return .allow() }
        AppLink.shared.report(FlowReport(address: remote.hostname, port: Int(remote.port) ?? 0,
                                         hostname: socket.remoteHostname,
                                         pid: FlowReport.pid(fromAuditToken: flow.sourceAppAuditToken),
                                         time: Date()))
        return .allow()
    }
}
