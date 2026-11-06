import Darwin
import Foundation

/// Watches the network for two minutes after an update has brought in a new
/// filter (#278). Twice, swapping a running filter for the new one left
/// macOS dropping every packet, even pings to the router, while the filter
/// itself was up and reporting, so the watchdog (#272) had nothing to see.
///
/// The app asks the router for an answer before the swap and every few
/// seconds after it. If it answered before and stops answering after,
/// `FilterController` switches the filter off and on.
///
/// Pure, so it's tested on its own.
public struct UpdateGuard: Equatable {

    public enum Action: Equatable {
        case keepChecking
        /// Two minutes without a cut-off.
        case done
        /// The router stopped answering: switch the filter off and on.
        case restart
    }

    /// How often it asks the router.
    public static let interval: TimeInterval = 5
    /// How long it watches.
    public static let watchFor: TimeInterval = 120
    /// Unanswered in a row before it acts: a second or two without network
    /// is expected while the filter comes back on.
    public static let misses = 3

    private let started: Date
    private var missed = 0

    public init(now: Date = Date()) {
        started = now
    }

    /// What the router did: answered, didn't, or there was no router to ask
    /// (no network), which counts for nothing either way.
    public mutating func checked(_ answered: Bool?, at now: Date = Date()) -> Action {
        switch answered {
        case true?:
            missed = 0
        case false?:
            missed += 1
            if missed >= Self.misses { return .restart }
        case nil:
            break
        }
        return now.timeIntervalSince(started) >= Self.watchFor ? .done : .keepChecking
    }

    // MARK: Asking the router

    /// The IPv4 router `route -n get default` names, if any. A VPN's default
    /// route names an interface instead, and there's nothing to ping.
    public static func gateway(fromRouteOutput output: String) -> String? {
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == "gateway" else { continue }
            var address = in_addr()
            return inet_pton(AF_INET, parts[1], &address) == 1 ? parts[1] : nil
        }
        return nil
    }

    /// Whether the router answers a ping, off the main queue. Nil when
    /// there's no router to ask.
    public static func routerAnswers(_ completion: @escaping (Bool?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard let route = run("/sbin/route", ["-n", "get", "default"]),
                  let gateway = gateway(fromRouteOutput: route.output)
            else { completion(nil); return }
            let ping = run("/sbin/ping", ["-n", "-q", "-c", "1", "-t", "2", gateway])
            completion(ping?.status == 0)
        }
    }

    private static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// `net.necp.drop_all_level`, for the log: what macOS's drop-all is set
    /// to around a swap. It read 12 with the network working.
    public static var dropAllLevel: Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("net.necp.drop_all_level", &value, &size, nil, 0) == 0 ? value : nil
    }
}
