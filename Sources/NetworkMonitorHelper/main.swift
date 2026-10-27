import Foundation
import HostsFile
import LowDataMode

// NetworkMonitor privileged helper.
//
// The only part of this project that runs as root, and deliberately the
// smallest. It exists because the two most expensive things that can land on a
// hotspot — a 6–14 GB macOS update, and update downloads from apps that fetch
// them inside their own process — are both gated behind root-owned files.
//
// # Why a sudoers rule rather than an XPC daemon
//
// The textbook answer is `SMAppService.daemon` plus an `NSXPCListener`, with
// `SMAuthorizedClients` validating callers by team identifier. That last part
// is exactly what an ad-hoc signature cannot do: there is no team identifier to
// validate against. Without it, an XPC daemon is a Mach service any local
// process can talk to, wrapped in several hundred lines of protocol code that
// buys no security it can actually enforce.
//
// So the privilege grant is made explicit instead: a single file in
// /etc/sudoers.d naming this binary and the exact verbs below, with no
// arguments. The exposure is identical — a local process running as the
// installing user can invoke these verbs — but it is one auditable text file
// the user can read, and `visudo -c` verifies it before it is ever installed.
//
// # Why the vocabulary is fixed here and not passed in
//
// The hostnames blocked and the preference keys written are compiled into this
// binary. Nothing is taken from the command line. That is the actual security
// boundary: the app cannot ask this helper to block an arbitrary host or write
// an arbitrary key, because there is no way to express that request. Adding a
// verb means shipping a new root binary, which is the level of ceremony a
// change like that deserves.
//
// `constrain` keeps that rule. It puts the connection in Low Data Mode, and
// which interface that means is decided here, from the system's own routing
// order — the caller can ask for Low Data Mode but cannot say where. The only
// flags it can raise are `constrained` and `expensive`.
//
// Verbs: status | suppress | restore | constrain | unconstrain | self-heal | uninstall

// MARK: - Constants

let appBundlePath = "/Applications/NetworkMonitor.app"
let helperPath = "/Library/PrivilegedHelperTools/com.kevinabouhanna.NetworkMonitor.helper"
// No dot in the filename, deliberately. `sudo`'s `#includedir` skips any file
// in sudoers.d whose name contains a `.` or ends in `~`, so the obvious
// reverse-DNS name would have been parsed by nothing and silently granted
// nothing — the helper would then fail with a password prompt it can never
// answer, on a machine where everything looked installed.
let sudoersPath = "/etc/sudoers.d/networkmonitor"
let daemonPlistPath = "/Library/LaunchDaemons/com.kevinabouhanna.NetworkMonitor.helper.plist"
let daemonLabel = "com.kevinabouhanna.NetworkMonitor.helper"
let stateDirectory = "/Library/Application Support/NetworkMonitor"
let statePath = "\(stateDirectory)/system-suppression.json"

let hostsPath = "/etc/hosts"

/// Apple's own update settings, in the system preference domain.
///
/// `AutomaticDownload` is the one that matters: it is what fetches the multi-
/// gigabyte payload in the background. The others are included so that an
/// update cannot simply arrive by another route while the first is closed.
let softwareUpdateDomain = "com.apple.SoftwareUpdate"
let softwareUpdateKeys = [
    "AutomaticDownload",
    "AutomaticallyInstallMacOSUpdates",
    "AutomaticallyInstallAppUpdates",
    "ConfigDataInstall",
    "CriticalUpdateInstall",
]

/// Enterprise policies that switch an app's updater off at the source.
///
/// Both of these are the app's own supported administrative control, read
/// before its updater is even initialised, so no update traffic happens at all
/// — which is a great deal better than letting the check run and breaking the
/// download.
///
/// They live in `/Library/Managed Preferences` because that is the only place
/// each app looks. `defaults write <domain> …` into the user domain is read by
/// neither: Slack gates on `CFPreferencesAppValueIsForced`, which is true only
/// for a managed source, and Claude reads the two managed paths directly.
let managedPreferences: [(app: String, domain: String, key: String, value: Bool)] = [
    // Claude Desktop. Checked in `Vvt()` before `setFeedURL`/`checkForUpdates`,
    // so the updater never starts.
    (app: "Claude", domain: "com.anthropic.claudefordesktop",
     key: "disableAutoUpdates", value: true),
    // Slack. Feeds `getIsUpdateSupported()`, which returns false and stops the
    // updater running.
    (app: "Slack", domain: "com.tinyspeck.slackmacgap",
     key: "AutoUpdate", value: false),
]

