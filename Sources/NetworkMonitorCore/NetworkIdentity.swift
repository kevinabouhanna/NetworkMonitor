import Foundation
import Network
import SystemConfiguration

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
    /// Default gateway's IPv4 address, which `MeteredHeuristic` reads as a
    /// tethering signal. Already resolved on the way to the gateway MAC, so it
    /// costs nothing extra to keep.
    public let gatewayIP: String?
    /// Localised name of the interface carrying the default route — `"Wi-Fi"`,
    /// `"iPhone USB"`. The last automatic tethering signal.
    public let interfaceDisplayName: String?
    /// BSD name of that interface — `en0`, `en5`. What Low Data Mode is held on,
    /// and so what tells the app's own flags apart from the network's: see
    /// `InterfaceFlagOwnership`.
    public let interfaceName: String?

    /// Everything `MeteredHeuristic` needs except the user's own decision, which
    /// lives in the store and is deliberately **not** part of the fingerprint:
    /// were it here, toggling the override would change the fingerprint, which
    /// §4.2 reads as joining a different network and answers by wiping the
    /// bucket. Marking a network metered must not delete its history.
    public var signals: MeteredHeuristic.Signals {
        MeteredHeuristic.Signals(userOverride: nil,
                                 isExpensive: isExpensive,
                                 isConstrained: isConstrained,
                                 gatewayIP: gatewayIP,
                                 interfaceDisplayName: interfaceDisplayName)
    }

    public init(id: String,
                kind: Kind,
                gatewayMAC: String?,
                defaultLabel: String,
                isExpensive: Bool,
                isConstrained: Bool,
                gatewayIP: String? = nil,
                interfaceDisplayName: String? = nil,
                interfaceName: String? = nil) {
        self.id = id
        self.kind = kind
        self.gatewayMAC = gatewayMAC
        self.defaultLabel = defaultLabel
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.gatewayIP = gatewayIP
        self.interfaceDisplayName = interfaceDisplayName
        self.interfaceName = interfaceName
    }

    public static let offline = NetworkFingerprint(
        id: "offline", kind: .offline, gatewayMAC: nil,
        defaultLabel: "No Connection", isExpensive: false, isConstrained: false)

    public static func make(kind: Kind,
                     gatewayMAC: String?,
                     interfaceName: String?,
                     isExpensive: Bool,
                     isConstrained: Bool,
                     gatewayIP: String? = nil,
                     interfaceDisplayName: String? = nil) -> NetworkFingerprint {
        // Keying on the gateway MAC alone (not MAC + medium) means moving the
        // same router from Wi-Fi to Ethernet keeps one bucket, which is what a
        // data cap cares about.
        let identifier: String
        if let mac = gatewayMAC {
            identifier = "gw:\(mac)"
        } else if let interfaceName {
            // The router's IP, while its address is unknown, keeps an iPhone
            // hotspot (172.20.10.1) apart from home Wi-Fi on the same interface.
            // On the interface alone they were one network (#70). Two routers
            // on the same IP still share a key until the address is known.
            identifier = gatewayIP.map { "if:\(interfaceName)@\($0)" } ?? "if:\(interfaceName)"
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
                                  isConstrained: isConstrained,
                                  gatewayIP: gatewayIP,
                                  interfaceDisplayName: interfaceDisplayName,
                                  interfaceName: interfaceName)
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

    /// The interface flags this app raised itself, kept out of `kind`.
    private let ownership: InterfaceFlagOwnership

    public init(ownership: InterfaceFlagOwnership = .shared) {
        self.ownership = ownership
    }

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
            let next = Self.fingerprint(for: path, ownership: self.ownership)
            guard next != self.current else { return }
            self.current = next
            DispatchQueue.main.async { self.onChange?(next) }
        }
        debounce = work
        // 2 s is comfortably longer than a DHCP handshake burst and short
        // enough that bucket switching feels immediate.
        queue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    static func fingerprint(for path: NWPath,
                            ownership: InterfaceFlagOwnership) -> NetworkFingerprint {
        guard path.status == .satisfied else { return .offline }

        // The interface carrying the default route, ignoring tunnels: a VPN's
        // utun is not the network you are *on*.
        let interfaceName = path.availableInterfaces.first {
            $0.type == .wifi || $0.type == .wiredEthernet || $0.type == .cellular
        }?.name

        // Resolved once and threaded through: `GatewayProbe.macAddress()` needs
        // the gateway IP anyway, and the heuristic reads it as a tethering
        // signal, so asking `route` twice would buy nothing.
        let gatewayIP = GatewayProbe.defaultGatewayIP()
        let gatewayMAC = gatewayIP.flatMap(GatewayProbe.macAddress(forGateway:))
        let displayName = interfaceName.flatMap(InterfaceNaming.displayName(forBSDName:))

        // Masked, for the same reason the override is left out below: putting a
        // hotel network the user marked metered into Low Data Mode must not turn
        // it into a "Personal Hotspot". The fingerprint itself keeps the raw
        // flags, so a flag macOS lowers behind our back is still a change the
        // controller hears about and can re-assert.
        let signals = ownership.masking(
            MeteredHeuristic.Signals(userOverride: nil,
                                     isExpensive: path.isExpensive,
                                     isConstrained: path.isConstrained,
                                     gatewayIP: gatewayIP,
                                     interfaceDisplayName: displayName),
            on: interfaceName)

        // `kind` follows the heuristic rather than `isExpensive` alone. The old
        // ordering tested `isExpensive` first and fell through to `.ethernet`
        // for anything unflagged, which classified iPhone USB tethering — an
        // Ethernet-type interface — as a wired network, badge and all.
        //
        // The override is not consulted here: `kind` is part of the identity and
        // has to stay stable while the user changes their mind about it.
        let kind: NetworkFingerprint.Kind
        if MeteredHeuristic.verdict(for: signals).isMetered {
            kind = .hotspot
        } else if path.usesInterfaceType(.wiredEthernet) {
            kind = .ethernet
        } else if path.usesInterfaceType(.wifi) {
            kind = .wifi
        } else {
            kind = .other
        }

        return .make(kind: kind,
                     gatewayMAC: gatewayMAC,
                     interfaceName: interfaceName,
                     isExpensive: path.isExpensive,
                     isConstrained: path.isConstrained,
                     gatewayIP: gatewayIP,
                     interfaceDisplayName: displayName)
    }
}

