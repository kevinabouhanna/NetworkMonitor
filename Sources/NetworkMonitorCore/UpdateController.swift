import Combine
import Foundation
import Sparkle

/// NetworkMonitor updating itself (#132), with Sparkle.
///
/// Once a day it asks for the newest release's appcast on GitHub; a newer
/// version is offered, downloaded and installed with the person's OK, and only
/// if its disk image carries a signature from the key whose public half is in
/// the app (`SUPublicEDKey`), as well as Apple's notarization.
///
/// An update the daily check finds while the main window is open waits on a
/// card at the foot of its sidebar (#520): Install & Restart, What's New, or
/// put it away until the next check. Found while the window is closed, or
/// asked for, Sparkle's own window offers it, as before.
///
/// With Install updates automatically on (#710), off by default, what the daily
/// check finds downloads in the background and installs once nothing would be
/// interrupted: no window or popover open, no speed test running. Until then
/// the card says it's ready. The choice is Sparkle's own, which its window's
/// tick box shows and changes too.
///
/// With Get beta versions on (#585), it reads the beta feed instead, which
/// holds the newest beta or release, whichever is newer, and allows the beta
/// channel a beta's item carries. Off, a beta is never offered, even one in
/// the usual feed by mistake.
///
/// Only in builds that carry a feed and that key, which `bundle.sh` adds to
/// Developer ID builds: a build from source isn't replaced by a release.
public final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate,
                                     SPUStandardUserDriverDelegate {

    /// Whether it checks on its own, once a day. On by default.
    @Published public var checksAutomatically: Bool = true {
        didSet {
            guard let updater, updater.automaticallyChecksForUpdates != checksAutomatically else { return }
            updater.automaticallyChecksForUpdates = checksAutomatically
        }
    }

    /// Whether a new version downloads and installs by itself (#710). Off by
    /// default. Kept by Sparkle, whose window's tick box changes it too; off
    /// while the daily check is off, which it needs.
    @Published public var installsAutomatically: Bool = false {
        didSet {
            guard let updater, updater.automaticallyDownloadsUpdates != installsAutomatically else { return }
            updater.automaticallyDownloadsUpdates = installsAutomatically
        }
    }

    /// When it last asked whether there's a newer version.
    @Published public private(set) var lastChecked: Date?

    /// The version downloaded and waiting to install by itself (#710).
    @Published public private(set) var readyVersion: String?
    /// Its card was put away with its ✕; it still installs.
    @Published private var readyCardHidden = false
    /// The version that installed by itself, until that's been seen.
    @Published public private(set) var updatedVersion: String?

    /// What the card at the foot of the main window's sidebar says.
    public enum Notice: Equatable {
        case available(String), ready(String), updated(String)
    }

    public var notice: Notice? {
        if let readyVersion { return readyCardHidden ? nil : .ready(readyVersion) }
        if let pendingVersion { return .available(pendingVersion) }
        return updatedVersion.map(Notice.updated)
    }

    /// Whether nothing would be interrupted by a restart: no window or popover
    /// open, no speed test running.
    public var canRestartQuietly: () -> Bool = { true }
    /// The section open in the main window, to come back to after a restart.
    public var sectionToReopen: () -> String? = { nil }
    /// Check for Updates… while one waits to install: where it says so.
    public var onShowReady: (() -> Void)?

    /// How often a waiting update looks again. Public for the tests.
    public var quietCheckInterval: TimeInterval = 60

    private var installNow: (() -> Void)?
    private var quietTimer: Timer?
    private var observers: Set<AnyCancellable> = []

    public static let reopenKey = "reopenAfterUpdate"
    public static let installedByItselfKey = "updateInstalledByItself"

    public var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// Whether betas are offered too (#585). Off by default; turned on, it
    /// looks at once, as the daily check would, if that's on.
    @Published public var getsBetas: Bool {
        didSet {
            guard getsBetas != oldValue else { return }
            defaults.set(getsBetas, forKey: Self.betasKey)
            if getsBetas, checksAutomatically { updater?.checkForUpdatesInBackground() }
        }
    }

    public static let betasKey = "updatesIncludeBetas"

    /// The standing `beta-updates` prerelease's appcast, which every release
    /// and every beta replaces (.github/workflows/release.yml).
    public static let betaFeedURL = "https://github.com/kevinabouhanna/NetworkMonitor/releases/download/beta-updates/appcast.xml"

    /// The feed to read: a launch argument's, then the beta feed with betas
    /// on, otherwise nil, the app's own (`SUFeedURL`).
    public static func feedURL(betas: Bool, launchArgument: String?) -> String? {
        launchArgument ?? (betas ? betaFeedURL : nil)
    }

    /// The channels allowed besides the default one.
    public static func channels(betas: Bool) -> Set<String> {
        betas ? ["beta"] : []
    }

    /// Whether Sparkle takes build `a` for newer than build `b`: how a beta's
    /// build sits between two releases' (Scripts/build-number.sh).
    public static func isNewer(build a: String, than b: String) -> Bool {
        SUStandardVersionComparator.default.compareVersion(b, toVersion: a) == .orderedAscending
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        getsBetas = defaults.bool(forKey: Self.betasKey)
        super.init()
    }

    /// The version waiting on the sidebar's card (#520), while there is one.
    @Published public private(set) var pendingVersion: String?

    /// Whether the main window is open, so a card there would be seen.
    public var cardCanBeSeen: () -> Bool = { false }

    /// Whether the connection is metered: the daily check waits for one that
    /// isn't, as every other app's updates do on a hotspot. A check the person
    /// asks for goes ahead.
    public var isMetered: () -> Bool = { false }

    /// Gentle reminders, as Sparkle asks of a menu bar app: an update it shows
    /// would otherwise open behind whatever the person is using. The app comes
    /// into the Dock while it's up, badged when nobody asked (`false`), and
    /// goes back to the menu bar when it's done.
    public var onWillShowUpdate: ((_ userInitiated: Bool) -> Void)?
    public var onUpdateAttended: (() -> Void)?
    public var onUpdateSessionEnded: (() -> Void)?

    private var updater: SPUUpdater?
    private var driver: CardUserDriver?

    public var isAvailable: Bool {
        if previewsSettings { return true }
        let info = Bundle.main.infoDictionary
        return info?["SUFeedURL"] != nil && info?["SUPublicEDKey"] != nil
    }

    /// From `applicationDidFinishLaunching`: Sparkle starts with the app.
    ///
    /// A development build can be pointed at a local appcast with
    /// `-updateFeedURL http://127.0.0.1:8765/appcast.xml`, and
    /// `-checkForUpdatesNow YES` checks at once; `-checkForUpdatesNow card`
    /// checks as the daily check does, so what it finds goes on the card
    /// while the main window is open. `-previewUpdateCard 9.9.9` shows the
    /// card alone, with nothing behind it, for pictures of it. Launch
    /// arguments only, so none outlives the run.
    public func start() {
        if let version = Self.launchArgument("previewUpdateCard") { pendingVersion = version }
        guard isAvailable, updater == nil else { return }
        let standard = SPUStandardUserDriver(hostBundle: .main, delegate: self)
        let driver = CardUserDriver(standard: standard, controller: self)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        do {
            try updater.start()
        } catch {
            NSLog("NetworkMonitor: the updater didn't start: \(error.localizedDescription)")
            return
        }
        self.driver = driver
        follow(updater)
        switch Self.launchArgument("checkForUpdatesNow") {
        case "YES":
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.checkForUpdates() }
        case "card":
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.updater?.checkForUpdatesInBackground()
            }
        default:
            break
        }
    }

    /// Its settings, and every change to them from Sparkle's side: its
    /// window's tick box, and the daily check going off or on, which switches
    /// installing automatically off and back with it. Public for the tests,
    /// with an updater that never starts.
    public func follow(_ updater: SPUUpdater) {
        checksAutomatically = updater.automaticallyChecksForUpdates
        installsAutomatically = updater.automaticallyDownloadsUpdates
        self.updater = updater
        lastChecked = updater.lastUpdateCheckDate
        updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.readSettings() }
            .store(in: &observers)
        updater.publisher(for: \.automaticallyDownloadsUpdates).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.readSettings() }
            .store(in: &observers)
        updater.publisher(for: \.allowsAutomaticUpdates).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.readSettings() }
            .store(in: &observers)
        noticeUpdatedByItself()
    }

    private func readSettings() {
        guard let updater else { return }
        let checks = updater.automaticallyChecksForUpdates, installs = updater.automaticallyDownloadsUpdates
        if checksAutomatically != checks { checksAutomatically = checks }
        if installsAutomatically != installs { installsAutomatically = installs }
    }

    private static func launchArgument(_ name: String) -> String? {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[name] as? String
    }

    public func checkForUpdates() {
        if readyVersion != nil {
            readyCardHidden = false
            onShowReady?()
            return
        }
        updater?.checkForUpdates()
    }

    // MARK: Installing by itself (#710)

    /// A version the daily check found has downloaded and can install: now if
    /// nothing would be interrupted, otherwise once nothing would be.
    public func updateIsReady(version: String, install: @escaping () -> Void) {
        installNow = install
        readyVersion = version
        readyCardHidden = false
        // However it installs, the app having been quit included, the card
        // says so the next time the window opens.
        defaults.set(version, forKey: Self.installedByItselfKey)
        // Told at once of a window closing; this is for what closes without
        // saying so, and for a speed test's result having been up a while.
        quietTimer?.invalidate()
        let timer = Timer(timeInterval: quietCheckInterval, repeats: true) { [weak self] _ in
            self?.installReadyIfQuiet()
        }
        timer.tolerance = quietCheckInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        quietTimer = timer
        installReadyIfQuiet()
    }

    /// Installs the waiting version if nothing would be interrupted. Switched
    /// off since it downloaded, it waits for the person, or for the app to
    /// quit, when Sparkle installs it.
    public func installReadyIfQuiet() {
        guard readyVersion != nil, installsAutomatically, canRestartQuietly() else { return }
        installNow?()
    }

    /// Restart Now.
    public func restartNow() {
        // They asked: there's nothing to tell them afterwards.
        defaults.removeObject(forKey: Self.installedByItselfKey)
        installNow?()
    }

    /// The waiting card's ✕: it still installs.
    public func hideReadyCard() { readyCardHidden = true }

    private func noticeUpdatedByItself() {
        guard let version = defaults.string(forKey: Self.installedByItselfKey) else { return }
        if version == currentVersion {
            updatedVersion = version
        } else {
            defaults.removeObject(forKey: Self.installedByItselfKey)
        }
    }

    public func dismissUpdated() {
        updatedVersion = nil
        defaults.removeObject(forKey: Self.installedByItselfKey)
    }

    /// A version's What's new, for a card with no window of Sparkle's behind it.
    public static func releaseURL(version: String) -> URL {
        URL(string: "https://github.com/kevinabouhanna/NetworkMonitor/releases/tag/v\(version)")!
    }

    // MARK: Back where it was

    /// As the app restarts into an update: the window that was open comes back.
    public func willRestart(now: Date = Date()) {
        guard let section = sectionToReopen() else { return }
        defaults.set(["section": section, "date": now], forKey: Self.reopenKey)
    }

    /// The section to open after a restart into an update, once, and only
    /// right after it: a restart that never came leaves nothing to open later.
    public func takeSectionToReopen(now: Date = Date()) -> String? {
        guard let left = defaults.dictionary(forKey: Self.reopenKey) else { return nil }
        defaults.removeObject(forKey: Self.reopenKey)
        guard let date = left["date"] as? Date, abs(now.timeIntervalSince(date)) < 300 else { return nil }
        return left["section"] as? String
    }

    public var canCheckForUpdates: Bool { updater?.canCheckForUpdates ?? false }

    // MARK: The card (#520)

    /// Install & Restart: downloads it, with Sparkle's progress window, and
    /// relaunches into it without asking again.
    public func installPendingUpdate() {
        pendingVersion = nil
        driver?.install()
    }

    /// What's New: Sparkle's window, with the release notes and its own
    /// Install Update, Skip This Version and Remind Me Later.
    public func showPendingUpdate() {
        pendingVersion = nil
        driver?.showInWindow()
    }

    /// The card's ✕, or the main window closing on it: until the next daily
    /// check, as Sparkle's Remind Me Later.
    public func dismissPendingUpdate() {
        guard pendingVersion != nil else { return }
        pendingVersion = nil
        driver?.dismiss()
    }

    /// The card, with nothing behind it: for the tests and the design shots.
    public func preview(_ notice: Notice?) {
        pendingVersion = nil
        readyVersion = nil
        readyCardHidden = false
        updatedVersion = nil
        switch notice {
        case .available(let version): pendingVersion = version
        case .ready(let version): readyVersion = version
        case .updated(let version): updatedVersion = version
        case nil: break
        }
    }

    /// Shows the update settings in a copy that can't update itself: for the
    /// tests and the design shots.
    public var previewsSettings = false

    fileprivate func cardDidShow(version: String) {
        pendingVersion = version
    }

    fileprivate func cardDidEnd() {
        pendingVersion = nil
    }

    // MARK: SPUUpdaterDelegate

    public func feedURLString(for updater: SPUUpdater) -> String? {
        Self.feedURL(betas: getsBetas, launchArgument: Self.launchArgument("updateFeedURL"))
    }

    public func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        Self.channels(betas: getsBetas)
    }

    public func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        try refuseOnHotspot(updateCheck)
    }

    /// Again once the appcast is read, before anything downloads (#710): the
    /// Mac may have joined a hotspot meanwhile.
    public func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem,
                        updateCheck: SPUUpdateCheck) throws {
        try refuseOnHotspot(updateCheck)
    }

    /// Nothing of its own accord on a hotspot. Public for the tests.
    public func refuseOnHotspot(_ updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updatesInBackground, isMetered() else { return }
        throw NSError(domain: "com.kevinabouhanna.NetworkMonitor", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: L("On a metered connection: the check waits.")])
    }

    public func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        updateIsReady(version: item.displayVersionString, install: immediateInstallHandler)
        return true
    }

    public func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        willRestart()
    }

    public func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        lastChecked = updater.lastUpdateCheckDate
    }

    // MARK: SPUStandardUserDriverDelegate

    public var supportsGentleScheduledUpdateReminders: Bool { true }

    public func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                          state: SPUUserUpdateState) {
        onWillShowUpdate?(state.userInitiated)
    }

    public func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        onUpdateAttended?()
    }

    public func standardUserDriverWillFinishUpdateSession() {
        onUpdateSessionEnded?()
    }
}

