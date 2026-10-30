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

    private var controller: SPUStandardUpdaterController?
    private var updater: SPUUpdater? { controller?.updater }

    public var isAvailable: Bool {
        let info = Bundle.main.infoDictionary
        return info?["SUFeedURL"] != nil && info?["SUPublicEDKey"] != nil
    }

    /// From `applicationDidFinishLaunching`: Sparkle starts with the app.
    ///
    /// A development build can be pointed at a local appcast with
    /// `-updateFeedURL http://127.0.0.1:8765/appcast.xml`, and
    /// `-checkForUpdatesNow YES` checks at once: launch arguments only, so
    /// neither outlives the run.
    public func start() {
        guard isAvailable, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self,
                                                      userDriverDelegate: self)
        self.controller = controller
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
        if Self.launchArgument("checkForUpdatesNow") == "YES" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.checkForUpdates() }
        }
    }

    private static func launchArgument(_ name: String) -> String? {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[name] as? String
    }

    public func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    public var canCheckForUpdates: Bool { updater?.canCheckForUpdates ?? false }

    // MARK: SPUUpdaterDelegate

    public func feedURLString(for updater: SPUUpdater) -> String? {
        Self.launchArgument("updateFeedURL")
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

    public func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updatesInBackground, isMetered() else { return }
        throw NSError(domain: "com.kevinabouhanna.NetworkMonitor", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "On a metered connection: the check waits."])
    }
}