/// Resolves the default gateway's hardware address.
///
/// From configd first, then `arp`. The gateway's IP comes from `route` rather
/// than walking the routing table via `sysctl(NET_RT_FLAGS)`. This runs only on
/// a debounced network change — a few times a day — so the pointer-arithmetic
/// version buys nothing and risks more.
public enum GatewayProbe {

    public static func macAddress() -> String? {
        guard let gateway = defaultGatewayIP() else { return nil }
        return macAddress(forGateway: gateway)
    }

    /// As `macAddress()`, for a gateway IP the caller has already resolved.
    ///
    /// `fingerprint(for:)` needs the IP in its own right — it is one of the
    /// tethering signals — so this exists to keep it from shelling out to
    /// `route` a second time for an answer it is already holding.
    public static func macAddress(forGateway gateway: String) -> String? {
        // The ARP entry can be missing for a moment right after association,
        // even though the gateway is reachable. Retry briefly rather than
        // fingerprinting the network as unknown.
        for attempt in 0..<5 {
            if let mac = configdLookup(gateway) ?? arpLookup(gateway) { return mac }
            if attempt < 4 { Thread.sleep(forTimeInterval: 0.4) }
        }
        return nil
    }

    /// The router's hardware address as configd resolved it, which needs no
    /// permission (#70).
    ///
    /// macOS 27 hides the ARP table from apps without Local Network access:
    /// `arp -n` run by NetworkMonitor answered "no entry" for a router that a
    /// terminal showed, so from 27.0.1 on every network fell back to the same
    /// `if:en0` key. configd resolves the router itself, for the network
    /// signature it keeps, and publishes it in each service's IPv4 state, which
    /// any process can read. Checked from a process `arp` answered "no entry"
    /// to: configd gave it the router's address all the same.
    public static func configdLookup(_ gateway: String) -> String? {
        guard let store = SCDynamicStoreCreate(nil, "NetworkMonitor" as CFString, nil, nil),
              let states = SCDynamicStoreCopyMultiple(
                store, nil, ["State:/Network/Service/[^/]+/IPv4"] as CFArray) as? [String: Any]
        else { return nil }
        return routerMAC(forGateway: gateway, in: Array(states.values))
    }

    /// From services' IPv4 state, the address resolved for `gateway`. Matched
    /// on the router's IP, since a VPN or a second interface has a service of
    /// its own.
    public static func routerMAC(forGateway gateway: String, in states: [Any]) -> String? {
        for case let state as [String: Any] in states
        where state["ARPResolvedIPAddress"] as? String == gateway {
            if let mac = state["ARPResolvedHardwareAddress"] as? String, mac.contains(":") {
                return normalizeMAC(mac)
            }
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

    /// Parses `? (192.168.1.1) at 0:0:5e:0:53:2a on en0 ifscope [ethernet]`
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

    /// macOS prints MACs without leading zeros (`0:0:5e:0:53:2a` for
    /// `00:00:5e:00:53:2a`). Normalising keeps a network's key stable regardless.
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
