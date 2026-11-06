import Darwin
import Foundation

/// Notices a filter that's on but has gone quiet (#272). After an update
/// macOS once handed the filter no connections for 35 minutes, while holding
/// every new one back: nothing got out, and nothing was reported.
///
/// Pure, so it's tested on its own: `FilterController` ticks it, tells it
/// when the filter was heard from, and does what it says.
public struct FilterWatchdog: Equatable {

    public enum Action: Equatable {
        case none
        /// Make a test connection, which the filter reports when it's working.
        case probe
        /// Nothing came back: reconnect to the filter, and test again.
        case reconnect
        /// Still nothing: switch the filter off and on.
        case restart
    }

    private enum Step: Equatable {
        case probing(since: Date)
        case reconnected(since: Date)
    }

    /// Silence this long, and it tests.
    public static let quiet: TimeInterval = 120
    /// A working filter reports within a second; this allows for a busy one.
    public static let wait: TimeInterval = 10
    /// A restart that didn't help isn't repeated sooner than this.
    public static let restartGap: TimeInterval = 15 * 60

    private var lastHeard: Date
    private var step: Step?
    private var lastRestart: Date?

    public init(now: Date = Date()) {
        lastHeard = now
    }

    /// The filter reported something.
    public mutating func heard(at now: Date = Date()) {
        lastHeard = now
        step = nil
    }

    /// A test connection that couldn't start, with no network to make it on,
    /// proves nothing either way: wait another quiet spell.
    public mutating func probeCouldNotStart(at now: Date = Date()) {
        heard(at: now)
    }

    public mutating func tick(at now: Date = Date()) -> Action {
        switch step {
        case nil:
            guard now.timeIntervalSince(lastHeard) >= Self.quiet else { return .none }
            step = .probing(since: now)
            return .probe
        case .probing(let since)?:
            guard now.timeIntervalSince(since) >= Self.wait else { return .none }
            step = .reconnected(since: now)
            return .reconnect
        case .reconnected(let since)?:
            guard now.timeIntervalSince(since) >= Self.wait else { return .none }
            // Start over either way: the next quiet spell tests again.
            heard(at: now)
            if let lastRestart, now.timeIntervalSince(lastRestart) < Self.restartGap { return .none }
            lastRestart = now
            return .restart
        }
    }

    // MARK: The test connection

    /// RFC 5737's documentation-only address: nothing answers, and nothing
    /// is sent but the attempt.
    public static let probeAddress = "192.0.2.1"
    public static let probePort: UInt16 = 9

    /// Whether a report is the app's own test connection, which isn't one of
    /// the person's.
    public static func isProbe(address: String, port: Int, pid: Int32) -> Bool {
        address == probeAddress && port == Int(probePort) && pid == getpid()
    }

    /// Starts a connection to the probe address and closes it a few seconds
    /// later. False when it couldn't start (no route, no network).
    @discardableResult
    public static func startProbe() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = probePort.bigEndian
        inet_pton(AF_INET, probeAddress, &address.sin_addr)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 || errno == EINPROGRESS else {
            close(fd)
            return false
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + wait) { close(fd) }
        return true
    }
}