/// Update endpoints blocked at the name-resolution level.
///
/// The last resort, used only where an app has no policy at all. Every entry
/// must carry update traffic **and nothing else** — an unchecked entry here is
/// how a metering feature breaks the apps it promised to leave working.
///
/// **Three candidates were removed after checking what else uses them, and that
/// check is the only reason this feature does not break things:**
///
/// - `update.code.visualstudio.com` is literally `updateUrl` in VS Code's
///   product.json, and is also where the Remote-SSH extension downloads the VS
///   Code server (`/commit:<hash>/server-darwin-arm64/stable`). Blocking it
///   breaks remote development. VS Code is covered by its own `update.mode`
///   setting instead, which needs no privileges.
/// - `api.anthropic.com` is Claude Desktop's update feed *and* the API it uses
///   for everything else — its feed URL is
///   `api.anthropic.com/api/desktop/darwin/universal/squirrel/update`. Blocking
///   it takes the app off the air. Claude is covered by managed preferences.
/// - `downloads.claude.ai` carries the update payload but also Claude Code and
///   claude-ssh downloads. With the policy above stopping the check, blocking
///   the payload host buys nothing and risks breaking a feature.
let updateHosts = [
    // Canva — `app-update.yml` names this as the electron-updater feed. Canva
    // exposes no policy and no user setting of any kind, so this is the only
    // lever it has. Verified update-only: normal use is canva.com.
    "desktop-release.canva.com",
    // Figma — its `DisableUpdater` preference is the primary lever, but that
    // write is deferred while Figma is running, and Figma is running most of
    // the time for the people who have it installed. This closes that window.
    // Verified update-only: interactive traffic is figma.com.
    "desktop.figma.com",
    // Google: the update check for GoogleUpdater, which has replaced Keystone
    // and updates Chrome. It reads neither Keystone's `checkInterval` nor, on a
    // Mac that isn't enrolled in MDM, its own `updatePolicies`
    // (`ManagedPreferencePolicyManager::HasActiveDevicePolicies`), so a host is
    // the only lever left (#92). Verified update-only: it is the update
    // protocol's endpoint, and Chrome's component updater is its only other
    // caller. The payloads come from shared download hosts
    // (`edgedl.me.gvt1.com`, `dl.google.com`), which stay open: with the check
    // blocked, nothing asks for one.
    "update.googleapis.com",
]

// MARK: - State

/// What was there before, so `restore` can put it back exactly.
///
/// Kept root-side and separate from the app's own `suppression.json`, because
/// this file has to survive the app being deleted — that is the case it exists
/// for.
struct SystemState: Codable {
    /// Key → prior value. A missing entry in `priorSoftwareUpdate` means the
    /// key was absent and must be removed again, not set to `true`.
    var priorSoftwareUpdate: [String: Bool] = [:]
    var absentSoftwareUpdateKeys: [String] = []
    var didModifyHosts = false
    /// Managed-preference files we wrote. `nil` contents means the file did not
    /// exist and must be deleted again rather than emptied — restoring an empty
    /// managed policy file is not the same as having none.
    var priorManagedFiles: [String: Data?] = [:]
    /// Directories created under /Library/Managed Preferences, removed on
    /// restore if still empty. A machine with no MDM has no such directory, and
    /// leaving one behind would be a leftover.
    var createdDirectories: [String] = []
    var appliedAt = Date()
}

// MARK: - Managed preferences

/// The console user, for the per-user managed path.
///
/// `SUDO_USER` when invoked through sudo, which is how `suppress` and `restore`
/// always arrive. The LaunchDaemon calls only `self-heal`, which does not need
/// it, but the owner of /dev/console is the correct fallback.
func consoleUser() -> String? {
    if let sudoUser = ProcessInfo.processInfo.environment["SUDO_USER"], !sudoUser.isEmpty {
        return sudoUser
    }
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: "/dev/console"),
          let owner = attributes[.ownerAccountName] as? String, owner != "root"
    else { return nil }
    return owner
}

