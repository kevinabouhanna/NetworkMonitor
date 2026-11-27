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
        /// Runs until `condition` holds, for what arrives when it arrives:
        /// Sparkle's settings reach each other through another process (#751).
        func arrives(_ condition: () -> Bool) -> Bool {
            let limit = Date().addingTimeInterval(20)
            while !condition(), Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return condition()
        }
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
                Check.expectTrue(arrives { updates.installsAutomatically }, "ticked there, on here")
                updates.installsAutomatically = false
                Check.expectTrue(arrives { !tickBox.automaticallyDownloadsUpdates }, "off here, not ticked there")
                updates.installsAutomatically = true
                Check.expectTrue(arrives { tickBox.automaticallyDownloadsUpdates }, "on here, ticked there")
                tickBox.automaticallyDownloadsUpdates = false
                Check.expectTrue(arrives { !updates.installsAutomatically }, "unticked there, off here")
            }
        }

        Check.test("off while the daily check is off, and back with it") {
            withUpdater { make, _ in
                let updates = controller("updates-checks")
                updates.follow(make())
                updates.installsAutomatically = true
                updates.checksAutomatically = false
                Check.expectTrue(arrives { !updates.installsAutomatically }, "it needs the daily check")
                updates.checksAutomatically = true
                Check.expectTrue(arrives { updates.installsAutomatically }, "the choice came back")
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
            Check.expectTrue(arrives { installs == 1 }, "installed once nothing was open")
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

        Check.test("a beta that downloaded doesn't install by itself once betas are off") {
            let updates = controller("updates-beta-off")
            updates.installsAutomatically = true
            updates.getsBetas = true
            updates.canRestartQuietly = { false }
            var installs = 0
            updates.updateIsReady(version: "2.0-beta.1", isBeta: true) { installs += 1 }
            updates.getsBetas = false
            updates.canRestartQuietly = { true }
            updates.installReadyIfQuiet()
            Check.expectEqual(installs, 0)
            Check.expectTrue(updates.whatHappens.contains("once this one has installed"), updates.whatHappens)
            updates.getsBetas = true
            updates.installReadyIfQuiet()
            Check.expectEqual(installs, 1, "betas back on")
        }

        Check.test("an install that fails leaves nothing waiting") {
            withUpdater { make, _ in
                let defaults = Check.defaults("updates-failed")
                let updates = UpdateController(defaults: defaults)
                updates.installsAutomatically = true
                updates.quietCheckInterval = 0.1
                updates.canRestartQuietly = { false }
                var installs = 0
                updates.updateIsReady(version: "2.0") { installs += 1 }
                updates.readyEnded()
                updates.canRestartQuietly = { true }
                settle()
                Check.expectNil(updates.notice)
                Check.expectEqual(installs, 0, "nothing to look again for")
                Check.expectNil(defaults.string(forKey: UpdateController.installedByItselfKey))
            }
        }

        Check.test("the last check is when GitHub answered, and kept") {
            withUpdater { make, _ in
                let defaults = Check.defaults("updates-heard")
                let updates = UpdateController(defaults: defaults)
                updates.follow(make())
                Check.expectNil(updates.lastChecked, "never")
                let then = Date(timeIntervalSinceNow: -60)
                updates.heardFromGitHub(now: then)
                let relaunched = UpdateController(defaults: defaults)
                relaunched.follow(make())
                Check.expectEqual(relaunched.lastChecked?.timeIntervalSince1970 ?? 0, then.timeIntervalSince1970, accuracy: 0.01)
            }
        }

        Check.test("switched on with a version on the card, the card gives way to installing it") {
            let updates = controller("updates-on-with-card")
            updates.preview(.available("2.0"))
            updates.installsAutomatically = true
            Check.expectNil(updates.notice)
        }

        Check.test("What's New opens that version's page, whatever it's called") {
            Check.expectEqual(UpdateController.releaseURL(version: "1.33.0-beta.1").absoluteString,
                              "https://github.com/kevinabouhanna/NetworkMonitor/releases/tag/v1.33.0-beta.1")
            Check.expectTrue(UpdateController.releaseURL(version: "1 2").absoluteString.hasSuffix("v1%202"))
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

        Check.test("a check skipped on a hotspot goes ahead once off it (#810)") {
            let updates = controller("updates-after-hotspot")
            var checks = 0
            updates.checkInBackground = { checks += 1 }
            // Leaving a hotspot with nothing skipped checks nothing.
            updates.meteringDidChange(isMetered: false)
            Check.expectEqual(checks, 0)
            updates.isMetered = { true }
            _ = try? updates.refuseOnHotspot(.updatesInBackground)
            Check.expectTrue(updates.refusedWhileMetered)
            // Still metered (another hotspot): it waits.
            updates.meteringDidChange(isMetered: true)
            Check.expectEqual(checks, 0)
            updates.isMetered = { false }
            updates.meteringDidChange(isMetered: false)
            Check.expectEqual(checks, 1)
            // Kept until GitHub answers: a check that failed is tried again.
            Check.expectTrue(updates.refusedWhileMetered)
            updates.meteringDidChange(isMetered: false)
            Check.expectEqual(checks, 2)
            updates.heardFromGitHub()
            Check.expectFalse(updates.refusedWhileMetered)
            updates.meteringDidChange(isMetered: false)
            Check.expectEqual(checks, 2)
            // Check Now is never refused, so leaves nothing to ask later.
            updates.isMetered = { true }
            _ = try? updates.refuseOnHotspot(.updates)
            Check.expectFalse(updates.refusedWhileMetered)
            // With the daily check off, nothing goes ahead by itself.
            _ = try? updates.refuseOnHotspot(.updatesInBackground)
            updates.checksAutomatically = false
            updates.meteringDidChange(isMetered: false)
            Check.expectEqual(checks, 2)
        }

        Check.test("a check skipped on a hotspot is remembered across launches (#810)") {
            let defaults = Check.defaults("updates-after-hotspot-relaunch")
            let before = UpdateController(defaults: defaults)
            before.isMetered = { true }
            _ = try? before.refuseOnHotspot(.updatesInBackground)
            let after = UpdateController(defaults: defaults)
            Check.expectTrue(after.refusedWhileMetered)
            var checks = 0
            after.checkInBackground = { checks += 1 }
            after.meteringDidChange(isMetered: false)
            Check.expectEqual(checks, 1)
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
