import Foundation

// What the app and its content filter agree on (#128): who they are, how they
// reach each other, and what the filter reports. Pure Foundation, like
// HostsFile and LowDataMode, so the system extension links none of the app's
// frameworks and the two can't disagree about a name or a field.

public enum FilterIdentity {
    /// The system extension's bundle identifier, and its App ID's.
    public static let extensionIdentifier = "com.kevinabouhanna.NetworkMonitor.Filter"
    public static let teamIdentifier = "GRQKG7M8CL"
    /// The XPC service the filter listens on, before a build number is added.
    /// A Network Extension's Mach service must be named under one of its app
    /// groups, which on macOS are prefixed with the team.
    public static let machServiceName = "GRQKG7M8CL.com.kevinabouhanna.NetworkMonitor.Filter"
    public static let appGroup = "GRQKG7M8CL.com.kevinabouhanna.NetworkMonitor"

    /// Each build's own name (#142). With one name for every version, an
    /// update could find the outgoing filter still holding it, and the new
    /// one came up with no service at all until a restart.
    public static func machServiceName(build: String) -> String {
        build.isEmpty ? machServiceName : "\(machServiceName).\(build)"
    }

    /// The name a filter bundle's Info.plist declares, as `bundle.sh` stamps
    /// it: what the filter listens on, and what the app shipping it connects
    /// to.
    public static func machServiceName(inInfo info: [String: Any]?) -> String {
        ((info?["NetworkExtension"] as? [String: Any])?["NEMachServiceName"] as? String) ?? machServiceName
    }
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
    /// Set when it was blocked (#114): the rule's id, or "mode" when nothing
    /// was allowed. Optional, so reports from a filter before it still decode.
    public let blockedBy: String?
    /// For a blocked connection, the app it was for, by the key Connections
    /// uses. The process may be gone by the time the app reads this.
    public let appKey: String?

    public init(address: String, port: Int, hostname: String?, pid: Int32, time: Date,
                blockedBy: String? = nil, appKey: String? = nil) {
        self.address = address
        self.port = port
        self.hostname = hostname
        self.pid = pid
        self.time = time
        self.blockedBy = blockedBy
        self.appKey = appKey
    }

    /// The name this report gives its server, if it gives one. A DNS lookup's
    /// flow carries the name being looked up, which would name the resolver
    /// (1.1.1.1 read as *developer.apple.com*), so lookups name nothing (#196).
    public var serverName: String? {
        guard let hostname, !hostname.isEmpty, !Self.lookupPorts.contains(port) else { return nil }
        return hostname
    }

    /// DNS, and DNS over TLS.
    public static let lookupPorts: Set<Int> = [53, 853]

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

/// Ask Me (#129): the filter holds an app's first connections to a company
/// and asks the app whether they may go.
public struct FlowQuestion: Codable, Equatable, Identifiable {
    public let id: String
    /// The app, by the key Connections uses.
    public let appKey: String
    /// The company, by `Company.key`, its name, and whether it only hosts;
    /// nil when the address has no known owner.
    public let companyKey: String?
    public let companyName: String?
    public let companyIsHost: Bool
    public let hostname: String?
    public let address: String
    public let country: String?
    /// When it's allowed anyway, if nobody answers.
    public let deadline: Date
    /// The server's port (#199). Optional, so questions from a filter
    /// before it still decode.
    public let port: Int?

    public init(id: String, appKey: String, companyKey: String?, companyName: String?, companyIsHost: Bool,
                hostname: String?, address: String, country: String?, deadline: Date, port: Int? = nil) {
        self.id = id
        self.appKey = appKey
        self.companyKey = companyKey
        self.companyName = companyName
        self.companyIsHost = companyIsHost
        self.hostname = hostname
        self.address = address
        self.country = country
        self.deadline = deadline
        self.port = port
    }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public static func decode(_ data: Data) -> FlowQuestion? {
        try? JSONDecoder().decode(FlowQuestion.self, from: data)
    }
}

public enum FlowAnswer: String, Codable {
    /// These connections, and the same app and company for the next hour.
    case allowOnce
    /// Allowed for good: the app has made a rule, on its way.
    case allow
    case block
}

/// What the app offers the filter: somewhere to send what it saw, and to ask.
@objc public protocol FilterAppInterface {
    func flowsSeen(_ reports: Data)
    /// A `FlowQuestion`, as JSON.
    func ask(_ question: Data)
    /// Nobody answered in time, and the connections went ahead.
    func questionExpired(_ id: String)
}

/// What the filter offers the app. The first call opens the connection the
/// filter then reports over.
@objc public protocol FilterExtensionInterface {
    func register(_ reply: @escaping (String) -> Void)
    /// The rules, the mode and whether the Mac is on a hotspot (#114), as a
    /// `FirewallPolicy` in JSON. Sent on connecting and after every change.
    func applyPolicy(_ policy: Data)
    /// The answer to a `FlowQuestion`, as a `FlowAnswer`'s raw value.
    func answer(_ id: String, _ answer: String)
    /// A newer month of the country and owner tables (#121), as open files:
    /// the filter keeps its own copy, and uses it from then on.
    func applyGeoData(_ countries: FileHandle, _ owners: FileHandle, _ month: String)
    /// The ad, tracker and malware lists (#176), as open files, and the date
    /// they were built: the filter keeps its own copy, used from then on.
    func applyBlocklists(_ ads: FileHandle, _ malware: FileHandle, _ version: String)
}