/// Both paths each app consults: the host-wide file and the per-user one.
///
/// Written to both rather than guessing. `CFPreferencesAppValueIsForced` — the
/// gate Slack uses — resolves the per-user file first, and Claude reads both
/// directly, so covering both is what makes this work regardless.
func managedPreferencePaths(domain: String) -> [String] {
    var paths = ["/Library/Managed Preferences/\(domain).plist"]
    if let user = consoleUser() {
        paths.append("/Library/Managed Preferences/\(user)/\(domain).plist")
    }
    return paths
}

/// Writes each managed policy file, persisting the undo record **before** every
/// change rather than once at the end.
///
/// `save` is called after each prior value is recorded and before the file it
/// describes is touched. That ordering is the fix for a real hole: this function
/// used to accumulate priors in memory and rely on the caller saving once
/// afterwards, so a throw part-way — a full disk, an unwritable directory —
/// left policy files on disk while the on-disk state still said
/// `priorManagedFiles: {}`. `restore` reads that state, finds nothing to undo,
/// and Claude and Slack stay switched off permanently with no record of why.
///
/// Recording a path before writing it is safe in the other direction: restoring
/// a prior of `nil` removes a file, and removing a file that was never created
/// is a no-op.
func applyManagedPreferences(into state: inout SystemState,
                             save: (SystemState) throws -> Void) throws {
    let manager = FileManager.default
    for preference in managedPreferences {
        for path in managedPreferencePaths(domain: preference.domain) {
            let directory = (path as NSString).deletingLastPathComponent
            if !manager.fileExists(atPath: directory) {
                // Recorded before it exists, so a crash during creation still
                // leaves a directory to clean up rather than an orphan.
                state.createdDirectories.append(directory)
                try save(state)
                try manager.createDirectory(atPath: directory,
                                            withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o755])
            }

            // Record what was there first — including "nothing", which is the
            // usual case on a machine with no MDM. A real MDM-managed file must
            // come back byte for byte.
            state.priorManagedFiles[path] = manager.contents(atPath: path)
            try save(state)

            var plist = (try? PropertyListSerialization.propertyList(
                from: manager.contents(atPath: path) ?? Data(),
                format: nil) as? [String: Any]) ?? [:]
            plist[preference.key] = preference.value
            let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                          format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        }
    }
}

