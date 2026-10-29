import Foundation
import FilterProtocol

/// The filter's side of its connection to the app: listens on the Mach
/// service, accepts only NetworkMonitor signed by its team, and sends it what
/// the filter saw, a batch at a time.
///
/// With no app connected, reports are dropped: the record lives in the app,
/// and a filter holding on to connections nobody asked about would be a log.
final class AppLink: NSObject, NSXPCListenerDelegate, FilterExtensionInterface {

    static let shared = AppLink()

    private let queue = DispatchQueue(label: "com.kevinabouhanna.NetworkMonitor.Filter.link")
    private var listener: NSXPCListener?
    private var app: NSXPCConnection?
    private var pending: [FlowReport] = []
    private var flushScheduled = false

    /// How long reports wait to travel together, and how many at most.
    static let batchDelay: TimeInterval = 0.5
    static let batchLimit = 500

    func start() {
        let listener = NSXPCListener(machServiceName: FilterIdentity.machServiceName)
        listener.delegate = self
        listener.resume()
        self.listener = listener
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(FilterIdentity.appRequirement)
        connection.exportedInterface = NSXPCInterface(with: FilterExtensionInterface.self)
        connection.exportedObject = self
        connection.remoteObjectInterface = NSXPCInterface(with: FilterAppInterface.self)
        connection.invalidationHandler = { [weak self, weak connection] in
            self?.queue.async {
                if self?.app === connection { self?.app = nil }
            }
        }
        connection.resume()
        queue.async { self.app = connection }
        return true
    }

    func register(_ reply: @escaping (String) -> Void) {
        reply(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
    }

    func report(_ flow: FlowReport) {
        queue.async {
            guard self.app != nil else { return }
            self.pending.append(flow)
            if self.pending.count >= Self.batchLimit {
                self.flush()
            } else if !self.flushScheduled {
                self.flushScheduled = true
                self.queue.asyncAfter(deadline: .now() + Self.batchDelay) { self.flush() }
            }
        }
    }

    /// On `queue`.
    private func flush() {
        flushScheduled = false
        guard !pending.isEmpty, let app else { pending = []; return }
        let batch = pending
        pending = []
        (app.remoteObjectProxy as? FilterAppInterface)?.flowsSeen(FlowReport.encode(batch))
    }
}
