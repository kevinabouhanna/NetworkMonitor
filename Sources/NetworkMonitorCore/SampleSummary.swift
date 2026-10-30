import Foundation

/// One nettop sample, folded into what the rest of the app records: each app's
/// internet bytes, the servers it talked to, the LAN bytes the total sheds,
/// and the processes seen (#110).
///
/// Pure, given how a row's process is named, so it's tested without nettop or
/// `NSWorkspace`. It used to live inline in `MonitorViewModel`, the one piece
/// of decision-making there that no test reached.
public struct SampleSummary {

    /// One entry per app: several helper pids fold into one identity, and the
    /// store expects each app once.
    public private(set) var apps: [(identity: AppIdentity, bytesIn: Int64, bytesOut: Int64)] = []
    /// Each app's internet bytes by server address, for Connections (#115).
    public private(set) var servers: [String: [String: ByteCounts]] = [:]
    /// The unicast LAN bytes, which never become an app row but come off the
    /// kernel's total. Multicast is kept out of the rows and left in the total,
    /// since its reported size can't be trusted.
    public private(set) var localIn: Int64 = 0
    public private(set) var localOut: Int64 = 0
    /// Every process in the sample, quiet ones included, for pid-reuse cache
    /// eviction.
    public private(set) var pids = Set<Int32>()
    /// Rows from processes named like updaters, by their own name rather than
    /// the app they fold into: GoogleUpdater is an updater whether or not its
    /// row groups under Chrome, and the name is the only list-free sign.
    public private(set) var updaters: [(processName: String, appName: String, bytes: Int64)] = []

    public init(_ sample: [NettopRow], identify: (NettopRow) -> AppIdentity) {
        var merged: [String: Int] = [:]
        for row in sample {
            pids.insert(row.pid)
            localIn += row.subtractableLocalIn
            localOut += row.subtractableLocalOut
            // Only internet bytes reach a row. An app that did nothing but talk
            // to a NAS or mirror a screen doesn't appear at all.
            let bytesIn = row.internetBytesIn, bytesOut = row.internetBytesOut
            guard bytesIn > 0 || bytesOut > 0 else { continue }
            let identity = identify(row)
            if let index = merged[identity.key] {
                apps[index].bytesIn += bytesIn
                apps[index].bytesOut += bytesOut
            } else {
                merged[identity.key] = apps.count
                apps.append((identity, bytesIn, bytesOut))
            }
            for (address, bytes) in row.servers {
                servers[identity.key, default: [:]][address, default: ByteCounts(bytesIn: 0, bytesOut: 0)] += bytes
            }
            if UpdaterScan.looksLikeUpdater(row.processName) {
                updaters.append((row.processName, identity.displayName, bytesIn + bytesOut))
            }
        }
    }
}

extension AppIdentity {
    /// Where an update's traffic is looked for (#95, #94): the app's bundle,
    /// as Squirrel's ShipIt and Sparkle's downloader run inside the app they
    /// update; outside an app, its executable, and the app that adopted it,
    /// as Claude Code updates itself from the folder it runs from, inside a
    /// terminal.
    public var trafficPaths: [String] {
        if let bundlePath { return [bundlePath] }
        return [AppIdentityResolver.keyBeforeAdoption(key) ?? key] + [parent?.bundlePath].compactMap { $0 }
    }
}