/// Removes only this helper's own contribution to a managed policy file.
///
/// A prior of `nil` means "there was no file here", and the obvious undo is to
/// delete it. That is wrong if an MDM profile has been installed in the meantime:
/// the file now carries somebody else's configuration too, and deleting it as
/// root would silently disable it. So the file goes only when what remains is
/// exactly what we put there.
func removeOurContribution(at path: String) {
    let manager = FileManager.default
    let domain = ((path as NSString).lastPathComponent as NSString)
        .deletingPathExtension
    guard let preference = managedPreferences.first(where: { $0.domain == domain }),
          let data = manager.contents(atPath: path),
          var plist = try? PropertyListSerialization.propertyList(
            from: data, format: nil) as? [String: Any]
    else {
        // Unreadable or not one of ours by name: leave it alone rather than guess.
        return
    }

    plist.removeValue(forKey: preference.key)
    if plist.isEmpty {
        try? manager.removeItem(atPath: path)
    } else if let rewritten = try? PropertyListSerialization.data(
        fromPropertyList: plist, format: .xml, options: 0) {
        try? rewritten.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

func restoreManagedPreferences(_ state: SystemState) {
    let manager = FileManager.default
    for (path, prior) in state.priorManagedFiles {
        // Confined to the one directory this helper ever writes policy into. The
        // state file is the input to a root-privileged write, so its paths are
        // validated rather than trusted — see `loadState`.
        guard path.hasPrefix("/Library/Managed Preferences/") else { continue }
        if let prior {
            try? prior.write(to: URL(fileURLWithPath: path), options: .atomic)
        } else {
            removeOurContribution(at: path)
        }
    }
    // Longest first, so a nested per-user directory is removed before its
    // parent. `removeItem` on a non-empty directory would delete somebody
    // else's policy, so emptiness is checked rather than forced.
    for directory in state.createdDirectories.sorted(by: { $0.count > $1.count }) {
        let entries = (try? manager.contentsOfDirectory(atPath: directory)) ?? ["keep"]
        if entries.isEmpty { try? manager.removeItem(atPath: directory) }
    }
}

/// `nil` means there is no state file. Throws when one exists but cannot be read.
///
/// The distinction is the whole point, and collapsing it was a silent-permanent-
/// suppression bug: a `try?` here made a truncated or hand-edited state file
/// indistinguishable from "nothing is suppressed". `restore` would then undo
/// nothing, and the next `suppress` would read the *already suppressed* values
/// and record them as the priors to return to — cementing the suppression as a
/// deliberate-looking act, with the real prior values gone.
///
/// Failing loudly instead means the app reports the tier as failed and the user
/// keeps a file that still holds the answer.
func loadState() throws -> SystemState? {
    try loadTrusted(SystemState.self, at: statePath)
}

/// Reads one of this helper's state files, refusing one that anybody but root
/// could have written. Shared by both state files, so the Low Data Mode record
/// gets exactly the provenance check the update-suppression one does.
func loadTrusted<T: Decodable>(_ type: T.Type, at path: String) throws -> T? {
    let manager = FileManager.default
    guard let data = manager.contents(atPath: path) else { return nil }

    // Everything below turns this file's contents into root-privileged writes and
    // deletes, so its provenance is checked rather than assumed. The only thing
    // that makes that safe today is `/Library/Application Support` not being
    // group-writable — true on a stock macOS, and not something to rely on
    // silently when third-party installers are known to loosen directories.
    let attributes = try manager.attributesOfItem(atPath: path)
    let owner = (attributes[.ownerAccountID] as? NSNumber)?.intValue
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.int16Value ?? 0
    guard owner == 0, permissions & 0o022 == 0 else {
        throw HelperError.untrustedState(path: path)
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
        return try decoder.decode(T.self, from: data)
    } catch {
        throw HelperError.unreadableState(path: path, underlying: error)
    }
}

enum HelperError: LocalizedError {
    case unreadableState(path: String, underlying: Error)
    case untrustedState(path: String)
    case busy(path: String)
    case noInterface
    case unreadableInterface(String)
    case flagsRefused(String)
    case couldNotRelease(String)

    var errorDescription: String? {
        switch self {
        case .untrustedState(let path):
            return """
                \(path) is not owned by root, or is group- or world-writable. \
                Refusing to act on it: this file drives privileged writes, so a \
                version anyone could edit is a way to make this helper modify \
                files it was never meant to touch.
                """
        case .busy(let path):
            return """
                another invocation is already running (lock: \(path)). Nothing \
                was changed; this one declined rather than interleaving two \
                read-modify-write passes over /etc/hosts.
                """
        case .unreadableState(let path, let underlying):
            return """
                \(path) exists but could not be read (\(underlying)). \
                Refusing to act: this file is the only record of what to restore, \
                and treating it as absent would make the current suppression \
                permanent. Move it aside only if you are certain nothing is \
                currently suppressed.
                """
        case .noInterface:
            return """
                no Wi-Fi, Ethernet or USB-tethered interface is carrying traffic, \
                so there is nothing to put in Low Data Mode.
                """
        case .unreadableInterface(let interface):
            return "could not read the flags on \(interface); nothing was changed."
        case .flagsRefused(let interface):
            return """
                \(interface) did not keep the constrained and expensive flags \
                after they were set. Anything raised on the way was lowered again.
                """
        case .couldNotRelease(let interface):
            return """
                could not lower the flags this helper raised on \(interface). \
                The record of them is kept so the next attempt still knows they \
                are ours; a restart clears them in any case.
                """
        }
    }
}

func saveState(_ state: SystemState) throws {
    try saveTrusted(state, to: statePath)
}

func saveTrusted<T: Encodable>(_ value: T, to path: String) throws {
    try FileManager.default.createDirectory(atPath: stateDirectory,
                                            withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o755])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    // Write-ahead, atomically, for the same reason the app's journal is: a
    // change made without a durable record of how to undo it is the failure
    // this whole design is built to avoid.
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
}

func clearState() {
    try? FileManager.default.removeItem(atPath: statePath)
}

// MARK: - Apple software update

func readSoftwareUpdate(_ key: String) -> Bool? {
    let value = CFPreferencesCopyValue(key as CFString,
                                       softwareUpdateDomain as CFString,
                                       kCFPreferencesAnyUser,
                                       kCFPreferencesCurrentHost)
    guard let number = value as? NSNumber else { return nil }
    return number.boolValue
}

func writeSoftwareUpdate(_ key: String, _ value: Bool?) {
    // `nil` removes the key, which is what restoring an absent value means.
    CFPreferencesSetValue(key as CFString,
                          value.map { $0 as CFBoolean },
                          softwareUpdateDomain as CFString,
                          kCFPreferencesAnyUser,
                          kCFPreferencesCurrentHost)
}

func synchronizeSoftwareUpdate() {
    CFPreferencesSynchronize(softwareUpdateDomain as CFString,
                             kCFPreferencesAnyUser,
                             kCFPreferencesCurrentHost)
}

// MARK: - /etc/hosts

/// Reads `/etc/hosts`, throwing rather than substituting an empty string.
///
/// That distinction is the whole point. `String(contentsOfFile:encoding:.utf8)`
/// throws on the first byte that is not valid UTF-8 — one Latin-1 character in a
/// comment, left by a third-party hosts manager or an editor on another machine,
/// is enough. A caller that read that failure as "the file is empty" would hand
/// `HostsFile.applying` an empty document and write back an `/etc/hosts`
/// containing nothing but our own block, erasing `localhost`, `broadcasthost`
/// and every entry the user has. There is no backup to recover from.
///
/// An unreadable `/etc/hosts` must abort the verb. Callers that only *report* on
/// the file may substitute a default locally, where it cannot reach a write.
func currentHosts() throws -> String {
    try String(contentsOfFile: hostsPath, encoding: .utf8)
}

func writeHosts(_ contents: String) throws {
    // /etc/hosts is load-bearing for the whole machine: a truncated write would
    // be a serious problem. Write a temporary file in the same directory and
    // rename it into place, so the swap is atomic.
    let temporary = "/etc/.hosts.networkmonitor.tmp"
    try contents.write(toFile: temporary, atomically: false, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0],
                                          ofItemAtPath: temporary)
    // `try`, not `try?`. This rename is the only step that actually changes the
    // file, so discarding its error meant reporting success without having
    // written anything — and on the `restore` path the caller would then go on to
    // clear the state file, leaving the block in `/etc/hosts` permanently with no
    // record that it was ever put there.
    _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: hostsPath),
                                              withItemAt: URL(fileURLWithPath: temporary))
    flushDNS()
}

