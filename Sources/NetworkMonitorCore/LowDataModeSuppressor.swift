import Foundation
import LowDataMode

/// Puts a metered connection in Low Data Mode for as long as it is metered.
///
/// The one lever in this feature that does not depend on knowing the app.
/// Every other suppressor switches off a named updater; this one tells macOS the
/// connection is costly and lets everything that listens act on it — iCloud and
/// Photos sync, discretionary background `URLSession` work, and any app that
/// sets `allowsConstrainedNetworkAccess` or `allowsExpensiveNetworkAccess` to
/// false. It reaches apps NetworkMonitor has never heard of, which is the gap a
/// list of updaters can never close on its own.
///
/// What it cannot do is make an app listen. Chromium's network stack, and so
/// most Electron apps, ignores both flags. `UpdaterScan` names those apps rather
/// than letting this switch imply it covers them.
///
/// It goes beyond "updates only", the line the rest of the feature holds: iCloud
/// Photos stops syncing too. It is still part of the one switch — it serves the
/// same purpose, and a second switch would ask the same question twice — so
/// Settings says so under that switch in a line of its own. It is released on
/// every network change and on quit — see `MeteringController.stop`.
///
/// Root-only, through the helper's `constrain` and `unconstrain`. What is held,
/// and how to undo it, lives in the helper's own record; this side keeps only a
/// journal entry saying something is held, exactly as `PrivilegedSuppressor`
/// does for the system update settings.
public final class LowDataModeSuppressor: UpdateSuppressor {

    public let name = "Low Data Mode"
    /// Its key in the same opt-out set as the per-app switches. Settings offers
    /// no switch for it — the feature's own switch covers it — but the policy
    /// asks every suppressor the same way, and the journal's names use it.
    public static let itemID = "privileged/low-data-mode"

    public enum Availability: Equatable {
        case available
        /// No helper at all.
        case helperMissing
        /// A helper installed before Low Data Mode existed. Its binary lacks the
        /// verbs and its sudoers rule cannot grant them, so only reinstalling
        /// the helper fixes it — said in those words, not reported as a failure.
        case helperOutdated
    }

    /// What is in force right now, for Settings.
    public enum State: Equatable {
        case off
        /// Held on this interface, and its flags read back as raised.
        case on(interface: String)
        /// The connection was in Low Data Mode before we arrived — the user's own
        /// setting, or macOS's. Nothing of ours to hold, and nothing to undo.
        case alreadyOn
        case failed(String)
    }

    public private(set) var state: State = .off

    /// How many re-asserts are allowed inside `reassertWindow` before giving up
    /// on this connection until the next network change.
    ///
    /// A hotspot that drops and rejoins makes macOS lower the flags, and putting
    /// them back is the point. A system that lowers them the moment they go up is
    /// a different thing, and answering it in a loop would be a root call every
    /// couple of seconds for as long as it lasted.
    public static let reassertLimit = 3
    public static let reassertWindow: TimeInterval = 300

    private let ownership: InterfaceFlagOwnership
    private let invoke: (String) -> String?
    private let isHelperInstalled: () -> Bool
    private let primaryInterface: () -> String?
    private let readFlags: (String) -> LowDataMode.Flags?
    private let now: () -> Date

    private var cachedAvailability: Availability?
    private var recentAsserts: [Date] = []
    /// False until the helper has said what it holds this session.
    ///
    /// A previous run that crashed while holding leaves flags up that this run
    /// has no memory of, and until they are known about they cannot be masked.
    /// So the first `revert` — at launch, from `MeteringController.start` — asks
    /// the helper even with an empty journal.
    private var knowsHelperState = false

    public convenience init() {
        self.init(ownership: .shared,
                  invoke: PrivilegedSuppressor.invoke,
                  isHelperInstalled: { PrivilegedSuppressor.isInstalled },
                  primaryInterface: InterfaceProbe.primaryInterface,
                  readFlags: InterfaceProbe.flags(on:),
                  now: Date.init)
    }

    /// Every outside effect injected, so the policy is testable without root.
    public init(ownership: InterfaceFlagOwnership,
                invoke: @escaping (String) -> String?,
                isHelperInstalled: @escaping () -> Bool,
                primaryInterface: @escaping () -> String?,
                readFlags: @escaping (String) -> LowDataMode.Flags?,
                now: @escaping () -> Date) {
        self.ownership = ownership
        self.invoke = invoke
        self.isHelperInstalled = isHelperInstalled
        self.primaryInterface = primaryInterface
        self.readFlags = readFlags
        self.now = now
    }

