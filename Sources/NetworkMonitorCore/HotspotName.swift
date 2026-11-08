import Foundation
import SystemConfiguration

/// The name of the iPhone or iPad sharing its connection, such as "Kevin's
/// iPhone" (#369).
///
/// CoreWLAN gives no Wi-Fi name for a Personal Hotspot joined from the Wi-Fi
/// menu, even with Location allowed, and configd's `SSID_STR` is empty for it.
/// What configd does keep, in the interface's AirPort state and readable by
/// any process, is `LastTetherDevice`: an archived `CWTetherDevice` whose
/// `_deviceName` is the name the Wi-Fi menu shows under Personal Hotspot.
///
/// It is the *last* device, so it's only read for a link whose router is in
/// iOS Personal Hotspot's range, and checked against the name the phone's
/// own DHCP server gives (`sname`, "Kevins-iPhone") so a second iPhone joined
/// another way isn't called by the first one's name.
public enum HotspotName {

    /// The live version, for `interface`'s link with its router at `router`.
    public static func name(onInterface interface: String, router: String?) -> String? {
        guard let router, let address = IPv4Address(router),
              MeteredHeuristic.iOSHotspotRange.contains(address),
              let store = SCDynamicStoreCreate(nil, "NetworkMonitor" as CFString, nil, nil),
              let airport = SCDynamicStoreCopyValue(
                store, "State:/Network/Interface/\(interface)/AirPort" as CFString) as? [String: Any],
              let name = deviceName(inAirPortState: airport)
        else { return nil }
        let server = run("/usr/sbin/ipconfig", ["getpacket", interface]).flatMap(serverName(inPacket:))
        return matches(name, serverName: server) ? name : nil
    }

    /// `_deviceName` from the archived `CWTetherDevice` in an interface's
    /// AirPort state.
    public static func deviceName(inAirPortState state: [String: Any]) -> String? {
        guard let data = state["LastTetherDevice"] as? Data,
              let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data)
        else { return nil }
        // Decoded into a class of its own, which reads only the name, so
        // nothing depends on CoreWLAN's private one.
        unarchiver.setClass(ArchivedTetherDevice.self, forClassName: "CWTetherDevice")
        let device = unarchiver.decodeObject(of: ArchivedTetherDevice.self,
                                             forKey: NSKeyedArchiveRootObjectKey)
        unarchiver.finishDecoding()
        guard let name = device?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }

    /// The `sname` of a DHCP packet, as `ipconfig getpacket` prints it:
    /// `sname = Kevins-iPhone`.
    public static func serverName(inPacket output: String) -> String? {
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "sname" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Whether a device name and the host name its phone hands out could be
    /// the same phone. iOS makes the host name from the device name, dropping
    /// what a host name can't hold: "Kevin's iPhone" → "Kevins-iPhone". A name
    /// with nothing to compare (no `sname`, or no Latin letters in it) passes.
    public static func matches(_ deviceName: String, serverName: String?) -> Bool {
        func letters(_ text: String) -> String {
            String(text.lowercased().unicodeScalars.filter {
                $0.isASCII && CharacterSet.alphanumerics.contains($0)
            }.map(Character.init))
        }
        guard let serverName else { return true }
        let device = letters(deviceName), server = letters(serverName)
        guard !device.isEmpty, !server.isEmpty else { return true }
        return device == server
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

/// Stands in for CoreWLAN's `CWTetherDevice` when decoding one, and archives
/// one for tests under that class name.
@objc(NMArchivedTetherDevice)
public final class ArchivedTetherDevice: NSObject, NSSecureCoding {
    public static var supportsSecureCoding: Bool { true }
    public let name: String?

    public init(name: String?) {
        self.name = name
    }

    public init?(coder: NSCoder) {
        name = coder.decodeObject(of: NSString.self, forKey: "_deviceName") as String?
    }

    public func encode(with coder: NSCoder) {
        coder.encode(name, forKey: "_deviceName")
    }
}
