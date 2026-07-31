import Foundation
import Network

/// Identifies *which* network you are attached to, so usage can be bucketed per
/// network instead of wiped whenever connectivity blips.
///
/// Deliberately does **not** use SSID. On macOS 26 both non-Location routes to
/// the SSID are dead ends — verified on the development machine while connected
/// to Wi-Fi:
///
///   $ networksetup -getairportnetwork en0
///   You are not associated with an AirPort network.   ← withheld, not true
///   $ system_profiler SPAirPortDataType | grep -i ssid
///   (redacted)
///
/// So SSID means prompting for Location access. The default gateway's MAC
/// address needs no permission, and is a *better* fingerprint: it distinguishes
/// two different routers that share an SSID name, and survives a Wi-Fi roam
/// between access points on the same network (where the BSSID changes but the
/// gateway does not).
public struct NetworkFingerprint: Equatable {

    public enum Kind: String, Codable {
        case wifi, ethernet, hotspot, other, offline
    }

    /// Stable identity used as the usage-bucket key.
    public let id: String
    public let kind: Kind
    public let gatewayMAC: String?
    /// Shown until the user renames the network.
    public let defaultLabel: String
    /// From `NWPath.isExpensive` — true for Personal Hotspot and cellular.
    /// This is the hook for metered-network features.
    public let isExpensive: Bool
    /// From `NWPath.isConstrained` — macOS Low Data Mode.
    public let isConstrained: Bool

    public init(id: String,
                kind: Kind,
                gatewayMAC: String?,
                defaultLabel: String,
                isExpensive: Bool,
                isConstrained: Bool) {
        self.id = id
        self.kind = kind
        self.gatewayMAC = gatewayMAC
        self.defaultLabel = defaultLabel
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    public static let offline = NetworkFingerprint(
        id: "offline", kind: .offline, gatewayMAC: nil,
        defaultLabel: "No Connection", isExpensive: false, isConstrained: false)

    public static func make(kind: Kind,
                     gatewayMAC: String?,
                     interfaceName: String?,
                     isExpensive: Bool,
                     isConstrained: Bool) -> NetworkFingerprint {
        // Keying on the gateway MAC alone (not MAC + medium) means moving the
        // same router from Wi-Fi to Ethernet keeps one bucket, which is what a
        // data cap cares about.
        let identifier: String
        if let mac = gatewayMAC {
            identifier = "gw:\(mac)"
        } else if let interfaceName {
            identifier = "if:\(interfaceName)"
        } else {
            identifier = "unknown"
        }

        let base: String
        switch kind {
        case .hotspot:  base = "Personal Hotspot"
        case .wifi:     base = "Wi-Fi"
        case .ethernet: base = "Ethernet"
        case .other:    base = "Network"
        case .offline:  base = "No Connection"
        }

        // A short MAC suffix disambiguates several networks of the same kind
        // before the user renames them.
        var label = base
        if let mac = gatewayMAC {
            let suffix = mac.replacingOccurrences(of: ":", with: "").suffix(4)
            label = "\(base) · \(suffix)"
        }

        return NetworkFingerprint(id: identifier,
                                  kind: kind,
                                  gatewayMAC: gatewayMAC,
                                  defaultLabel: label,
                                  isExpensive: isExpensive,
                                  isConstrained: isConstrained)
    }
}

/// Watches for genuine network changes and reports the current fingerprint.
public final class NetworkIdentityWatcher {

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.networkmonitor.path")
    private var debounce: DispatchWorkItem?
    private var current: NetworkFingerprint = .offline

    /// Fires only when the fingerprint actually changes, on the main queue.
    public var onChange: ((NetworkFingerprint) -> Void)?

    public init() {}

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handle(path)
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        monitor.cancel()
    }

    public var fingerprint: NetworkFingerprint { current }

    /// `NWPathMonitor` is chatty — it fires on VPN up/down, AWDL flaps, DNS
    /// changes and interface metric changes, several times for a single logical
    /// event. Debouncing collapses that burst into one evaluation, and the
    /// fingerprint comparison then discards changes that aren't real.
    private func handle(_ path: NWPath) {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let next = Self.fingerprint(for: path)
            guard next != self.current else { return }
            self.current = next
            DispatchQueue.main.async { self.onChange?(next) }
        }
        debounce = work
        // 2 s is comfortably longer than a DHCP handshake burst and short
        // enough that bucket switching feels immediate.
        queue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    static func fingerprint(for path: NWPath) -> NetworkFingerprint {
        guard path.status == .satisfied else { return .offline }

        let kind: NetworkFingerprint.Kind
        if path.isExpensive {
            // Personal Hotspot and cellular both surface as expensive.
            kind = .hotspot
        } else if path.usesInterfaceType(.wiredEthernet) {
            kind = .ethernet
        } else if path.usesInterfaceType(.wifi) {
            kind = .wifi
        } else {
            kind = .other
        }

        // The interface carrying the default route, ignoring tunnels: a VPN's
        // utun is not the network you are *on*.
        let interfaceName = path.availableInterfaces.first {
            $0.type == .wifi || $0.type == .wiredEthernet || $0.type == .cellular
        }?.name

        return .make(kind: kind,
                     gatewayMAC: GatewayProbe.macAddress(),
                     interfaceName: interfaceName,
                     isExpensive: path.isExpensive,
                     isConstrained: path.isConstrained)
    }
}

/// Resolves the default gateway's hardware address.
///
/// Shells out to `route` and `arp` rather than walking the routing table via
/// `sysctl(NET_RT_FLAGS)`. This runs only on a debounced network change — a few
/// times a day — so the pointer-arithmetic version buys nothing and risks more.
public enum GatewayProbe {

    public static func macAddress() -> String? {
        guard let gateway = defaultGatewayIP() else { return nil }

        // The ARP entry can be missing for a moment right after association,
        // even though the gateway is reachable. Retry briefly rather than
        // fingerprinting the network as unknown.
        for attempt in 0..<5 {
            if let mac = arpLookup(gateway) { return mac }
            if attempt < 4 { Thread.sleep(forTimeInterval: 0.4) }
        }
        return nil
    }

    public static func defaultGatewayIP() -> String? {
        guard let output = run("/sbin/route", ["-n", "get", "default"]) else { return nil }
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "gateway"
            else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Parses `? (192.168.1.1) at 50:c7:bf:8a:94:93 on en0 ifscope [ethernet]`
    public static func arpLookup(_ ip: String) -> String? {
        guard let output = run("/usr/sbin/arp", ["-n", ip]) else { return nil }
        return parseARP(output)
    }

    public static func parseARP(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ").map(String.init)
            guard let atIndex = fields.firstIndex(of: "at"), atIndex + 1 < fields.count
            else { continue }
            let candidate = fields[atIndex + 1]
            // "(incomplete)" appears while the entry is still resolving.
            guard candidate.contains(":"), candidate != "(incomplete)" else { continue }
            return normalizeMAC(candidate)
        }
        return nil
    }

    /// macOS prints MACs without leading zeros (`50:c7:bf:8a:94:93` but also
    /// `0:1b:63:...`). Normalising keeps a network's key stable regardless.
    public static func normalizeMAC(_ mac: String) -> String {
        mac.split(separator: ":")
            .map { $0.count == 1 ? "0\($0)" : String($0) }
            .joined(separator: ":")
            .lowercased()
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