/// What updating says of itself (#710), in one place: Settings, the welcome
/// window and the sidebar's card.
public enum UpdateCopy {
    public static var installsInfo: String { L("A new version downloads in the background, and installs while NetworkMonitor's windows are closed and no speed test is running. NetworkMonitor restarts, which takes a few seconds. Never on a hotspot, and only if it's signed by NetworkMonitor.") }
    public static var installsSummary: String { L("New versions install by themselves while NetworkMonitor's windows are closed. Otherwise you're told, and they install when you say so.") }
}

extension UpdateController {
    /// What happens, with the switches as they are.
    public var whatHappens: String {
        guard checksAutomatically else {
            return L("NetworkMonitor looks for a new version only when you press Check Now. It installs only when you say so.")
        }
        guard installsAutomatically else {
            return L("You're told when there's a new version. It installs only when you say so.")
        }
        return getsBetas
            ? L("New versions, betas included, install by themselves while NetworkMonitor's windows are closed.")
            : L("New versions install by themselves while NetworkMonitor's windows are closed.")
    }

    /// What it's doing: beside the version, in Settings.
    public var status: String {
        if let readyVersion { return readyText(readyVersion) }
        if let pendingVersion { return L("Version %@ is available.", pendingVersion) }
        guard let lastChecked else { return L("Not checked yet") }
        let formatter = DateFormatter()
        formatter.locale = Localization.shared.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return L("Last checked: %@", formatter.string(from: lastChecked))
    }

