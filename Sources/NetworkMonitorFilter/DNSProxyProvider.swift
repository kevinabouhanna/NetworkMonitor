import FilterProtocol
import FirewallPolicy
import Foundation
import Network
import NetworkExtension
import os

/// Encrypted lookups (#291): every DNS lookup the Mac makes comes here, and
/// goes on over DNS over HTTPS to the resolver picked in Settings. The answer
/// comes back unchanged, and the content filter reads its aliases (#255).
///
/// It fails towards working: a lookup the encrypted resolver doesn't answer
/// in time goes to the network's own DNS server, as it would have without
/// this, and after a few such failures in a row every lookup does for a
/// minute. Names only the network knows (the router, `.local`, a work
/// network's own) always go there.
///
/// Named for the Objective-C runtime, as the Info.plist's
/// `NEProviderClasses` names it.
@objc(DNSProxyProvider)
final class DNSProxyProvider: NEDNSProxyProvider {

    static let log = Logger(subsystem: FilterIdentity.extensionIdentifier, category: "dns")

    override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        // Which resolver comes with the rules the app sends, and is kept with them.
        Self.log.notice("encrypted lookups to \(Lookups.shared.resolver.title, privacy: .public)")
        completionHandler(nil)
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        Self.log.notice("encrypted lookups stopped: \(reason.rawValue)")
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        if let udp = flow as? NEAppProxyUDPFlow {
            UDPLookups(flow: udp).start()
            return true
        }
        if let tcp = flow as? NEAppProxyTCPFlow, let remote = tcp.remoteEndpoint as? NWHostEndpoint {
            TCPRelay(flow: tcp, remote: remote).start()
            return true
        }
        return false
    }
}

/// Answers one lookup at a time, encrypted if it can, and remembers when the
/// encrypted resolver isn't answering.
final class Lookups {

    static let shared = Lookups()

    /// As the app last said, in the policy it sends the filter.
    var resolver: EncryptedDNS.Resolver { EncryptedDNS.resolver(Firewall.shared.lookupResolver) }
    private let lock = NSLock()
    private var fallback = EncryptedDNS.Fallback()
    /// Long enough for a resolver across the world; short enough that a
    /// lookup sent on to the network still comes back before most apps give up.
    static let encryptedTimeout: TimeInterval = 2.5

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.encryptedTimeout
        configuration.timeoutIntervalForResource = Self.encryptedTimeout
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// The answer to `query`, which was meant for `server`.
    func answer(_ query: Data, server: NWHostEndpoint, reply: @escaping (Data?) -> Void) {
        let local = EncryptedDNS.questionName(query).map(EncryptedDNS.staysOnNetwork) ?? true
        lock.lock()
        let encrypted = !local && fallback.triesEncrypted()
        lock.unlock()
        guard encrypted else {
            Self.plain(query, to: server, reply: reply)
            return
        }
        var request = URLRequest(url: resolver.url, timeoutInterval: Self.encryptedTimeout)
        request.httpMethod = "POST"
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        request.httpBody = query
        session.dataTask(with: request) { [weak self] data, response, error in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            if ok, let data, let answer = EncryptedDNS.answer(data, for: query) {
                self?.note(true)
                reply(answer)
                return
            }
            self?.note(false, error: error)
            Self.plain(query, to: server, reply: reply)
        }.resume()
    }

    private func note(_ succeeded: Bool, error: Error? = nil) {
        lock.lock()
        let wasPaused = fallback.isPaused
        succeeded ? fallback.succeeded() : fallback.failed()
        let isPaused = fallback.isPaused
        lock.unlock()
        if isPaused && !wasPaused {
            DNSProxyProvider.log.error("""
                the encrypted resolver isn't answering (\(error?.localizedDescription ?? "no answer", privacy: .public)); \
                lookups go to the network's DNS for a minute
                """)
        } else if wasPaused && !isPaused {
            DNSProxyProvider.log.notice("the encrypted resolver answers again")
        }
    }

    /// Unencrypted, to the server it was meant for: as it would have gone.
    static func plain(_ query: Data, to server: NWHostEndpoint, reply: @escaping (Data?) -> Void) {
        guard let port = NWEndpoint.Port(server.port) else { reply(nil); return }
        let connection = NWConnection(host: NWEndpoint.Host(server.hostname), port: port, using: .udp)
        let done = Once()
        let finish: (Data?) -> Void = { answer in
            guard done.first() else { return }
            connection.cancel()
            reply(answer)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: query, completion: .contentProcessed { error in
                    if error != nil { finish(nil) }
                })
                connection.receiveMessage { data, _, _, _ in finish(data) }
            case .failed, .cancelled:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { finish(nil) }
    }
}

/// True the first time only, from any thread.
final class Once {
    private let lock = NSLock()
    private var done = false

    func first() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// One app's lookups over UDP: each datagram answered on its own, and the
/// answer written back as though from the server it was sent to.
final class UDPLookups {
    private let flow: NEAppProxyUDPFlow

    init(flow: NEAppProxyUDPFlow) {
        self.flow = flow
    }

    func start() {
        flow.open(withLocalEndpoint: nil) { [self] error in
            if let error {
                DNSProxyProvider.log.error("couldn't open a lookup: \(error.localizedDescription, privacy: .public)")
                return
            }
            read()
        }
    }

    private func read() {
        flow.readDatagrams { [self] datagrams, endpoints, error in
            guard error == nil, let datagrams, let endpoints, !datagrams.isEmpty else {
                flow.closeReadWithError(nil)
                flow.closeWriteWithError(nil)
                return
            }
            for (query, endpoint) in zip(datagrams, endpoints) {
                guard let server = endpoint as? NWHostEndpoint else { continue }
                Lookups.shared.answer(query, server: server) { [self] answer in
                    guard let answer else { return }
                    // The filter reads its aliases, as it read plain answers (#255).
                    Firewall.shared.learnLookup(answer)
                    flow.writeDatagrams([answer], sentBy: [endpoint]) { _ in }
                }
            }
            read()
        }
    }
}

/// Lookups over TCP, which are rare (an answer too big for UDP): passed on
/// to the server unchanged, with the aliases in its answers read on the way
/// (#321).
final class TCPRelay {
    private let flow: NEAppProxyTCPFlow
    private let connection: NWConnection
    private var answers = DNSStream()

    init(flow: NEAppProxyTCPFlow, remote: NWHostEndpoint) {
        self.flow = flow
        connection = NWConnection(host: NWEndpoint.Host(remote.hostname),
                                  port: NWEndpoint.Port(remote.port) ?? 53, using: .tcp)
    }

    func start() {
        flow.open(withLocalEndpoint: nil) { [self] error in
            guard error == nil else { return }
            connection.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    upstream()
                    downstream()
                case .failed, .cancelled:
                    close()
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private func upstream() {
        flow.readData { [self] data, error in
            guard error == nil, let data, !data.isEmpty else { close(); return }
            connection.send(content: data, completion: .contentProcessed { [self] error in
                error == nil ? upstream() : close()
            })
        }
    }

    private func downstream() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, finished, error in
            if let data, !data.isEmpty {
                if Firewall.shared.readsLookups { answers.append(data).forEach(Firewall.shared.learnLookup) }
                flow.write(data) { [self] error in
                    if error != nil { close() } else if !finished { downstream() } else { close() }
                }
            } else {
                close()
            }
            _ = error
        }
    }

    private func close() {
        connection.cancel()
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
    }
}
