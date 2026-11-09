import Foundation
import LowDataMode
import SystemConfiguration

/// Which connection the Mac is using, in words, for the popover and Settings
/// (#355). Joining a network doesn't mean using it: macOS sends everything over
/// the connection it ranks highest, so this says which one that is rather than
/// leaving someone to work it out from a total.
public struct ConnectionStatus: Equatable {
    /// "Using Ethernet", "Using hotspot · Kevin's iPhone".
    public let line: String
    /// Orange in the popover: this connection's total is the one that matters.
    public let isHighlighted: Bool
    /// What kind of link it is, in words: "Ethernet", "Wi-Fi", "iPhone USB".
    /// nil offline.
    public let medium: String?
    public let kind: NetworkFingerprint.Kind
    /// The network's name, the user's or its Wi-Fi name, or a tether's
    /// interface: "Kevin's iPhone". nil when there's none to show.
    public var name: String? = nil

    /// - Parameter name: the name to show, if there is one: the user's, or the
    ///   Wi-Fi network's. Not a remembered Wi-Fi name, which belongs to the
    ///   router, and so would call Ethernet through that router by it.
    public static func make(network: NetworkFingerprint,
                            verdict: MeteredHeuristic.Verdict,
                            name: String?) -> ConnectionStatus {
        guard network.kind != .offline else {
            return ConnectionStatus(line: L("No connection"), isHighlighted: false, medium: nil, kind: .offline)
        }
        let medium = medium(of: network)
        func joined(_ parts: String?...) -> String { parts.compactMap { $0 }.joined(separator: " · ") }

        switch verdict {
        case .constrained:
            // Low Data Mode is a statement about cost, not about a phone.
            return ConnectionStatus(line: joined(L("Using %@", medium), name, L("Low Data Mode")),
                                    isHighlighted: true, medium: medium, kind: network.kind, name: name)
        case _ where verdict.isMetered:
            // A tether has no Wi-Fi name, and the interface is what names it.
            let tether = network.kind == .hotspot && network.interfaceDisplayName != "Wi-Fi"
                ? network.interfaceDisplayName : nil
            return ConnectionStatus(line: joined(L("Using hotspot"), name ?? tether),
                                    isHighlighted: true, medium: medium, kind: network.kind, name: name ?? tether)
        default:
            return ConnectionStatus(line: joined(L("Using %@", medium), name),
                                    isHighlighted: false, medium: medium, kind: network.kind, name: name)
        }
    }

    private static func medium(of network: NetworkFingerprint) -> String {
        switch network.kind {
        case .ethernet: return L("Ethernet")
        case .wifi:     return L("Wi-Fi")
        default:        return network.interfaceDisplayName ?? L("a network")
        }
    }
}

/// A hotspot the Mac has joined but isn't sending anything over, because macOS
/// ranks another connection above it (#355).
public struct StandbyHotspot: Equatable {
    /// What to call it, if anything can: "Kevin's iPhone", "iPhone USB".
    public let name: String?
    /// The entry to move in macOS's service order: "Wi-Fi", "iPhone USB".
    public let service: String?

    public init(name: String?, service: String?) {
        self.name = name
        self.service = service
    }

    /// "Not using Kevin's iPhone", under "Using Ethernet". Short enough for
    /// one line in the popover's header, beside its buttons.
    public var message: String {
        name.map { L("Not using %@", $0) } ?? L("Not using the hotspot")
    }

    private var connected: String {
        name.map { L("%@ is connected, but isn't being used", $0) } ?? L("A hotspot is connected, but isn't being used")
    }

    /// Why, and how to change it, behind the ⓘ.
    public func explanation(inUse connection: ConnectionStatus) -> String {
        let move = L("move %@ above %@ in Network settings › Set Service Order",
                     service ?? L("the hotspot"), connection.medium ?? L("it"))
        let how: String
        switch connection.kind {
        case .ethernet: how = L("unplug the cable, or %@", move)
        case .wifi:     how = L("disconnect from that Wi-Fi network, or %@", move)
        default:        how = move
        }
        return L("%@. Your Mac sends everything over the connection ranked highest in macOS, and that's %@. To use the hotspot, %@.",
                 connected, connection.medium ?? L("another connection"), how)
    }

    /// Network › This network, which has room for the whole sentence.
    public func rightNow(inUse connection: ConnectionStatus) -> String {
        L("You're on %@. %@.", connection.medium ?? L("another connection"), connected)
    }
}