    /// A version waiting to install. With the switch off since it downloaded,
    /// closing the window leaves it: it installs as the app quits.
    public func readyText(_ version: String) -> String {
        installsAutomatically
            ? L("Version %@ installs when you close this window.", version)
            : L("Version %@ installs when you quit NetworkMonitor.", version)
    }
}

/// Sparkle's standard windows, except for an update the daily check found
/// while the main window is open: that one is held for the card (#520), and
/// handed to the standard window only if the person asks for What's New.
private final class CardUserDriver: NSObject, SPUUserDriver {
    private let standard: SPUStandardUserDriver
    private weak var controller: UpdateController?

    /// The update on the card, and Sparkle's question about it, unanswered.
    private var held: (item: SUAppcastItem, state: SPUUserUpdateState, reply: (SPUUserUpdateChoice) -> Void)?
    /// Release notes Sparkle fetched while it was held.
    private var heldNotes: SPUDownloadData?
    private var heldNotesError: Error?
    /// Install & Restart was chosen on the card: once downloaded, it
    /// relaunches without asking a second time.
    private var installsWithoutAsking = false

    init(standard: SPUStandardUserDriver, controller: UpdateController) {
        self.standard = standard
        self.controller = controller
    }

    func install() {
        guard let held else { return }
        self.held = nil
        installsWithoutAsking = true
        held.reply(.install)
    }

