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
        self.updater = updater
        checksAutomatically = updater.automaticallyChecksForUpdates
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

    private static func launchArgument(_ name: String) -> String? {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[name] as? String
    }

    public func checkForUpdates() {
        updater?.checkForUpdates()
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

    /// The card for a version, with nothing behind it: for the tests.
    public func previewCard(version: String?) {
        pendingVersion = version
    }

    fileprivate func cardDidShow(version: String) {
        pendingVersion = version
    }

    fileprivate func cardDidEnd() {
        pendingVersion = nil
    }

    // MARK: SPUUpdaterDelegate

    public func feedURLString(for updater: SPUUpdater) -> String? {
        Self.launchArgument("updateFeedURL")
    }

    public func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updatesInBackground, isMetered() else { return }
        throw NSError(domain: "com.kevinabouhanna.NetworkMonitor", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: L("On a metered connection: the check waits.")])
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