/// A connection the Mac has joined besides the one in use, with what the
/// heuristic reads from it. Whether it's a hotspot also takes what the person
/// said about that network, which the store holds: see `StandbyHotspots.pick`.
public struct StandbyCandidate: Equatable {
    public let networkID: String
    public let signals: MeteredHeuristic.Signals
    public let wifiName: String?
    public let service: String?
    public let isWiFi: Bool

    public init(networkID: String, signals: MeteredHeuristic.Signals, wifiName: String? = nil,
                service: String? = nil, isWiFi: Bool = true) {
        self.networkID = networkID
        self.signals = signals
        self.wifiName = wifiName
        self.service = service
        self.isWiFi = isWiFi
    }
}

/// Finds hotspots on connections that aren't in use. Reports only: History,
/// data use and hotspot pauses follow the connection in use, so an idle hotspot
/// never counts as being on one.
public enum StandbyHotspots {

    /// A link with a router, from configd's service state.
    public struct Link: Equatable {
        public let interface: String
        public let router: String
        public let routerMAC: String?
        public let androidSaysMetered: Bool
    }

    /// Every other physical link that has a router. A tunnel isn't a network
    /// you're on, and a link without a router has no way to the internet.
    public static func links(besides inUse: String?, in states: [String: Any]) -> [Link] {
        states.keys.filter { $0.hasSuffix("/IPv4") }.sorted().compactMap { key in
            guard let ipv4 = states[key] as? [String: Any],
                  let interface = ipv4["InterfaceName"] as? String,
                  interface != inUse,
                  LowDataMode.isPhysicalInterface(interface),
                  let router = ipv4["Router"] as? String, !router.isEmpty
            else { return nil }
            return Link(interface: interface,
                        router: router,
                        routerMAC: GatewayProbe.routerMAC(forGateway: router, in: [ipv4]),
                        androidSaysMetered: AndroidTethering.saysMetered(onInterface: interface, in: states))
        }
    }

    /// The live version: what configd and the interface flags say now.
    public static func candidates(besides inUse: String?,
                                  ownership: InterfaceFlagOwnership,
                                  wifiName: (String) -> String?) -> [StandbyCandidate] {
        guard let store = SCDynamicStoreCreate(nil, "NetworkMonitor" as CFString, nil, nil),
              let states = SCDynamicStoreCopyMultiple(
                store, nil, ["State:/Network/Service/[^/]+/(IPv4|DHCP)"] as CFArray) as? [String: Any]
        else { return [] }

        return links(besides: inUse, in: states).map { link in
            let service = InterfaceNaming.displayName(forBSDName: link.interface)
            let flags = InterfaceProbe.flags(on: link.interface)
            // Low Data Mode is left out: on a home Wi-Fi network sitting idle
            // beside Ethernet, it says nothing about a phone.
            let signals = ownership.masking(
                MeteredHeuristic.Signals(isExpensive: flags?.expensive == true,
                                         androidSaysMetered: link.androidSaysMetered,
                                         isConstrained: false,
                                         gatewayIP: link.router,
                                         interfaceDisplayName: service),
                on: link.interface)
            let id = NetworkFingerprint.make(kind: .hotspot, gatewayMAC: link.routerMAC,
                                             interfaceName: link.interface, isExpensive: false,
                                             isConstrained: false, gatewayIP: link.router).id
            let name = wifiName(link.interface)
                ?? HotspotName.name(onInterface: link.interface, router: link.router)
            return StandbyCandidate(networkID: id, signals: signals, wifiName: name,
                                    service: service, isWiFi: InterfaceNaming.isWiFi(bsdName: link.interface))
        }
    }

    /// The hotspot to mention, if any. None while the connection in use is
    /// itself a hotspot, or the Mac has no connection: then nothing is being
    /// passed over for something else.
    public static func pick(_ candidates: [StandbyCandidate],
                            inUse network: NetworkFingerprint,
                            inUseIsMetered: Bool,
                            override: (String) -> Bool?,
                            label: (String) -> String?) -> StandbyHotspot? {
        guard network.kind != .offline, !inUseIsMetered else { return nil }
        for candidate in candidates where candidate.networkID != network.id {
            var signals = candidate.signals
            signals.userOverride = override(candidate.networkID)
            guard MeteredHeuristic.verdict(for: signals).isMetered else { continue }
            let name = label(candidate.networkID)
                ?? candidate.wifiName
                ?? (candidate.isWiFi ? nil : candidate.service)
            return StandbyHotspot(name: name, service: candidate.service)
        }
        return nil
    }
}