func flushDNS() {
    // Without this, mDNSResponder serves the previous answer from cache and the
    // change appears not to have worked for a minute or two.
    run("/usr/bin/dscacheutil", ["-flushcache"])
    run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
}

// MARK: - Low Data Mode

/// Which interface flags this helper raised, and on which interface.
///
/// A file of its own rather than a field in `system-suppression.json`, because
/// its lifecycle is different: the app lets go of Low Data Mode on every network
/// change and on quit, while the update settings stay down for as long as the
/// connection is metered. Sharing one record would make releasing either one a
/// partial edit of the other's undo information.
let lowDataStatePath = "\(stateDirectory)/low-data-mode.json"
let ifconfigPath = "/sbin/ifconfig"
let systemConfigurationPreferencesPath =
    "/Library/Preferences/SystemConfiguration/preferences.plist"

/// The only two flags this helper touches. A closed set, so nothing in a state
/// file or on a command line can become an arbitrary `ifconfig` argument.
enum InterfaceFlag: String {
    case constrained, expensive
}

func interfaceFlags(_ interface: String) -> LowDataMode.Flags? {
    guard LowDataMode.isPhysicalInterface(interface),
          let output = capture(ifconfigPath, ["-v", interface])
    else { return nil }
    return LowDataMode.flags(fromIfconfig: output)
}

/// Chosen here rather than passed in, so the verbs keep taking no arguments:
/// the caller can ask for Low Data Mode, never say where.
func primaryInterface() -> String? {
    capture("/usr/sbin/scutil", ["--nwi"]).flatMap(LowDataMode.primaryInterface(fromNWI:))
}

