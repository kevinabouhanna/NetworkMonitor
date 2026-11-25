import Foundation
import NetworkMonitorCore
import Sparkle

/// Installing new versions by itself (#710): what the switch is, when it
/// installs, and what's said of it. The switch is read and written through a
/// real `SPUUpdater`, which never starts: nothing is checked or downloaded.
func runUpdateTests() {
    Check.suite("Update settings (#710)") {

        /// A bundle that can update itself, and the settings Sparkle keeps for it.
        func withUpdater(_ body: (_ make: () -> SPUUpdater, _ bundle: Bundle) -> Void) {
            let id = "com.kevinabouhanna.NetworkMonitor.tests.updates-\(UUID().uuidString)"
            let app = FileManager.default.temporaryDirectory.appendingPathComponent("\(id).app")
            let contents = app.appendingPathComponent("Contents")
            try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: [String: Any] = [
                "CFBundleIdentifier": id, "CFBundleName": "Updates", "CFBundleVersion": "1",
                "CFBundleShortVersionString": "1.0", "CFBundlePackageType": "APPL",
                "SUFeedURL": "https://127.0.0.1:1/appcast.xml",
                "SUPublicEDKey": "Aepvgea9syp9AsDuIzvxAVpldAhbPvAgi1mExn9it5Y=", "SUEnableAutomaticChecks": true,
            ]
            (info as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
            defer {
                try? FileManager.default.removeItem(at: app)
                UserDefaults.standard.removePersistentDomain(forName: id)
                try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Preferences/\(id).plist"))
            }
            guard let bundle = Bundle(url: app) else { return Check.expectTrue(false, "no bundle at \(app.path)") }
            body({
                SPUUpdater(hostBundle: bundle, applicationBundle: bundle,
                           userDriver: SPUStandardUserDriver(hostBundle: bundle, delegate: nil), delegate: nil)
            }, bundle)
        }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
        func controller(_ name: String) -> UpdateController { UpdateController(defaults: Check.defaults(name)) }

        Check.test("off on a new copy, and kept after a relaunch") {
            withUpdater { make, _ in
                let updates = controller("updates-new")
                updates.follow(make())
                Check.expectFalse(updates.installsAutomatically, "off by default")
                Check.expectTrue(updates.checksAutomatically)
                updates.installsAutomatically = true
                let relaunched = controller("updates-relaunched")
                relaunched.follow(make())
                Check.expectTrue(relaunched.installsAutomatically, "kept")
            }
        }

        // Sparkle's window has settings of its own onto the same place.
        Check.test("the switch and Sparkle's tick box are one choice, both ways") {
            withUpdater { make, bundle in
                let updates = controller("updates-tick")
                updates.follow(make())
                let tickBox = SPUUpdaterSettings(hostBundle: bundle)
                tickBox.automaticallyDownloadsUpdates = true
                settle()
                Check.expectTrue(updates.installsAutomatically, "ticked there, on here")
                updates.installsAutomatically = false
                settle()
                Check.expectFalse(tickBox.automaticallyDownloadsUpdates, "off here, not ticked there")
                updates.installsAutomatically = true
                settle()
                Check.expectTrue(tickBox.automaticallyDownloadsUpdates, "on here, ticked there")
                tickBox.automaticallyDownloadsUpdates = false
                settle()
                Check.expectFalse(updates.installsAutomatically, "unticked there, off here")
            }
        }

        Check.test("off while the daily check is off, and back with it") {
            withUpdater { make, _ in
                let updates = controller("updates-checks")
                updates.follow(make())
                updates.installsAutomatically = true
                updates.checksAutomatically = false
                settle()
                Check.expectFalse(updates.installsAutomatically, "it needs the daily check")
                updates.checksAutomatically = true
                settle()
                Check.expectTrue(updates.installsAutomatically, "the choice came back")
            }
        }

        Check.test("installs at once with nothing open, otherwise once nothing is") {
            let updates = controller("updates-quiet")
            updates.installsAutomatically = true
            var installs = 0
            updates.updateIsReady(version: "2.0") { installs += 1 }
            Check.expectEqual(installs, 1, "nothing open")

            let busy = controller("updates-busy")
            busy.installsAutomatically = true
            // A window open, or a speed test running.
            var quiet = false
            busy.canRestartQuietly = { quiet }
            installs = 0
            busy.updateIsReady(version: "2.0") { installs += 1 }
            busy.installReadyIfQuiet()
            Check.expectEqual(installs, 0, "waits")
            Check.expectEqual(busy.notice, .ready("2.0"), "and says so")
            busy.hideReadyCard()
            Check.expectNil(busy.notice, "the card put away")
            Check.expectEqual(busy.readyVersion, "2.0", "still waiting")
            quiet = true
            busy.installReadyIfQuiet()
            Check.expectEqual(installs, 1, "once nothing's open")
        }

        Check.test("looks again by itself, for what closes without saying so") {
            let updates = controller("updates-again")
            updates.installsAutomatically = true
            updates.quietCheckInterval = 0.1
            var quiet = false, installs = 0
            updates.canRestartQuietly = { quiet }
            updates.updateIsReady(version: "2.0") {
                installs += 1
                // As the app going does.
                quiet = false
            }
            settle()
            Check.expectEqual(installs, 0)
            quiet = true
            settle()
            Check.expectEqual(installs, 1)
        }

        Check.test("switched off since it downloaded, it waits to be asked") {
            let updates = controller("updates-off-since")
            updates.installsAutomatically = true
            updates.canRestartQuietly = { false }
            var installs = 0
            updates.updateIsReady(version: "2.0") { installs += 1 }
            updates.installsAutomatically = false
            updates.canRestartQuietly = { true }
            updates.installReadyIfQuiet()
            Check.expectEqual(installs, 0)
            Check.expectTrue(updates.status.contains(L("Version %@ installs when you quit NetworkMonitor.", "2.0")), updates.status)
            updates.restartNow()
            Check.expectEqual(installs, 1, "Restart Now")
        }

        Check.test("Check for Updates… while one waits shows it, card and all") {
            let updates = controller("updates-check")
            updates.canRestartQuietly = { false }
            var shown = 0
            updates.onShowReady = { shown += 1 }
            updates.updateIsReady(version: "2.0") {}
            updates.hideReadyCard()
            updates.checkForUpdates()
            Check.expectEqual(shown, 1)
            Check.expectEqual(updates.notice, .ready("2.0"))
        }

        Check.test("on a hotspot, nothing is checked or downloaded of its own accord") {
            let updates = controller("updates-hotspot")
            func refused(_ check: SPUUpdateCheck) -> Bool {
                do { try updates.refuseOnHotspot(check); return false } catch { return true }
            }
            Check.expectFalse(refused(.updatesInBackground), "not on one")
            updates.isMetered = { true }
            Check.expectTrue(refused(.updatesInBackground), "the daily check, and the download it would start")
            Check.expectFalse(refused(.updates), "Check Now goes ahead")
        }

        Check.test("says once that it installed by itself, until that's been seen") {
            withUpdater { make, _ in
                let defaults = Check.defaults("updates-itself")
                let before = UpdateController(defaults: defaults)
                before.canRestartQuietly = { false }
                // The tests' own version, which is none.
                before.updateIsReady(version: before.currentVersion) {}
                let after = UpdateController(defaults: defaults)
                after.follow(make())
                Check.expectEqual(after.notice, .updated(after.currentVersion))
                let again = UpdateController(defaults: defaults)
                again.follow(make())
                Check.expectEqual(again.notice, .updated(after.currentVersion), "not seen yet")
                again.dismissUpdated()
                let seen = UpdateController(defaults: defaults)
                seen.follow(make())
                Check.expectNil(seen.notice, "seen")

                // Never installed: nothing to say.
                seen.canRestartQuietly = { false }
                seen.updateIsReady(version: "99.0") {}
                let old = UpdateController(defaults: defaults)
                old.follow(make())
                Check.expectNil(old.notice, "still the old version")

                // Restart Now: they know.
                seen.updateIsReady(version: seen.currentVersion) {}
                seen.restartNow()
                let asked = UpdateController(defaults: defaults)
                asked.follow(make())
                Check.expectNil(asked.notice, "they asked for it")
            }
        }

        Check.test("comes back to the open window, once, and only right after the restart") {
            let defaults = Check.defaults("updates-reopen")
            let updates = UpdateController(defaults: defaults)
            updates.willRestart()
            Check.expectNil(updates.takeSectionToReopen(), "no window was open")
            updates.sectionToReopen = { "connections" }
            updates.willRestart()
            let after = UpdateController(defaults: defaults)
            Check.expectEqual(after.takeSectionToReopen(), "connections")
            Check.expectNil(after.takeSectionToReopen(), "once")
            updates.willRestart(now: Date(timeIntervalSinceNow: -3600))
            Check.expectNil(after.takeSectionToReopen(), "a restart that never came")
        }

        Check.test("what's said is what happens, with the switches as they are") {
            let updates = controller("updates-words")
            let says = { updates.whatHappens }
            Check.expectTrue(says().contains("only when you say so") && says().contains("You're told"), says())
            updates.installsAutomatically = true
            Check.expectTrue(says().contains("by themselves") && !says().contains("betas"), says())
            updates.getsBetas = true
            Check.expectTrue(says().contains("by themselves") && says().contains("betas included"), says())
            updates.checksAutomatically = false
            updates.installsAutomatically = false
            Check.expectTrue(says().contains("only when you press Check Now"), says())
            Check.expectTrue(updates.status.contains("Not checked yet"), updates.status)
        }
    }
}
