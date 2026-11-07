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

        // #238: switched on in System Settings, but launchd can't start it.
        Check.test("a daemon that answers, or isn't switched on, is never registered again") {
            for (status, answering) in [(HelperService.Status.enabled, true), (.waitingForApproval, false),
                                        (.notRegistered, false), (.unavailable, false)] {
                var steps: [String] = []
                let repair = HelperService.repair(status: { status }, answers: { answering },
                                                  registerAgain: { steps.append("again") },
                                                  unregister: { steps.append("unregister") },
                                                  register: { steps.append("register"); return .done })
                Check.expectEqual(repair, .notNeeded, "\(status)")
                Check.expectEqual(steps, [], "\(status)")
            }
        }

        Check.test("one that doesn't answer is registered again as it is first, which keeps the approval") {
            var steps: [String] = []
            var answering = false
            let repair = HelperService.repair(status: { .enabled }, answers: { answering },
                                              registerAgain: { steps.append("again"); answering = true },
                                              unregister: { steps.append("unregister") },
                                              register: { steps.append("register"); return .done })
            Check.expectEqual(repair, .repaired)
            Check.expectEqual(steps, ["again"])
        }

        Check.test("and only then unregistered and registered, saying if macOS wants it allowed again") {
            let cases: [(HelperInstaller.Outcome, Bool, HelperService.Repair)] = [
                (.done, true, .repaired), (.done, false, .failed),
                (.waitingForApproval, false, .waitingForApproval), (.failed("no"), false, .failed),
            ]
            for (outcome, answersAfter, expected) in cases {
                var steps: [String] = []
                var registered = false
                let repair = HelperService.repair(status: { .enabled },
                                                  answers: { registered && answersAfter },
                                                  registerAgain: { steps.append("again") },
                                                  unregister: { steps.append("unregister") },
                                                  register: { steps.append("register"); registered = true
                                                              return outcome })
                Check.expectEqual(repair, expected, "\(outcome)")
                Check.expectEqual(steps, ["again", "unregister", "register"], "\(outcome)")
            }
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

    Check.suite("A helper that doesn't answer (#243)") {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        Check.test("a missed answer holds verbs back for a minute, and an answer lets them through") {
            var breaker = HelperService.HelperBreaker()
            Check.expectTrue(breaker.allows(now: now))
            breaker.missed(now: now)
            Check.expectFalse(breaker.allows(now: now.addingTimeInterval(59)))
            Check.expectTrue(breaker.allows(now: now.addingTimeInterval(60)))
            breaker.missed(now: now)
            breaker.answered()
            Check.expectTrue(breaker.allows(now: now.addingTimeInterval(1)))
        }

        Check.test("while it's being repaired, nothing waits on it") {
            var breaker = HelperService.HelperBreaker()
            breaker.repairing = true
            Check.expectFalse(breaker.allows(now: now))
            breaker.repairing = false
            Check.expectTrue(breaker.allows(now: now))
        }

        Check.test("a clock set back doesn't hold verbs for ever") {
            var breaker = HelperService.HelperBreaker()
            breaker.missed(now: now)
            Check.expectTrue(breaker.allows(now: now.addingTimeInterval(-3600)))
        }

        Check.test("the main thread waits 5 seconds at most") {
            Check.expectTrue(HelperService.mainThreadTimeout <= 5)
        }
    }
}
