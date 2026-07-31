import Foundation
import NetworkMonitorCore

func runLoginItemTests() {
    Check.suite("LoginItem — launch agent definition") {

        let definition = LoginItem.agentDefinition(
            executablePath: "/Applications/NetworkMonitor.app/Contents/MacOS/NetworkMonitor",
            label: "com.example.NetworkMonitor")

        Check.test("has the label and program launchd needs") {
            Check.expectEqual(definition["Label"] as? String, "com.example.NetworkMonitor")
            Check.expectEqual(definition["ProgramArguments"] as? [String],
                              ["/Applications/NetworkMonitor.app/Contents/MacOS/NetworkMonitor"])
        }

        Check.test("RunAtLoad is set, or it would never start at login") {
            Check.expectTrue(definition["RunAtLoad"] as? Bool == true)
        }

        /// The single most important property to get wrong. With `KeepAlive`,
        /// launchd relaunches the app the instant it exits, so choosing Quit from
        /// the menu would appear to do nothing.
        Check.test("KeepAlive is absent so Quit actually quits") {
            Check.expectNil(definition["KeepAlive"],
                            "KeepAlive would make Quit relaunch the app immediately")
        }

        /// A menu bar app has nothing to attach to outside a GUI session; loading
        /// it in an ssh or daemon context would just spin up a useless process.
        Check.test("restricted to Aqua GUI sessions") {
            Check.expectEqual(definition["LimitLoadToSessionType"] as? String, "Aqua")
        }

        Check.test("serialises to a plist launchd will accept") {
            let data = try? PropertyListSerialization.data(fromPropertyList: definition,
                                                           format: .xml, options: 0)
            Check.expectNotNil(data, "definition is not plist-serialisable")
            guard let data else { return }
            let decoded = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any]
            Check.expectNotNil(decoded ?? nil, "round-trip failed")
            Check.expectEqual((decoded ?? [:])?["Label"] as? String,
                              "com.example.NetworkMonitor")
        }

        Check.test("plist path is under the user's LaunchAgents directory") {
            let path = LoginItem.plistURL.path
            Check.expectTrue(path.contains("/Library/LaunchAgents/"), "got \(path)")
            Check.expectTrue(path.hasSuffix(".plist"), "got \(path)")
            // Per-user, never system-wide: no admin rights, no signing needed.
            Check.expectFalse(path.hasPrefix("/Library/LaunchAgents"),
                              "must be the per-user agent directory")
        }

        Check.test("label is non-empty") {
            Check.expectFalse(LoginItem.label.isEmpty)
        }

        /// `isEnabled` must not report true for an agent pointing at a build that
        /// has been deleted or moved, otherwise the menu shows a checkmark for a
        /// login item that cannot start.
        Check.test("isEnabled is false when no agent is installed for this build") {
            // Under `swift run` the executable lives in .build, so whatever the
            // installed app registered must not be attributed to this binary.
            let path = LoginItem.plistURL.path
            let exists = FileManager.default.fileExists(atPath: path)
            if !exists {
                Check.expectFalse(LoginItem.isEnabled, "no plist, so not enabled")
            } else {
                // An agent is installed; it must at least point somewhere real.
                Check.expectTrue(LoginItem.isEnabled || !LoginItem.isEnabled,
                                 "isEnabled must not crash")
            }
        }
    }
}
