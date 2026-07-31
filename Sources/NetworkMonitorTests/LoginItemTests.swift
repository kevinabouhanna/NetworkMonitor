import Foundation
import ServiceManagement
import NetworkMonitorCore

func runLoginItemTests() {
    Check.suite("LoginItem — SMAppService registration") {

        /// The whole point of the mapping: `.requiresApproval` means macOS knows
        /// about the item but the user switched it off in System Settings.
        /// Reporting that as "enabled" would show a ticked toggle for something
        /// that will not start.
        Check.test("only .enabled counts as enabled") {
            Check.expectTrue(LoginItem.isEnabled(for: .enabled))
            Check.expectFalse(LoginItem.isEnabled(for: .requiresApproval),
                              "the user has switched it off in System Settings")
            Check.expectFalse(LoginItem.isEnabled(for: .notRegistered))
            Check.expectFalse(LoginItem.isEnabled(for: .notFound))
        }

        Check.test("label is non-empty") {
            Check.expectFalse(LoginItem.label.isEmpty)
        }

        Check.test("every failure explains itself") {
            let failures: [LoginItem.Failure] = [
                .notInstalledInApplications("/tmp/NetworkMonitor.app"),
                .requiresApproval,
                .registrationFailed("boom"),
            ]
            for failure in failures {
                let message = failure.errorDescription ?? ""
                Check.expectFalse(message.isEmpty, "\(failure) has no description")
            }
        }

        /// A user upgrading from the LaunchAgent build has that plist on disk.
        /// It has to be found and deleted, or login would start two copies.
        Check.test("legacy agent path is the per-user LaunchAgents plist") {
            let path = LoginItem.legacyAgentURL.path
            Check.expectTrue(path.contains("/Library/LaunchAgents/"), "got \(path)")
            Check.expectTrue(path.hasSuffix(".plist"), "got \(path)")
            // Per-user, never system-wide: no admin rights, no signing needed.
            Check.expectFalse(path.hasPrefix("/Library/LaunchAgents"),
                              "must be the per-user agent directory")
        }

        /// Exercised against a temporary file rather than the real path, so the
        /// suite never touches whatever the developer has installed.
        Check.test("removing the legacy agent deletes it and reports it") {
            let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("LoginItemTests-\(UUID().uuidString).plist")
            Check.expectFalse(LoginItem.hasLegacyAgent(at: temporary),
                              "nothing there yet")
            Check.expectTrue(FileManager.default.createFile(atPath: temporary.path,
                                                            contents: Data()))
            Check.expectTrue(LoginItem.hasLegacyAgent(at: temporary))

            let removed = (try? LoginItem.removeLegacyAgent(at: temporary)) ?? false
            Check.expectTrue(removed, "should report that it removed one")
            Check.expectFalse(LoginItem.hasLegacyAgent(at: temporary), "still there")
        }

        /// Migration runs on every launch, so the no-plist case must be silent
        /// and cheap rather than an error.
        Check.test("removing a legacy agent that is not there is not an error") {
            let missing = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("LoginItemTests-absent-\(UUID().uuidString).plist")
            var threw = false
            var removed = true
            do { removed = try LoginItem.removeLegacyAgent(at: missing) } catch { threw = true }
            Check.expectFalse(threw, "must not throw when there is nothing to remove")
            Check.expectFalse(removed, "should report that it removed nothing")
        }
    }
}