@discardableResult
func setFlag(_ flag: InterfaceFlag, raised: Bool, on interface: String) -> Bool {
    guard LowDataMode.isPhysicalInterface(interface) else { return false }
    return run(ifconfigPath, [interface, raised ? flag.rawValue : "-\(flag.rawValue)"]) == 0
}

/// Whether the user has put this wired interface in Low Data Mode in System
/// Settings, in the location set currently in force.
///
/// Checked before lowering `constrained`, for one case: a USB tether unplugged
/// and plugged back in while held. The interface comes back as a new device,
/// `configd` raises the flag from the user's own setting, and the hold — which
/// still says the flag is ours — would otherwise take it down. Wi-Fi keeps its
/// equivalent per network in a file only `wifid` writes, so this protects wired
/// links only; for Wi-Fi the flag is released and the user's setting re-applies
/// on the next join.
func userConfiguredLowDataMode(_ interface: String) -> Bool {
    guard let data = FileManager.default.contents(atPath: systemConfigurationPreferencesPath),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any]
    else { return false }
    return LowDataMode.isConfigured(interface: interface, inPreferences: plist)
}

/// Lowers only what `hold` raised, and only where it is still up.
///
/// False when a flag that is ours could not be lowered. The caller must then
/// keep the state file: it is the only record that the flag is ours. An
/// interface that has gone away counts as released — its flags went with it.
func release(_ hold: LowDataMode.Hold) -> Bool {
    guard let current = interfaceFlags(hold.interface) else { return true }
    var released = true
    if hold.setConstrained, current.constrained,
       !userConfiguredLowDataMode(hold.interface) {
        released = setFlag(.constrained, raised: false, on: hold.interface) && released
    }
    if hold.setExpensive, current.expensive {
        released = setFlag(.expensive, raised: false, on: hold.interface) && released
    }
    return released
}

func clearLowDataState() {
    try? FileManager.default.removeItem(atPath: lowDataStatePath)
}

/// Puts the interface carrying traffic in Low Data Mode, or re-asserts it.
///
/// Called again while already holding, this is the re-assert: macOS lowers the
/// flags when a hotspot drops and rejoins, and a flag found down is raised again
/// and recorded as ours. A flag found up and not already recorded is somebody
/// else's — macOS's, on a recognised iPhone hotspot, or the user's own Low Data
/// Mode — and stays out of the record so that `unconstrain` never lowers it.
func constrain() throws {
    guard let interface = primaryInterface() else { throw HelperError.noInterface }

    var hold = try loadTrusted(LowDataMode.Hold.self, at: lowDataStatePath)
    // The default route has moved — Wi-Fi to a USB tether, say. A flag left on
    // the old link would quietly constrain it the next time it carries traffic.
    if let previous = hold, previous.interface != interface {
        guard release(previous) else { throw HelperError.couldNotRelease(previous.interface) }
        clearLowDataState()
        hold = nil
    }

    guard let current = interfaceFlags(interface) else {
        throw HelperError.unreadableInterface(interface)
    }
    var next = hold ?? LowDataMode.Hold(interface: interface,
                                        setConstrained: false, setExpensive: false)
    if !current.constrained { next.setConstrained = true }
    if !current.expensive { next.setExpensive = true }

    guard next.setConstrained || next.setExpensive else {
        // Both up already, neither by us. Nothing to hold and nothing to undo.
        clearLowDataState()
        print(LowDataMode.Report.nothing.line)
        return
    }

    // Recorded before either flag moves, so a crash in between leaves a record
    // whose release is a no-op rather than a raised flag nobody knows about.
    try saveTrusted(next, to: lowDataStatePath)

    var raised = true
    if !current.constrained {
        raised = setFlag(.constrained, raised: true, on: interface) && raised
    }
    if !current.expensive {
        raised = setFlag(.expensive, raised: true, on: interface) && raised
    }

    // Verified, not assumed: `ifconfig` exiting 0 says the request was accepted,
    // and the flags being up afterwards is what was actually asked for.
    guard raised, interfaceFlags(interface) == .both else {
        if release(next) { clearLowDataState() }
        throw HelperError.flagsRefused(interface)
    }
    print(LowDataMode.Report.holding(next).line)
}