    // MARK: Availability

    /// Cached after the first answer: `apply` runs on every network change and
    /// should not cost a `status` call each time. `refreshAvailability()` is for
    /// when the world may have changed — Settings opening after a reinstall.
    public var availability: Availability {
        cachedAvailability ?? refreshAvailability()
    }

    @discardableResult
    public func refreshAvailability() -> Availability {
        refreshAvailability(status: isHelperInstalled() ? invoke("status") : nil)
    }

    /// The same, from the helper's `status` answer already in hand, so one call
    /// serves this and `HelperInstaller.state(status:)` (#65). `nil` is no answer.
    @discardableResult
    public func refreshAvailability(status output: String?) -> Availability {
        guard isHelperInstalled() else {
            cachedAvailability = .helperMissing
            return .helperMissing
        }
        guard let output,
              let data = output.data(using: .utf8),
              let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Not an answer either way — the helper declines while another verb
            // holds its lock. Not cached, and optimistic: if it really cannot do
            // this, the `constrain` that follows fails and says so.
            return .available
        }
        guard let verbs = status["verbs"] as? [String], verbs.contains("constrain") else {
            cachedAvailability = .helperOutdated
            return .helperOutdated
        }
        if let line = status["lowDataMode"] as? String,
           let report = LowDataMode.Report(output: line) {
            adopt(report)
        }
        cachedAvailability = .available
        return .available
    }

    // MARK: UpdateSuppressor

    /// Empty unless the helper can do this. Low Data Mode is not an app and has
    /// no row in the app list, so this exists for the journal's names and for
    /// anyone asking what is reachable.
    public func discover() -> [CoveredItem] {
        guard availability == .available else { return [] }
        return [CoveredItem(id: Self.itemID,
                            displayName: name,
                            mechanism: "System setting",
                            effect: "Holds back iCloud and other background downloads")]
    }

    @discardableResult
    public func apply(journal: SuppressionJournal,
                      excluding: Set<String> = []) -> SuppressionResult {
        var result = SuppressionResult()
        guard !excluding.contains(Self.itemID), availability == .available else {
            return result
        }

        let primary = primaryInterface()

        // Held, still raised, still the link carrying traffic: nothing to do.
        // Read as the user, from `ifconfig`, so the common case — every network
        // event on a hotspot that is already held — costs no root call at all.
        if let hold = ownership.hold, let primary, hold.interface == primary,
           readFlags(primary) == .both {
            state = .on(interface: primary)
            return result
        }

        // Held on this same link, but the flags are down: macOS lowered them.
        // Re-asserted, within a budget — see `reassertLimit`.
        let current = now()
        recentAsserts.removeAll { current.timeIntervalSince($0) > Self.reassertWindow }
        if let hold = ownership.hold, hold.interface == primary,
           recentAsserts.count >= Self.reassertLimit {
            state = .failed("macOS keeps turning Low Data Mode off on this connection")
            return result
        }

        if journal.record(for: .lowDataMode) == nil {
            do {
                try journal.record(SuppressionRecord(target: .lowDataMode,
                                                     priorValue: .absent,
                                                     appliedValue: .string("held")))
            } catch {
                // No durable record, no guaranteed undo, so nothing is changed.
                state = .failed("Couldn't record the change, so nothing was changed")
                return result
            }
        }

        recentAsserts.append(current)
        guard let output = invoke("constrain"),
              let report = LowDataMode.Report(output: output)
        else {
            // The helper lowers whatever it raised before failing, but whether it
            // was already holding something from an earlier call is now unknown.
            // Asking is one call, and it keeps the masking honest.
            resync()
            if ownership.hold == nil { journal.clear(.lowDataMode) }
            state = .failed("The helper couldn't turn Low Data Mode on")
            return result
        }

        adopt(report)
        switch report {
        case .nothing:
            journal.clear(.lowDataMode)
            state = .alreadyOn
        case .holding(let hold):
            // Checked again from this side, with the same parser the helper used.
            // Agreement is the point: if the two ever disagreed, the user would
            // otherwise be told it is on when it is not.
            state = readFlags(hold.interface) == .both
                ? .on(interface: hold.interface)
                : .failed("Low Data Mode didn't stay on for \(hold.interface)")
        }
        result.applied.append(name)
        return result
    }

    public func revert(journal: SuppressionJournal) {
        let recorded = journal.record(for: .lowDataMode) != nil
        guard recorded || ownership.hold != nil || !knowsHelperState else { return }
        guard isHelperInstalled(), availability != .helperOutdated else {
            // No helper left that could lower them — a restart will, and a hold
            // nobody can release would only keep masking a flag forever — or a
            // helper too old ever to have raised them.
            forget(journal)
            return
        }

        // At launch, `availability` has just asked `status`, which says what is
        // held. Nothing held and nothing recorded: nothing to lower, and no
        // reason to spend a root call finding that out twice.
        if !recorded, ownership.hold == nil, knowsHelperState {
            state = .off
            return
        }

        if let output = invoke("unconstrain"),
           LowDataMode.Report(output: output) == .nothing {
            forget(journal)
            return
        }

        // Not confirmed down. Possibly a helper from before this verb existed,
        // which therefore cannot be holding anything — `status` says which.
        resync()
        if ownership.hold == nil {
            forget(journal)
        } else {
            // Kept, and the masking with it: until the helper confirms the flags
            // are down they are still ours, and the heuristic must keep not
            // counting them. `MeteringController.evaluate` retries.
            state = .failed("Couldn't turn Low Data Mode off yet — it will be retried")
        }
    }

    /// Something is still held: the controller must keep trying to release it
    /// even once its journal is empty.
    public var holdsUnreleasedState: Bool { ownership.hold != nil }

    // MARK: Helpers

    private func adopt(_ report: LowDataMode.Report) {
        knowsHelperState = true
        switch report {
        case .holding(let hold): ownership.hold = hold
        case .nothing:           ownership.hold = nil
        }
    }

    private func resync() {
        guard let output = invoke("status"),
              let data = output.data(using: .utf8),
              let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if let line = status["lowDataMode"] as? String,
           let report = LowDataMode.Report(output: line) {
            adopt(report)
        } else if status["verbs"] == nil {
            // A helper without the verb holds nothing of this kind.
            adopt(.nothing)
        }
    }

    private func forget(_ journal: SuppressionJournal) {
        adopt(.nothing)
        journal.clear(.lowDataMode)
        recentAsserts.removeAll()
        state = .off
    }
}

