import FilterProtocol
import FirewallPolicy
import Foundation

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
    private var creditsDownloads = false
    private var pendingDownloads: [FilterDownload] = []
    private var flushScheduled = false

    /// How long reports wait to travel together, and how many at most.
    static let batchDelay: TimeInterval = 0.5
    static let batchLimit = 500

    func start() {
        let listener = NSXPCListener(machServiceName: FilterIdentity.machServiceName(inInfo: Bundle.main.infoDictionary))
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
        queue.async {
            self.creditsDownloads = false
            self.pendingDownloads.removeAll(keepingCapacity: true)
            self.app = connection
        }
        connection.resume()
        return true
    }

    func register(_ reply: @escaping (String) -> Void) {
        reply(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
    }

    func applyPolicy(_ policy: Data) {
        guard let policy = FirewallPolicy.decode(policy) else { return }
        let sender = NSXPCConnection.current()
        Firewall.shared.apply(policy)
        queue.async {
            guard let sender, self.app === sender else { return }
            self.creditsDownloads = policy.creditsFilterDownloads
            if !self.creditsDownloads { self.pendingDownloads.removeAll(keepingCapacity: true) }
        }
    }

    // MARK: Ask Me (#129)

    var isConnected: Bool {
        queue.sync { app != nil }
    }

    func ask(_ question: FlowQuestion) {
        queue.async {
            (self.app?.remoteObjectProxy as? FilterAppInterface)?.ask(question.encoded())
        }
    }

    /// Apps that refused Enhanced ad blocking's certificate, for the app to
    /// keep (#685).
    func leftAlone(_ apps: Set<String>) {
        guard !apps.isEmpty, let data = try? JSONEncoder().encode(apps.sorted()) else { return }
        queue.async {
            (self.app?.remoteObjectProxy as? FilterAppInterface)?.appsLeftAlone(data)
        }
    }

    func expired(_ id: String) {
        queue.async {
            (self.app?.remoteObjectProxy as? FilterAppInterface)?.questionExpired(id)
        }
    }

    func applyGeoData(_ countries: FileHandle, _ owners: FileHandle, _ month: String) {
        Firewall.shared.applyGeoData(countries: countries, owners: owners, month: month)
    }

    func applyBlocklists(_ ads: FileHandle, _ malware: FileHandle, _ version: String) {
        Firewall.shared.applyBlocklists([.ads: ads, .malware: malware], version: version)
    }

    func applyDownloadedLists(_ lists: FileHandle, _ version: String) {
        Firewall.shared.applyDownloadedLists(lists, version: version)
    }

    func answer(_ id: String, _ answer: String) {
        Firewall.shared.answer(id, FlowAnswer(rawValue: answer) ?? .allowOnce)
    }

    func report(_ flow: FlowReport) {
        queue.async {
            guard self.app != nil else { return }
            self.pending.append(flow)
            self.scheduleFlush()
        }
    }

    func report(_ download: FilterDownload) {
        queue.async {
            guard self.app != nil, self.creditsDownloads else { return }
            self.pendingDownloads.append(download)
            self.scheduleFlush()
        }
    }

    /// On `queue`.
    private func scheduleFlush() {
        if pending.count + pendingDownloads.count >= Self.batchLimit {
            flush()
        } else if !flushScheduled {
            flushScheduled = true
            queue.asyncAfter(deadline: .now() + Self.batchDelay) { self.flush() }
        }
    }

    private func flush() {
        flushScheduled = false
        let flows = pending
        let downloads = pendingDownloads
        pending = []
        pendingDownloads = []
        guard let remote = app?.remoteObjectProxy as? FilterAppInterface else { return }
        if !flows.isEmpty { remote.flowsSeen(FlowReport.encode(flows)) }
        if !downloads.isEmpty, let data = try? JSONEncoder().encode(downloads) {
            remote.filterDownloads(data)
        }
    }
}