/// Lowers whatever `constrain` raised. Idempotent: with nothing held it reports
/// so and succeeds.
func unconstrain() throws {
    guard let hold = try loadTrusted(LowDataMode.Hold.self, at: lowDataStatePath) else {
        print(LowDataMode.Report.nothing.line)
        return
    }
    guard release(hold) else { throw HelperError.couldNotRelease(hold.interface) }
    clearLowDataState()
    print(LowDataMode.Report.nothing.line)
}

// MARK: - Verbs

func suppress() throws {
    // Already applied. Re-recording would overwrite the prior values with our
    // own and make `restore` put the suppression back instead of undoing it.
    if try loadState() != nil {
        print("already suppressed")
        return
    }

    var state = SystemState()
    for key in softwareUpdateKeys {
        if let prior = readSoftwareUpdate(key) {
            state.priorSoftwareUpdate[key] = prior
        } else {
            state.absentSoftwareUpdateKeys.append(key)
        }
    }
    state.didModifyHosts = true

    // Written before anything changes. The managed-preference pass appends its
    // own prior values to `state`, so the file is saved again immediately
    // afterwards — the window in between touches nothing.
    try saveState(state)

    for key in softwareUpdateKeys { writeSoftwareUpdate(key, false) }
    synchronizeSoftwareUpdate()

    try applyManagedPreferences(into: &state, save: saveState)

    try writeHosts(HostsFile.applying(updateHosts, to: try currentHosts()))

    print("suppressed")
}

func restore() throws {
    guard let state = try loadState() else {
        // Nothing recorded. Still strip any stray hosts block, because a
        // crash between writing /etc/hosts and writing state would leave one.
        // One read, not two: re-reading between the comparison and the write
        // invites the file changing underneath us.
        let hosts = try currentHosts()
        let stripped = HostsFile.withoutBlock(hosts)
        if stripped != hosts { try writeHosts(stripped) }
        print("nothing to restore")
        return
    }

    for (key, prior) in state.priorSoftwareUpdate { writeSoftwareUpdate(key, prior) }
    for key in state.absentSoftwareUpdateKeys { writeSoftwareUpdate(key, nil) }
    synchronizeSoftwareUpdate()

    restoreManagedPreferences(state)

    if state.didModifyHosts {
        try writeHosts(HostsFile.withoutBlock(try currentHosts()))
    }

    clearState()
    print("restored")
}