/// The interface flags this app raised itself, readable from any thread.
///
/// The heuristic counts `NWPath.isConstrained` as evidence that a connection
/// costs money (rank 6), and `isExpensive` as stronger evidence still (rank 2).
/// Once Low Data Mode is held both flags are ours, and reading them back as
/// evidence would be circular. Leave a hotspot for home Wi-Fi on the same `en0`
/// and home would be judged metered by the flags raised for the hotspot — which
/// keeps them raised, which keeps home metered, for good. So every reader of
/// those two signals goes through `masking(_:on:)` first.
///
/// Locked rather than main-thread-only because `NetworkIdentityWatcher` builds
/// fingerprints on its own queue.
public final class InterfaceFlagOwnership {

    public static let shared = InterfaceFlagOwnership()

    private let lock = NSLock()
    private var current: LowDataMode.Hold?

    public init() {}

    public var hold: LowDataMode.Hold? {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }

    /// `signals` with the flags we raised on `interface` taken back out.
    ///
    /// An interface the path monitor could not name is masked too. Failing to
    /// mask is the direction that loops; masking a flag that turns out to be
    /// somebody else's costs one evaluation's worth of being wrong.
    public func masking(_ signals: MeteredHeuristic.Signals,
                        on interface: String?) -> MeteredHeuristic.Signals {
        guard let hold, interface == nil || interface == hold.interface else {
            return signals
        }
        var masked = signals
        if hold.setConstrained { masked.isConstrained = false }
        if hold.setExpensive { masked.isExpensive = false }
        return masked
    }
}

/// The unprivileged half of Low Data Mode: the two tools the helper uses, run as
/// the user. Both read without root, which is what lets the app check the
/// helper's work rather than take its word for it.
public enum InterfaceProbe {

    public static func primaryInterface() -> String? {
        run("/usr/sbin/scutil", ["--nwi"]).flatMap(LowDataMode.primaryInterface(fromNWI:))
    }

    public static func flags(on interface: String) -> LowDataMode.Flags? {
        guard LowDataMode.isPhysicalInterface(interface) else { return nil }
        return run("/sbin/ifconfig", ["-v", interface]).flatMap(LowDataMode.flags(fromIfconfig:))
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
        guard task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
