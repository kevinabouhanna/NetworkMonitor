import Foundation

// What the app and its content filter agree on (#128): who they are, how they
// reach each other, and what the filter reports. Pure Foundation, like
// HostsFile and LowDataMode, so the system extension links none of the app's
// frameworks and the two can't disagree about a name or a field.

public enum FilterIdentity {
    /// The system extension's bundle identifier, and its App ID's.
    public static let extensionIdentifier = "com.kevinabouhanna.NetworkMonitor.Filter"
    public static let teamIdentifier = "GRQKG7M8CL"
    /// The XPC service the filter listens on. A Network Extension's Mach
    /// service must be named under one of its app groups, which on macOS are
    /// prefixed with the team.
    public static let machServiceName = "GRQKG7M8CL.com.kevinabouhanna.NetworkMonitor.Filter"
    /// Only NetworkMonitor itself, signed with its Developer ID, may connect:
    /// the filter sees every server the Mac talks to, and says so to nobody else.
    public static let appRequirement = """
        anchor apple generic and identifier "com.kevinabouhanna.NetworkMonitor" \
        and certificate leaf[subject.OU] = "GRQKG7M8CL"
        """
    /// And the app only talks to the filter it shipped.
    public static let extensionRequirement = """
        anchor apple generic and identifier "com.kevinabouhanna.NetworkMonitor.Filter" \
        and certificate leaf[subject.OU] = "GRQKG7M8CL"
        """
}

/// One new connection, as the filter saw it open.
public struct FlowReport: Codable, Equatable {
    /// The server's address, as `nettop` would print it.
    public let address: String
    public let port: Int
    /// The name the app connected by, such as `api.slack.com`. Nil when it
    /// connected to a bare address.
    public let hostname: String?
    /// The process that opened it, from the flow's audit token.
    public let pid: Int32
    public let time: Date

    public init(address: String, port: Int, hostname: String?, pid: Int32, time: Date) {
        self.address = address
        self.port = port
        self.hostname = hostname
        self.pid = pid
        self.time = time
    }

    /// Reports travel as JSON in a `Data`, which XPC carries without a
    /// secure-coding class for each field.
    public static func encode(_ reports: [FlowReport]) -> Data {
        (try? JSONEncoder().encode(reports)) ?? Data()
    }

    public static func decode(_ data: Data) -> [FlowReport] {
        (try? JSONDecoder().decode([FlowReport].self, from: data)) ?? []
    }

    /// The process ID in a flow's audit token: the sixth of its eight words,
    /// as `audit_token_to_pid` reads it. Zero for a token too short to be one.
    public static func pid(fromAuditToken token: Data?) -> Int32 {
        guard let token, token.count >= 8 * MemoryLayout<UInt32>.size else { return 0 }
        return token.withUnsafeBytes { Int32(bitPattern: $0.loadUnaligned(fromByteOffset: 5 * 4, as: UInt32.self)) }
    }
}

/// What the app offers the filter: somewhere to send what it saw.
@objc public protocol FilterAppInterface {
    func flowsSeen(_ reports: Data)
}

/// What the filter offers the app. The first call opens the connection the
/// filter then reports over.
@objc public protocol FilterExtensionInterface {
    func register(_ reply: @escaping (String) -> Void)
    /// The rules, the mode and whether the Mac is on a hotspot (#114), as a
    /// `FirewallPolicy` in JSON. Sent on connecting and after every change.
    func applyPolicy(_ policy: Data)
}
