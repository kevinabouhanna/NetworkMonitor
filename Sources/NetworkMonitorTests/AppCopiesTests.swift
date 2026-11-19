import FirewallPolicy
import Foundation
import NetworkMonitorCore
import SQLite3

/// Copies of one app in other folders are one row (#663): every iOS simulator
/// install, builds of an installed app, apps macOS moved aside.
func runAppCopiesTests() {
    let simulator = "/Users/k/Library/Developer/CoreSimulator"
    func simulatorInstall(device: String, install: String) -> String {
        "\(simulator)/Devices/\(device)/data/Containers/Bundle/Application/\(install)/Home Control.app"
    }
    let firstInstall = simulatorInstall(device: "6F0E1B52-0C1E-4E5B-9E36-1A2B3C4D5E6F",
                                        install: "0B7A3C1D-2E4F-4A6B-8C9D-0E1F2A3B4C5D")
    let secondInstall = simulatorInstall(device: "9A8B7C6D-5E4F-4321-8765-0FEDCBA98765",
                                         install: "11111111-2222-4333-8444-555555555555")

    /// A folder with `Home Control.app` installed in it and two copies, each
    /// with the bundle id given.
    func apps(installed: String, copies: [String]) -> (folder: String, copies: [String], cleanup: () -> Void) {
        let root = NSTemporaryDirectory() + "app-copies-\(UUID().uuidString)"
        func make(_ path: String, _ id: String) {
            let contents = path + "/Contents"
            try? FileManager.default.createDirectory(atPath: contents + "/MacOS", withIntermediateDirectories: true)
            let plist = try? PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id],
                                                            format: .xml, options: 0)
            FileManager.default.createFile(atPath: contents + "/Info.plist", contents: plist)
        }
        let folder = root + "/Applications"
        make(folder + "/Home Control.app", installed)
        var paths: [String] = []
        for (index, id) in copies.enumerated() {
            let path = root + "/work/build-\(index)/Home Control.app"
            make(path, id)
            paths.append(path)
        }
        return (folder, paths, { try? FileManager.default.removeItem(atPath: root) })
    }

    Check.suite("App copies — simulator installs (#663)") {

        Check.test("two installs of one app, on two simulators, are one identity") {
            let first = AppIdentityResolver.identity(forExecutablePath: firstInstall + "/Home Control", fallbackName: "")
            let second = AppIdentityResolver.identity(forExecutablePath: secondInstall + "/Home Control", fallbackName: "")
            Check.expectEqual(first.key, second.key)
            Check.expectEqual(first.key, "\(simulator)/Home Control.app")
            Check.expectEqual(first.displayName, L("%@ (Simulator)", "Home Control"))
            Check.expectEqual(first.bundlePath, firstInstall, "its icon and name are still read from the copy")
        }

        // The content filter files a connection by `AppKey`; it must agree.
        Check.test("the filter files it under the same key") {
            Check.expectEqual(AppKey.key(forExecutablePath: secondInstall + "/Home Control"),
                              "\(simulator)/Home Control.app")
            Check.expectTrue(AppKey.isSimulatorApp("\(simulator)/Home Control.app"))
            Check.expectTrue(AppKey.isSimulatorApp(firstInstall))
            Check.expectFalse(AppKey.isSimulatorApp("/Applications/Home Control.app"))
        }

        Check.test("a key read back is the same app, still named for the simulator") {
            let identity = AppIdentityResolver.identity(forKey: "\(simulator)/Home Control.app")
            Check.expectEqual(identity.key, "\(simulator)/Home Control.app")
            Check.expectEqual(identity.displayName, L("%@ (Simulator)", "Home Control"))
        }

        Check.test("the simulator's own apps keep their place") {
            let news = "/private/var/run/com.apple.security.cryptexd/mnt/com.apple.iPhoneOS.SimulatorRuntime-v24.2.cdq9HQ"
                + "/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 27.2.simruntime/Contents/Resources/RuntimeRoot"
                + "/Applications/News.app"
            Check.expectNil(AppKey.simulatorInstallKey(news))
            Check.expectFalse(AppKey.isSimulatorApp(news))
        }
    }

    Check.suite("App copies — builds of an installed app (#663)") {

        Check.test("the same app in two folders is one row, the installed one") {
            let made = apps(installed: "com.example.home", copies: ["com.example.home", "com.example.home"])
            defer { made.cleanup() }
            let installed = made.folder + "/Home Control.app"
            for copy in made.copies {
                Check.expectEqual(AppKey.key(forBundlePath: copy, installedFolder: made.folder), installed, copy)
            }
            Check.expectEqual(AppKey.key(forBundlePath: installed, installedFolder: made.folder), installed)
        }

        Check.test("a rule on the row holds for every copy") {
            let made = apps(installed: "com.example.home", copies: ["com.example.home"])
            defer { made.cleanup() }
            let installed = made.folder + "/Home Control.app"
            let block = FirewallRule(subject: .app, key: installed, title: "Home Control", action: .block)
            for path in [installed, made.copies[0]] {
                let flow = FlowFacts(appKeys: [AppKey.key(forBundlePath: path, installedFolder: made.folder)],
                                     companyKey: "Amazon", country: "US", address: "52.1.2.3", port: 443, isApple: false)
                Check.expectEqual(FirewallPolicy(rules: [block]).decide(flow), .block(.rule(block)), path)
            }
        }

        // The filter's sandbox may keep the copy's Info.plist closed: it
        // passes the id from the signature instead.
        Check.test("a bundle id given is used in place of the copy's Info.plist") {
            let made = apps(installed: "com.example.home", copies: ["com.example.other"])
            defer { made.cleanup() }
            Check.expectEqual(AppKey.key(forBundlePath: made.copies[0], bundleID: "com.example.home",
                                         installedFolder: made.folder),
                              made.folder + "/Home Control.app")
        }

        Check.test("another app of the same name stays apart") {
            let made = apps(installed: "com.example.home", copies: ["com.example.other"])
            defer { made.cleanup() }
            Check.expectEqual(AppKey.key(forBundlePath: made.copies[0], installedFolder: made.folder), made.copies[0])
        }

        Check.test("an app in an installed place is never a copy of another") {
            Check.expectTrue(AppKey.isInstalledPlace("/Applications/Utilities/Terminal.app"))
            Check.expectTrue(AppKey.isInstalledPlace("/System/Applications/Mail.app"))
            Check.expectTrue(AppKey.isInstalledPlace("/Users/k/Applications/Home Control.app"))
            Check.expectFalse(AppKey.isInstalledPlace("/Users/k/Work/home/target/release/Home Control.app"))
            Check.expectEqual(AppKey.key(forBundlePath: "/Applications/Slack.app"), "/Applications/Slack.app")
        }
    }

    Check.suite("App copies — folders with a random part (#663)") {

        Check.test("an app macOS moved aside is keyed without its random folder") {
            let moved = "/private/var/folders/j7/abc/T/AppTranslocation/A9D221B6-C310-47DC-8FD6-314153115DDA/d/GitHub Desktop.app"
            Check.expectEqual(AppKey.key(forBundlePath: moved),
                              "/private/var/folders/j7/abc/T/AppTranslocation/GitHub Desktop.app")
        }

        Check.test("a simulator runtime's daemon is one program on every mount") {
            let mount = "/private/var/run/com.apple.security.cryptexd/mnt/com.apple.iPhoneOS.SimulatorRuntime-v24.2.8117.0"
            let tail = "/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 27.2.simruntime/Contents/Resources"
                + "/RuntimeRoot/usr/libexec/trustd"
            let first = AppIdentityResolver.identity(forExecutablePath: mount + ".cdq9HQ" + tail, fallbackName: "trustd")
            let second = AppIdentityResolver.identity(forExecutablePath: mount + ".ZXcZdz" + tail, fallbackName: "trustd")
            Check.expectEqual(first.key, second.key)
            Check.expectEqual(first.key, mount + tail)
            Check.expectEqual(AppKey.key(forExecutablePath: mount + ".ZXcZdz" + tail), mount + tail)
        }

        Check.test("an ordinary program's key is its path, as before") {
            Check.expectEqual(AppKey.key(forExecutablePath: "/usr/sbin/mDNSResponder"), "/usr/sbin/mDNSResponder")
        }
    }

    Check.suite("App copies — what was stored apart (#663)") {

        Check.test("a stored row's key now: a simulator install, a build that's gone, a program under one") {
            let made = apps(installed: "com.example.home", copies: [])
            defer { made.cleanup() }
            Check.expectEqual(AppIdentityResolver.currentKey(forStored: firstInstall, installedFolder: made.folder),
                              "\(simulator)/Home Control.app")
            // Deleted since, so its id can't be read: the installed app's name says it.
            let gone = "/private/tmp/home-control-152/target/release/bundle/macos/Home Control.app"
            Check.expectEqual(AppIdentityResolver.currentKey(forStored: gone, installedFolder: made.folder),
                              made.folder + "/Home Control.app")
            let child = AppKey.key(adopting: "/usr/bin/curl", by: gone)
            Check.expectEqual(AppIdentityResolver.currentKey(forStored: child, installedFolder: made.folder),
                              AppKey.key(adopting: "/usr/bin/curl", by: made.folder + "/Home Control.app"))
            Check.expectEqual(AppIdentityResolver.currentKey(forStored: "/Applications/Slack.app"),
                              "/Applications/Slack.app")
        }

        Check.test("today's totals fold into one row, bytes added") {
            let now = Date()
            let apps: [String: AppTotals] = [
                firstInstall: AppTotals(displayName: "Home Control", bundlePath: firstInstall, bytesIn: 4_000, bytesOut: 100,
                                        lastActive: now - 60),
                secondInstall: AppTotals(displayName: "Home Control", bundlePath: secondInstall, bytesIn: 2_000,
                                         bytesOut: 50, lastActive: now),
                "/Applications/Slack.app": AppTotals(displayName: "Slack", bytesIn: 1, bytesOut: 1, lastActive: now),
            ]
            let folded = UsageStore.foldingCopies(apps)
            Check.expectEqual(folded.count, 2)
            let row = folded["\(simulator)/Home Control.app"]
            Check.expectEqual(row?.bytesIn, 6_000)
            Check.expectEqual(row?.bytesOut, 150)
            Check.expectEqual(row?.lastActive, now)
            Check.expectEqual(row?.displayName, L("%@ (Simulator)", "Home Control"))
        }

        Check.test("history's rows of one app fold into one, servers and all") {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("history-copies-\(UUID().uuidString).sqlite")
            defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let reference = Date(timeIntervalSince1970: 1_792_573_800)
            func install(_ path: String) -> AppIdentity {
                // As an earlier version filed it: under its own folder.
                AppIdentity(key: path, displayName: "Home Control", bundlePath: path, isSystem: false)
            }
            do {
                let history = UsageHistory(databaseURL: url, calendar: calendar)
                history.join(NetworkFingerprint(id: "A", kind: .wifi, gatewayMAC: "A", defaultLabel: "Net A",
                                                isExpensive: false, isConstrained: false),
                             label: "Net A", switched: false, now: reference)
                history.recordApps([(install(firstInstall), 4_000, 100), (install(secondInstall), 2_000, 50)],
                                   servers: [firstInstall: ["52.1.2.3": ByteCounts(bytesIn: 4_000, bytesOut: 100)],
                                             secondInstall: ["52.1.2.3": ByteCounts(bytesIn: 2_000, bytesOut: 50)]],
                                   now: reference)
                history.flush()
            }
            // As a database from before #663 has it.
            var handle: OpaquePointer?
            sqlite3_open(url.path, &handle)
            sqlite3_exec(handle, "PRAGMA user_version = 1", nil, nil, nil)
            sqlite3_close(handle)

            let reopened = UsageHistory(databaseURL: url, calendar: calendar)
            let period = HistoryPeriod(scale: .day, containing: reference, calendar: calendar)
            let report = reopened.report(for: period)
            Check.expectEqual(report.apps.map(\.displayName), [L("%@ (Simulator)", "Home Control")])
            Check.expectEqual(report.apps.first?.total, 6_150)
            let servers = reopened.servers(in: period)
            Check.expectEqual(servers.map(\.appKey), ["\(simulator)/Home Control.app"])
            Check.expectEqual(servers.first?.bytesIn, 6_000)
        }
    }
}
