import Darwin
import Foundation

/// The app a WebKit networking process works for (#761).
///
/// Safari, Mail and any app with a web view each have a
/// `com.apple.WebKit.Networking` of macOS's own, started by launchd, so neither
/// its path nor its parents say whose it is. macOS does, to a call it keeps
/// private: it's only looked up, and without it the process is its own.
///
/// Shared by the app, which files bytes by it, and the content filter, which
/// matches rules by it, so a rule on a row covers what the row shows.
public enum WebKitOwner {

    private static let responsiblePID: (@convention(c) (Int32) -> Int32)? = {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (Int32) -> Int32).self)
    }()

    /// Whether a path is macOS's own WebKit networking process, as
    /// `proc_pidpath` says it: on the system volume or on a cryptex.
    public static func isNetworking(_ path: String) -> Bool {
        let system = path.hasPrefix("/System/Library/")
            || path.hasPrefix("/System/Cryptexes/") || path.hasPrefix("/System/Volumes/Preboot/Cryptexes/")
        return system && path.contains("/System/Library/Frameworks/WebKit.framework/")
            && path.hasSuffix("/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking")
    }

    /// The program a WebKit networking process works for. Asked each time, as
    /// it costs microseconds, and checked against pid reuse at both ends.
    public static func of(pid: Int32, path: String) -> (pid: Int32, path: String)? {
        guard isNetworking(path), let responsiblePID,
              let worker = ProcessInstance(pid: pid), executablePath(pid: pid) == path else { return nil }
        let ownerPID = responsiblePID(pid)
        guard ownerPID > 1, ownerPID != pid,
              let owner = ProcessInstance(pid: ownerPID), owner.canOwn(worker),
              let ownerPath = executablePath(pid: ownerPID),
              ProcessInstance(pid: ownerPID) == owner, ProcessInstance(pid: pid) == worker else { return nil }
        return (ownerPID, ownerPath)
    }

    private static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 2)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    public struct ProcessInstance: Equatable {
        public let uid: uid_t
        /// Since the Mac started, so setting the clock changes nothing.
        public let started: UInt64

        public init(uid: uid_t, started: UInt64) {
            self.uid = uid
            self.started = started
        }

        public init?(pid: Int32) {
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
            var usage = rusage_info_v0()
            let read = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V0, $0) }
            }
            guard read == 0 else { return nil }
            self.init(uid: info.pbsi_uid, started: usage.ri_proc_start_abstime)
        }

        /// One that started after the worker has only taken its owner's pid.
        public func canOwn(_ worker: ProcessInstance) -> Bool { uid == worker.uid && started <= worker.started }
    }
}
