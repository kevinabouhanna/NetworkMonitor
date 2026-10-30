import Foundation
import LowDataMode
import NetworkMonitorCore

func runHelperDaemonTests() {
    Check.suite("Helper as a launch daemon (#131)") {

        Check.test("the daemon decides, once this build has one") {
            typealias S = HelperInstaller.State
            let cases: [(HelperService.Status, Bool, S)] = [
                (.enabled, false, .current), (.enabled, true, .current),
                (.waitingForApproval, false, .waitingForApproval), (.waitingForApproval, true, .waitingForApproval),
                (.notRegistered, false, .missing),
                (.notRegistered, true, .outdated),   // a sudo helper moves over
            ]
            for (daemon, legacy, expected) in cases {
                Check.expectEqual(HelperInstaller.state(daemon: daemon, legacyInstalled: legacy, status: nil),
                                  expected, "\(daemon), sudo helper \(legacy)")
            }
        }

        Check.test("without one, the sudo helper is judged by its version, as before") {
            let current = #"{"version": \#(HelperProtocol.version)}"#
            Check.expectEqual(HelperInstaller.state(daemon: .unavailable, legacyInstalled: true, status: current),
                              .current)
            Check.expectEqual(HelperInstaller.state(daemon: .unavailable, legacyInstalled: true,
                                                    status: #"{"version": 4}"#), .outdated)
            Check.expectEqual(HelperInstaller.state(daemon: .unavailable, legacyInstalled: true, status: nil),
                              .outdated, "installed but not answering")
            Check.expectEqual(HelperInstaller.state(daemon: .unavailable, legacyInstalled: false, status: nil),
                              .missing)
        }

        Check.test("over XPC, the verbs the sudoers rule granted, and uninstall; never self-heal or serve") {
            Check.expectEqual(HelperDaemon.verbs,
                              ["status", "suppress", "restore", "constrain", "unconstrain", "uninstall"])
            Check.expectFalse(HelperDaemon.verbs.contains("self-heal"))
            Check.expectFalse(HelperDaemon.verbs.contains("serve"))
        }

        Check.test("only NetworkMonitor's team, each way") {
            for requirement in [HelperDaemon.clientRequirement, HelperDaemon.helperRequirement] {
                Check.expectTrue(requirement.contains("GRQKG7M8CL"))
                Check.expectTrue(requirement.hasPrefix("anchor apple generic"))
            }
            Check.expectTrue(HelperDaemon.clientRequirement.contains(#""com.kevinabouhanna.NetworkMonitor""#))
            Check.expectTrue(HelperDaemon.helperRequirement.contains(#""com.kevinabouhanna.NetworkMonitor.helper""#))
        }

        // The plist is what launchd reads, and nothing else checks it agrees.
        Check.test("the shipped plist names the daemon as both sides do") {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/LaunchDaemons/\(HelperDaemon.plistName)")
            let plist = (try? Data(contentsOf: url))
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
            Check.expectEqual(plist?["Label"] as? String, HelperDaemon.label)
            Check.expectEqual((plist?["MachServices"] as? [String: Bool])?[HelperDaemon.machServiceName], true)
            Check.expectEqual(plist?["BundleProgram"] as? String,
                              "Contents/Library/LaunchServices/com.kevinabouhanna.NetworkMonitor.helper")
            Check.expectEqual((plist?["ProgramArguments"] as? [String])?.last, "serve")
            Check.expectEqual(plist?["AssociatedBundleIdentifiers"] as? [String], ["com.kevinabouhanna.NetworkMonitor"])
        }
    }
}