    func showInWindow() {
        guard let held else { return }
        self.held = nil
        standard.showUpdateFound(with: held.item, state: held.state, reply: held.reply)
        if let heldNotes { standard.showUpdateReleaseNotes(with: heldNotes) }
        if let heldNotesError { standard.showUpdateReleaseNotesFailedToDownloadWithError(heldNotesError) }
        heldNotes = nil
        heldNotesError = nil
        standard.showUpdateInFocus()
    }

    func dismiss() {
        guard let held else { return }
        self.held = nil
        held.reply(.dismiss)
    }

    // MARK: SPUUserDriver

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard !state.userInitiated, state.stage == .notDownloaded, controller?.cardCanBeSeen() == true else {
            standard.showUpdateFound(with: appcastItem, state: state, reply: reply)
            return
        }
        held = (appcastItem, state, reply)
        heldNotes = nil
        heldNotesError = nil
        controller?.cardDidShow(version: appcastItem.displayVersionString)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        if held != nil { heldNotes = downloadData } else { standard.showUpdateReleaseNotes(with: downloadData) }
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        if held != nil { heldNotesError = error } else { standard.showUpdateReleaseNotesFailedToDownloadWithError(error) }
    }

    /// Check for Updates… while the card waits: the update, in the window.
    func showUpdateInFocus() {
        if held != nil {
            controller?.cardDidEnd()
            showInWindow()
        } else {
            standard.showUpdateInFocus()
        }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if installsWithoutAsking {
            installsWithoutAsking = false
            reply(.install)
        } else {
            standard.showReady(toInstallAndRelaunch: reply)
        }
    }

    func dismissUpdateInstallation() {
        held = nil
        heldNotes = nil
        heldNotesError = nil
        installsWithoutAsking = false
        controller?.cardDidEnd()
        standard.dismissUpdateInstallation()
    }

    // The rest, as Sparkle's own.

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        standard.show(request, reply: reply)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        standard.showUserInitiatedUpdateCheck(cancellation: cancellation)
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        standard.showUpdaterError(error, acknowledgement: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        standard.showDownloadInitiated(cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        standard.showDownloadDidReceiveData(ofLength: length)
    }

    func showDownloadDidStartExtractingUpdate() {
        standard.showDownloadDidStartExtractingUpdate()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        standard.showExtractionReceivedProgress(progress)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        standard.showInstallingUpdate(withApplicationTerminated: applicationTerminated,
                                      retryTerminatingApplication: retryTerminatingApplication)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
    }
}
