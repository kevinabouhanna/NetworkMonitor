import Foundation

/// One socket on loopback, with its two ports. See `NettopRow.loopback`.
public struct LoopbackSocket: Equatable {
    public let localPort: Int
    public let remotePort: Int
    public let bytesIn: Int64
    public let bytesOut: Int64

    public init(localPort: Int, remotePort: Int, bytesIn: Int64, bytesOut: Int64) {
        self.localPort = localPort
        self.remotePort = remotePort
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

/// The program that carries other apps' traffic: a proxy such as Clash
/// (Mihomo) or sing-box, or a VPN's packet tunnel (#356).
///
/// Every app's traffic goes into it, through its tunnel (`utun`, its "TUN
/// mode") or through its port on loopback (set as the system's proxy), and
/// leaves the Mac as its own. So `nettop -t external` counts all of it as the
/// carrier's.
public enum TunnelCarrier {
    /// Proxies that run as programs of their own rather than as a Network
    /// Extension, by the name of their executable: Mihomo (inside Clash Verge
    /// Rev as `verge-mihomo`, Mihomo Party, FlClash's `FlClashCore`), the older
    /// Clash cores, sing-box, Xray and V2Ray, Hysteria, tun2socks.
    static let proxyNames = ["mihomo", "verge-mihomo", "clash", "flclashcore", "sing-box",
                             "xray", "v2ray", "hysteria", "tun2socks"]

    /// Whether the process carries other apps' traffic: a proxy by name, or
    /// any Network Extension packet tunnel (WireGuard, Tailscale, Surge…).
    public static func isCarrier(processName: String, path: String?) -> Bool {
        let names = [processName, path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""]
            .map { $0.lowercased() }
        if names.contains(where: { name in proxyNames.contains { name.hasPrefix($0) } }) { return true }
        guard let path else { return false }
        return isPacketTunnelProvider(executablePath: path)
    }

    /// An executable inside an app extension or a system extension that
    /// declares a packet tunnel in its Info.plist.
    public static func isPacketTunnelProvider(executablePath: String) -> Bool {
        var url = URL(fileURLWithPath: executablePath)
        while url.pathComponents.count > 1 {
            if ["appex", "systemextension"].contains(url.pathExtension) {
                return declaresPacketTunnel(infoPlist: url.appendingPathComponent("Contents/Info.plist"))
            }
            url.deleteLastPathComponent()
        }
        return false
    }

    static let packetTunnel = "com.apple.networkextension.packet-tunnel"

    public static func declaresPacketTunnel(infoPlist: URL) -> Bool {
        guard let data = try? Data(contentsOf: infoPlist),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        if let ext = plist["NSExtension"] as? [String: Any],
           (ext["NSExtensionPointIdentifier"] as? String)?.hasPrefix(packetTunnel) == true {
            return true
        }
        if let ne = plist["NetworkExtension"] as? [String: Any],
           let classes = ne["NEProviderClasses"] as? [String: Any],
           classes.keys.contains(where: { $0.hasPrefix(packetTunnel) }) {
            return true
        }
        return false
    }
}

/// Traffic through a proxy or a VPN, credited to the apps that sent it (#356).
///
/// With Clash in TUN mode, `nettop -t external` sees one app on the internet,
/// the proxy: the apps' own sockets are on its tunnel (`utun`), which has no
/// interface type `-t external` takes. Measured in a VM with Mihomo 1.19, both
/// stacks: a 30 MB download by `curl` showed as 30 MB by `mihomo` and nothing
/// by `curl`. Without `-t`, `curl`'s socket is there, on `utun4`, with its
/// bytes. Set as the system's proxy instead, the apps' sockets go to its port
/// on loopback, which `-t external` leaves out too.
///
/// So while a carrier moves traffic (`TunnelCarrier`), a second `nettop`
/// with no `-t` reads only those rows: each app's bytes into a tunnel the
/// main stream can't see, and to a port the carrier listens on over
/// loopback. They're added to the app, and taken off the carrier, never more
/// than the carrier moved in the same sample, so the apps add up to what they
/// did before. What's left on the carrier is its own traffic and its overhead.
/// A tunnel the main stream already shows (some VPNs') is counted once: its
/// bytes are already the apps', so they only come off the carrier.
///
/// Not used for: Connections and the firewall, which see the apps' own
/// connections already (the content filter is below the tunnel); and the
/// servers in Usage History, which stay the carrier's for its share.
public enum TunnelCredit {

    /// What one app sent into a tunnel or to a carrier's port, by pid.
    public struct Hidden: Equatable {
        public var processName: String
        public var bytes: ByteCounts

        public init(processName: String, bytes: ByteCounts) {
            self.processName = processName
            self.bytes = bytes
        }
    }

    /// The traffic the main stream can't see in a sample of the second
    /// stream: each app's bytes on a tunnel not in `visibleTunnels`, and over
    /// loopback to a port a carrier is listening on in the same sample.
    public static func hidden(in sample: [NettopRow], visibleTunnels: Set<String>,
                              isCarrier: (NettopRow) -> Bool) -> [Int32: Hidden] {
        var carrierPorts = Set<Int>()
        var carrierPIDs = Set<Int32>()
        for row in sample where isCarrier(row) {
            carrierPIDs.insert(row.pid)
            // The ports it listens on; not the ephemeral ones it connects from
            // (macOS hands those out from 49152 up), whose far end is a
            // server, not an app using the proxy.
            for socket in row.loopback where socket.localPort < 49152 { carrierPorts.insert(socket.localPort) }
        }
        guard !carrierPIDs.isEmpty else { return [:] }
        var hidden: [Int32: Hidden] = [:]
        for row in sample where !carrierPIDs.contains(row.pid) {
            var bytes = ByteCounts(bytesIn: 0, bytesOut: 0)
            for (interface, counts) in row.tunnels where !visibleTunnels.contains(interface) { bytes += counts }
            for socket in row.loopback where carrierPorts.contains(socket.remotePort) {
                bytes += ByteCounts(bytesIn: socket.bytesIn, bytesOut: socket.bytesOut)
            }
            guard bytes.bytesIn > 0 || bytes.bytesOut > 0 else { continue }
            hidden[row.pid, default: Hidden(processName: row.processName, bytes: ByteCounts(bytesIn: 0, bytesOut: 0))]
                .bytes += bytes
        }
        return hidden
    }

    public struct Result {
        public var rows: [NettopRow]
        /// The carriers that had traffic taken off them, by pid.
        public var carriers: Set<Int32>
        /// Of `hidden`, what wasn't credited, for the next sample.
        public var left: [Int32: Hidden]
    }

    /// The main stream's sample with `hidden` credited to its apps and taken
    /// off the carriers.
    public static func apply(to sample: [NettopRow], hidden: [Int32: Hidden],
                             isCarrier: (NettopRow) -> Bool) -> Result {
        let carriers = sample.filter(isCarrier)
        let carrierPIDs = Set(carriers.map(\.pid))
        guard !carriers.isEmpty else { return Result(rows: sample, carriers: [], left: hidden) }

        // What the carriers moved, each way: the most that can be someone else's.
        var budgetIn = carriers.reduce(Int64(0)) { $0 + $1.internetBytesIn }
        var budgetOut = carriers.reduce(Int64(0)) { $0 + $1.internetBytesOut }

        // A tunnel the main stream shows is already the apps': only the
        // carrier's copy goes.
        var takenIn: Int64 = 0, takenOut: Int64 = 0
        for row in sample where !carrierPIDs.contains(row.pid) {
            let visible = row.tunnelBytes
            let inPart = min(visible.bytesIn, budgetIn), outPart = min(visible.bytesOut, budgetOut)
            budgetIn -= inPart; budgetOut -= outPart
            takenIn += inPart; takenOut += outPart
        }

        // The rest, each way in the same proportion to every app.
        let hiddenIn = hidden.values.reduce(Int64(0)) { $0 + $1.bytes.bytesIn }
        let hiddenOut = hidden.values.reduce(Int64(0)) { $0 + $1.bytes.bytesOut }
        let shareIn = hiddenIn > 0 ? min(1, Double(budgetIn) / Double(hiddenIn)) : 0
        let shareOut = hiddenOut > 0 ? min(1, Double(budgetOut) / Double(hiddenOut)) : 0
        var credit: [Int32: ByteCounts] = [:]
        var left: [Int32: Hidden] = [:]
        for (pid, entry) in hidden where !carrierPIDs.contains(pid) {
            let given = ByteCounts(bytesIn: Int64((Double(entry.bytes.bytesIn) * shareIn).rounded(.down)),
                                   bytesOut: Int64((Double(entry.bytes.bytesOut) * shareOut).rounded(.down)))
            credit[pid] = given
            takenIn += given.bytesIn; takenOut += given.bytesOut
            let rest = ByteCounts(bytesIn: entry.bytes.bytesIn - given.bytesIn, bytesOut: entry.bytes.bytesOut - given.bytesOut)
            if rest.bytesIn > 0 || rest.bytesOut > 0 { left[pid] = Hidden(processName: entry.processName, bytes: rest) }
        }
        guard takenIn > 0 || takenOut > 0 else { return Result(rows: sample, carriers: [], left: left) }

        // Off the carriers, each in proportion to what it moved.
        let movedIn = carriers.reduce(Int64(0)) { $0 + $1.internetBytesIn }
        let movedOut = carriers.reduce(Int64(0)) { $0 + $1.internetBytesOut }
        var rows: [NettopRow] = []
        var seen = Set<Int32>()
        for row in sample {
            seen.insert(row.pid)
            if carrierPIDs.contains(row.pid) {
                let offIn = movedIn > 0 ? Int64((Double(takenIn) * Double(row.internetBytesIn) / Double(movedIn)).rounded()) : 0
                let offOut = movedOut > 0 ? Int64((Double(takenOut) * Double(row.internetBytesOut) / Double(movedOut)).rounded()) : 0
                rows.append(row.adding(ByteCounts(bytesIn: -min(offIn, row.internetBytesIn),
                                                  bytesOut: -min(offOut, row.internetBytesOut))))
            } else if let given = credit[row.pid] {
                rows.append(row.adding(given))
            } else {
                rows.append(row)
            }
        }
        // An app with nothing outside the tunnel has no row in the main stream.
        for (pid, given) in credit.sorted(by: { $0.key < $1.key })
        where !seen.contains(pid) && (given.bytesIn > 0 || given.bytesOut > 0) {
            rows.append(NettopRow(pid: pid, processName: hidden[pid]?.processName ?? "",
                                  bytesIn: given.bytesIn, bytesOut: given.bytesOut))
        }
        return Result(rows: rows, carriers: Set(carriers.filter { $0.internetBytesIn > 0 || $0.internetBytesOut > 0 }.map(\.pid)),
                      left: left)
    }
}

extension NettopRow {
    /// The same row with internet bytes added (or, negative, taken off).
    func adding(_ bytes: ByteCounts) -> NettopRow {
        NettopRow(pid: pid, processName: processName,
                  bytesIn: bytesIn + bytes.bytesIn, bytesOut: bytesOut + bytes.bytesOut,
                  localBytesIn: localBytesIn, localBytesOut: localBytesOut,
                  subtractableLocalIn: subtractableLocalIn, subtractableLocalOut: subtractableLocalOut,
                  servers: servers, tunnels: tunnels, loopback: loopback)
    }
}

/// Runs `TunnelCredit` for `MonitorViewModel`: the second `nettop`, only
/// while a carrier moves traffic, and what it saw since the last sample. On
/// the main thread.
public final class TunnelCreditor {
    /// The carrier whose traffic went to the apps in the last minute, by pid,
    /// for Network to name it.
    public private(set) var activeCarrier: Int32?
    public var onActiveCarrierChange: ((Int32?) -> Void)?

    private let stream: NettopStream
    private let isCarrierProcess: (Int32, String) -> Bool
    private var carrierCache: [Int32: Bool] = [:]
    /// What the second stream saw since the last main sample, and what of
    /// the one before wasn't credited yet.
    private var fresh: [Int32: TunnelCredit.Hidden] = [:]
    private var carried: [Int32: TunnelCredit.Hidden] = [:]
    private var visibleTunnels: [String: Date] = [:]
    private var lastCarrierTraffic: Date?
    private var lastCredit: Date?
    private var running = false

    /// The second stream stops this long after the last carrier traffic.
    static let idleStop: TimeInterval = 120
    /// A tunnel the main stream showed is taken as shown for this long.
    static let visibleFor: TimeInterval = 300

    public init(stream: NettopStream = NettopStream(interfaces: .all),
                isCarrier: @escaping (Int32, String) -> Bool = { pid, name in
                    TunnelCarrier.isCarrier(processName: name, path: AppIdentityResolver.executablePath(pid: pid))
                }) {
        self.stream = stream
        self.isCarrierProcess = isCarrier
        stream.onSample = { [weak self] sample in
            DispatchQueue.main.async { self?.record(sample) }
        }
    }

    public func setSampleInterval(_ seconds: Int) { stream.setSampleInterval(seconds) }

    public func stop() {
        if running { stream.stop() }
        running = false
        fresh = [:]
        carried = [:]
    }

    private func isCarrier(_ row: NettopRow) -> Bool {
        if let known = carrierCache[row.pid] { return known }
        let answer = isCarrierProcess(row.pid, row.processName)
        if carrierCache.count > 1024 { carrierCache = [:] }
        carrierCache[row.pid] = answer
        return answer
    }

    /// A sample of the second stream: kept until the next main sample.
    public func record(_ sample: [NettopRow]) {
        guard running else { return }
        let found = TunnelCredit.hidden(in: sample, visibleTunnels: Set(visibleTunnels.keys), isCarrier: isCarrier)
        Self.merge(found, into: &fresh)
    }

    public var isRunning: Bool { running }

    private static func merge(_ entries: [Int32: TunnelCredit.Hidden], into pool: inout [Int32: TunnelCredit.Hidden]) {
        for (pid, entry) in entries {
            pool[pid, default: TunnelCredit.Hidden(processName: entry.processName,
                                                   bytes: ByteCounts(bytesIn: 0, bytesOut: 0))].bytes += entry.bytes
        }
    }

    /// The main stream's sample, with what the second one saw credited.
    public func credit(_ sample: [NettopRow], now: Date = Date()) -> [NettopRow] {
        for row in sample { for interface in row.tunnels.keys { visibleTunnels[interface] = now } }
        visibleTunnels = visibleTunnels.filter { now.timeIntervalSince($0.value) < Self.visibleFor }

        let carriers = sample.filter { isCarrier($0) && ($0.internetBytesIn > 0 || $0.internetBytesOut > 0) }
        if !carriers.isEmpty {
            lastCarrierTraffic = now
            if !running { running = true; stream.start() }
        } else if running, let last = lastCarrierTraffic, now.timeIntervalSince(last) > Self.idleStop {
            stop()
        }

        var pool = carried
        Self.merge(fresh, into: &pool)
        let result = TunnelCredit.apply(to: sample, hidden: pool, isCarrier: isCarrier)
        // What wasn't credited waits one more sample, the two streams' samples
        // being a moment apart; never more than one sample's worth.
        carried = [:]
        for (pid, rest) in result.left {
            guard let recent = fresh[pid] else { continue }
            carried[pid] = TunnelCredit.Hidden(processName: rest.processName,
                                               bytes: ByteCounts(bytesIn: min(rest.bytes.bytesIn, recent.bytes.bytesIn),
                                                                 bytesOut: min(rest.bytes.bytesOut, recent.bytes.bytesOut)))
        }
        fresh = [:]
        if let carrier = result.carriers.first {
            lastCredit = now
            setActive(carrier)
        } else if let last = lastCredit, now.timeIntervalSince(last) > 60 {
            lastCredit = nil
            setActive(nil)
        }
        return result.rows
    }

    private func setActive(_ pid: Int32?) {
        guard activeCarrier != pid else { return }
        activeCarrier = pid
        onActiveCarrierChange?(pid)
    }
}