/// Prints machine-readable state for the app to read.
func status() {
    var state: SystemState?
    var stateUnreadable = false
    do { state = try loadState() } catch { stateUnreadable = true }
    // Read-only path: this verb reports and never writes, so falling back to an
    // empty string here cannot destroy anything the way it could in `suppress`.
    let hostsBlocked = HostsFile.containsBlock((try? currentHosts()) ?? "")
    let lowDataReport: String
    do {
        let hold = try loadTrusted(LowDataMode.Hold.self, at: lowDataStatePath)
        lowDataReport = (hold.map(LowDataMode.Report.holding) ?? .nothing).line
    } catch {
        lowDataReport = "unreadable"
    }
    let payload: [String: Any] = [
        "suppressed": state != nil,
        // Surfaced so the app can tell "nothing suppressed" apart from "the
        // record is damaged", which look identical from the outside.
        "stateUnreadable": stateUnreadable,
        "hostsBlocked": hostsBlocked,
        "blockedHosts": hostsBlocked ? updateHosts : [],
        "managedPreferences": managedPreferences.map { pref in
            managedPreferencePaths(domain: pref.domain)
                .filter { FileManager.default.fileExists(atPath: $0) }
                .map { "\(pref.app): \($0)" }
        }.flatMap { $0 },
        "softwareUpdate": softwareUpdateKeys.reduce(into: [String: Any]()) {
            $0[$1] = readSoftwareUpdate($1) ?? "absent"
        },
        "appPresent": FileManager.default.fileExists(atPath: appBundlePath),
        // What this binary understands. The app reads it to tell a helper built
        // before Low Data Mode existed — whose sudoers rule cannot grant the new
        // verbs either — from one that is merely idle, and to say "reinstall the
        // helper" rather than reporting a failure it cannot explain.
        "verbs": verbs,
        "version": HelperProtocol.version,
        "lowDataMode": lowDataReport,
        "primaryInterface": primaryInterface() ?? "",
    ]
    if let data = try? JSONSerialization.data(withJSONObject: payload,
                                              options: [.prettyPrinted, .sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

/// Undoes everything and removes the helper, the sudoers rule and the daemon.
func uninstallSelf() throws {
    try restore()
    // Both must succeed before anything is deleted, for the reason `restore`
    // must: the state file and this binary are what can still undo it.
    try unconstrain()
    for path in [sudoersPath, daemonPlistPath] {
        try? FileManager.default.removeItem(atPath: path)
    }
    // Booting out the daemon that is running this code is fine: launchd tears
    // it down after the process exits.
    run("/bin/launchctl", ["bootout", "system/\(daemonLabel)"])
    try? FileManager.default.removeItem(atPath: helperPath)
    // `restore` and `unconstrain` have already deleted the state files, so
    // what is left is the lock this process holds, and the folder. The
    // drag-to-Trash path ends here, with no `helper-setup.sh` to tidy up after
    // it (#28). Unlinking a held lock is safe: the lock lives on the open file
    // until this process exits, and with the sudoers rule and binary gone no
    // other verb can start. `rmdir` only removes the folder if it is empty.
    try? FileManager.default.removeItem(atPath: lockPath)
    rmdir(stateDirectory)
    print("uninstalled")
}

/// The drag-to-Trash safety net.
///
/// Most people uninstall a Mac app by dragging it to the Trash, and no script
/// runs when they do. This is invoked at boot and hourly by the LaunchDaemon: if
/// the application is gone, everything it asked for is undone and this helper
/// removes itself. A helper that outlives its app has exactly one job — undo its
/// own work and leave.
func selfHeal() throws {
    if FileManager.default.fileExists(atPath: appBundlePath) { return }
    try uninstallSelf()
}

// MARK: - Utilities

@discardableResult
func run(_ path: String, _ arguments: [String]) -> Int32 {
    guard FileManager.default.isExecutableFile(atPath: path) else { return -1 }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = arguments
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { return -1 }
    task.waitUntilExit()
    return task.terminationStatus
}

/// As `run`, keeping stdout. Nil unless the tool exited 0, so a failed read is
/// never parsed as if it were an answer.
func capture(_ path: String, _ arguments: [String]) -> String? {
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

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("networkmonitor-helper: \(message)\n".utf8))
    exit(1)
}

// MARK: - Mutual exclusion

let lockPath = "\(stateDirectory)/.helper.lock"

/// Serialises verbs against each other.
///
/// Every verb is a read-modify-write over `/etc/hosts` and the state file, and
/// two of them can genuinely overlap: the app calls `restore` on a network change
/// while the hourly `self-heal` is running. The losing order leaves a block in
/// `/etc/hosts` with no state file left to say it is there.
///
/// **Non-blocking on purpose.** `PrivilegedSuppressor` waits on this process from
/// the main thread, so a blocking `flock` behind a wedged holder would freeze the
/// menu bar. Declining immediately costs nothing: the app reports the tier as
/// failed and re-asserts on its next evaluation.
func acquireLock() throws -> Int32 {
    try? FileManager.default.createDirectory(
        atPath: stateDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755])
    let descriptor = open(lockPath, O_CREAT | O_RDWR, 0o600)
    guard descriptor >= 0 else { throw HelperError.busy(path: lockPath) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        close(descriptor)
        throw HelperError.busy(path: lockPath)
    }
    return descriptor
}

// MARK: - Entry point

// Everything below needs root. Refusing early gives a clear message instead of
// a confusing permission error three calls deep.
guard getuid() == 0 else { fail("must run as root") }

let verbs = ["status", "suppress", "restore", "constrain", "unconstrain",
             "self-heal", "uninstall"]
let verb = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "status"

do {
    // Held for the life of the process; the kernel releases it on exit, including
    // on a crash, so there is no stale-lock case to clean up.
    let lock = try acquireLock()
    defer { close(lock) }

    switch verb {
    case "status":      status()
    case "suppress":    try suppress()
    case "restore":     try restore()
    case "constrain":   try constrain()
    case "unconstrain": try unconstrain()
    case "self-heal":   try selfHeal()
    case "uninstall":   try uninstallSelf()
    default:            fail("unknown verb '\(verb)' — expected \(verbs.joined(separator: "|"))")
    }
} catch {
    fail("\(verb) failed: \(error.localizedDescription)")
}
