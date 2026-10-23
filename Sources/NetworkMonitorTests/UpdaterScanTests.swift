import Foundation
import NetworkMonitorCore

// MARK: - Fixtures

private func temporaryDirectory(_ prefix: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeDirectory(_ url: URL) {
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}

private func makeFile(_ url: URL, bytes: Int = 0, executable: Bool = false,
                      text: String? = nil) {
    makeDirectory(url.deletingLastPathComponent())
    let data = text.map { Data($0.utf8) } ?? Data(count: bytes)
    FileManager.default.createFile(atPath: url.path, contents: data)
    if executable {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: url.path)
    }
}

/// A throwaway `.app` holding only what the scan looks at.
private func makeApp(in root: URL, name: String, identifier: String,
                     _ build: (URL) -> Void = { _ in }) -> URL {
    let app = root.appendingPathComponent("\(name).app")
    let contents = app.appendingPathComponent("Contents")
    makeDirectory(contents)
    let info: [String: Any] = ["CFBundleIdentifier": identifier,
                               "CFBundleName": name,
                               "CFBundlePackageType": "APPL"]
    if let data = try? PropertyListSerialization.data(fromPropertyList: info,
                                                       format: .xml, options: 0) {
        try? data.write(to: contents.appendingPathComponent("Info.plist"))
    }
    build(contents)
    return app
}

// MARK: - UpdaterScan

func runUpdaterScanTests() {
    Check.suite("UpdaterScan") {

        Check.test("Squirrel is found by its framework") {
            let root = temporaryDirectory("apps")
            defer { try? FileManager.default.removeItem(at: root) }
            let app = makeApp(in: root, name: "Chatty", identifier: "com.example.chatty") {
                makeDirectory($0.appendingPathComponent("Frameworks/Squirrel.framework"))
            }
            let finding = UpdaterScan.inspect(bundleAt: app)
            Check.expectEqual(finding?.mechanism, .squirrel)
            Check.expectEqual(finding?.bundleIdentifier, "com.example.chatty")
            Check.expectEqual(finding?.displayName, "Chatty")
        }

        Check.test("electron-updater is found by its config, with its cache directory") {
            let root = temporaryDirectory("apps")
            defer { try? FileManager.default.removeItem(at: root) }
            // Granola's file, verbatim.
            let granola = makeApp(in: root, name: "Granola", identifier: "com.granola.app") {
                makeFile($0.appendingPathComponent("Resources/app-update.yml"), text: """
                    owner: granola-inc
                    repo: granola-electron
                    provider: github
                    updaterCacheDirName: '@granolaelectron-updater'
                    """)
                makeDirectory($0.appendingPathComponent("Frameworks/Squirrel.framework"))
            }
            let finding = UpdaterScan.inspect(bundleAt: granola)
            Check.expectEqual(finding?.mechanism, .electronUpdater)
            Check.expectEqual(finding?.updaterCacheDirName, "@granolaelectron-updater")

            // Synergy's, unquoted.
            let synergy = makeApp(in: root, name: "Synergy", identifier: "com.symless.synergy") {
                makeFile($0.appendingPathComponent("Resources/app-update.yml"),
                         text: "provider: github\nupdaterCacheDirName: synergy-updater\n")
            }
            Check.expectEqual(UpdaterScan.inspect(bundleAt: synergy)?.updaterCacheDirName,
                              "synergy-updater")
        }

        Check.test("a cache directory that would leave Caches is refused") {
            let root = temporaryDirectory("apps")
            defer { try? FileManager.default.removeItem(at: root) }
            for value in ["../../Documents", "a/b", "..", "''"] {
                let app = makeApp(in: root, name: "Odd\(abs(value.hashValue))",
                                  identifier: "com.example.odd") {
                    makeFile($0.appendingPathComponent("Resources/app-update.yml"),
                             text: "updaterCacheDirName: \(value)\n")
                }
                let finding = UpdaterScan.inspect(bundleAt: app)
                Check.expectEqual(finding?.mechanism, .electronUpdater, value)
                Check.expectNil(finding?.updaterCacheDirName, value)
            }
        }

        Check.test("an app's own updater is found by a runnable component") {
            let root = temporaryDirectory("apps")
            defer { try? FileManager.default.removeItem(at: root) }
            // The three shapes on the development machine: Opera's executable,
            // Raycast's LaunchAgent, Omni's framework.
            let opera = makeApp(in: root, name: "Opera", identifier: "com.operasoftware.Opera") {
                makeFile($0.appendingPathComponent("MacOS/opera_autoupdate"), executable: true)
            }
            let raycast = makeApp(in: root, name: "Raycast", identifier: "com.raycast.macos") {
                makeFile($0.appendingPathComponent("Library/LaunchAgents/Updater.plist"),
                         text: "<plist/>")
            }
            let omni = makeApp(in: root, name: "OmniDiskSweeper",
                               identifier: "com.omnigroup.OmniDiskSweeper") {
                makeDirectory($0.appendingPathComponent(
                    "Frameworks/OmniSoftwareUpdate.framework"))
            }
            for app in [opera, raycast, omni] {
                Check.expectEqual(UpdaterScan.inspect(bundleAt: app)?.mechanism,
                                  .ownUpdater, app.lastPathComponent)
            }
        }

        Check.test("a picture named like an update is not an updater") {
            // Kindle ships `Resources/update.icns` — with its executable bit set,
            // as it is on the development machine, which is what once made the
            // scan report Kindle as having its own updater.
            let root = temporaryDirectory("apps")
            defer { try? FileManager.default.removeItem(at: root) }
            let kindle = makeApp(in: root, name: "Kindle", identifier: "com.amazon.Kindle") {
                makeFile($0.appendingPathComponent("Resources/update.icns"), bytes: 16,
                         executable: true)
            }
            Check.expectNil(UpdaterScan.inspect(bundleAt: kindle))
        }

        Check.test("an app with no updater is not reported") {
            let root = temporaryDirectory("apps")
            defer { try? FileManager.default.removeItem(at: root) }
            let plain = makeApp(in: root, name: "Plain", identifier: "com.example.plain") {
                makeFile($0.appendingPathComponent("MacOS/Plain"), executable: true)
            }
            Check.expectNil(UpdaterScan.inspect(bundleAt: plain))
        }

        Check.test("covered apps drop out, by identifier or by name") {
            func finding(_ name: String, _ identifier: String?) -> UpdaterScan.Finding {
                UpdaterScan.Finding(displayName: name, bundleIdentifier: identifier,
                                    bundlePath: "/Applications/\(name).app",
                                    mechanism: .squirrel)
            }
            let findings = [finding("Slack", "com.tinyspeck.slackmacgap"),
                            finding("Granola", "com.granola.app"),
                            finding("Canva", "com.canva.whatever")]
            let covered = [
                CoveredItem(id: "privileged/all", displayName: "Slack",
                            mechanism: "Managed policy", effect: "",
                            bundleIdentifiers: ["com.tinyspeck.slackmacgap"]),
                // The helper's Canva entry carries no identifier.
                CoveredItem(id: "privileged/all", displayName: "Canva",
                            mechanism: "Update endpoint", effect: ""),
            ]
            Check.expectEqual(UpdaterScan.uncovered(findings, by: covered).map(\.displayName),
                              ["Granola"])
        }

        // Settings shows these to people who have never heard of an updater
        // framework, so none of them may name one.
        Check.test("every reason an app can't be paused is in plain words") {
            let mechanisms: [UpdaterScan.Mechanism] =
                [.squirrel, .electronUpdater, .sparkle, .ownUpdater]
            for mechanism in mechanisms {
                let reason = mechanism.whyNotPaused
                Check.expectFalse(reason.isEmpty, mechanism.rawValue)
                for jargon in ["Squirrel", "electron", "Electron", "Sparkle", "sandbox"] {
                    Check.expectFalse(reason.contains(jargon), "\(mechanism.rawValue): \(reason)")
                }
            }
        }

        Check.test("updater process names are recognised without a list") {
            for name in ["GoogleUpdater", "opera_autoupdate", "softwareupdated",
                         "Microsoft AutoUpdate", "ShipIt", "UpdateBrainService"] {
                Check.expectTrue(UpdaterScan.looksLikeUpdater(name), name)
            }
            for name in ["Safari", "nsurlsessiond", "mDNSResponder", "Slack Helper",
                         "Google Chrome Helper"] {
                Check.expectFalse(UpdaterScan.looksLikeUpdater(name), name)
            }
        }

        Check.test("this Mac's apps scan without trouble") {
            // Not asserting what is installed — that is the point of the scan —
            // only that a real /Applications produces well-formed findings.
            for finding in UpdaterScan.findings() {
                Check.expectFalse(finding.displayName.isEmpty)
                Check.expectTrue(finding.bundlePath.hasSuffix(".app"), finding.bundlePath)
            }
        }
    }
}

// MARK: - UpdateCaches and UpdateWatch

func runUpdateWatchTests() {
    Check.suite("UpdateWatch") {

        Check.test("each framework's staging place is found, and says whose it is") {
            let caches = temporaryDirectory("caches")
            defer { try? FileManager.default.removeItem(at: caches) }
            makeFile(caches.appendingPathComponent(
                "com.anthropic.claudefordesktop.ShipIt/update.mQ5fIP5/Claude.app/x"), bytes: 4)
            makeFile(caches.appendingPathComponent(
                "com.anthropic.claudefordesktop.ShipIt/ShipItState.plist"), bytes: 4)
            makeFile(caches.appendingPathComponent(
                "@granolaelectron-updater/pending/Granola-7.668.0-mac-universal.zip"), bytes: 4)
            makeFile(caches.appendingPathComponent(
                "@granolaelectron-updater/pending/update-info.json"), bytes: 4)
            makeFile(caches.appendingPathComponent(
                "org.videolan.vlc/org.sparkle-project.Sparkle/PersistentDownloads/a/VLC.dmg"),
                bytes: 4)
            makeFile(caches.appendingPathComponent("com.example.unrelated/Cache.db"), bytes: 4)

            let owners = Set(UpdateCaches.payloads(in: caches).map(\.owner))
            Check.expectEqual(owners, [.bundle("com.anthropic.claudefordesktop"),
                                       .electronCache("@granolaelectron-updater"),
                                       .bundle("org.videolan.vlc")])
            Check.expectEqual(UpdateCaches.payloads(in: caches).count, 3,
                              "state files, update-info.json and unrelated caches are not payloads")
        }

        func makeWatch(caches: URL, defaults: UserDefaults) -> UpdateWatch {
            UpdateWatch(cachesDirectory: caches, defaults: defaults) { owner in
                switch owner {
                case .bundle(let id): return id == "com.granola.app" ? "Granola" : id
                case .electronCache: return "Granola"
                }
            }
        }

        func freshDefaults() -> UserDefaults {
            UserDefaults(suiteName: "netmon.tests.\(UUID().uuidString)")!
        }

        Check.test("a download that lands while metered is reported, with its size") {
            let caches = temporaryDirectory("caches")
            defer { try? FileManager.default.removeItem(at: caches) }
            // Already there before the hotspot: not this connection's cost.
            makeFile(caches.appendingPathComponent("old-updater/pending/old.zip"),
                     bytes: 3_000_000)

            let watch = makeWatch(caches: caches, defaults: freshDefaults())
            watch.begin(networkID: "gw:hotspot", now: Date().addingTimeInterval(-60))
            makeFile(caches.appendingPathComponent(
                "@granolaelectron-updater/pending/Granola.zip"), bytes: 2_000_000)
            watch.scan()

            Check.expectEqual(watch.reportable.map(\.name), ["Granola"])
            Check.expectEqual(watch.reportable.first?.bytes, 2_000_000)
            Check.expectEqual(watch.reportable.first?.source, .download)
        }

        Check.test("something too small to be an update is not reported") {
            let caches = temporaryDirectory("caches")
            defer { try? FileManager.default.removeItem(at: caches) }
            let watch = makeWatch(caches: caches, defaults: freshDefaults())
            watch.begin(networkID: "gw:hotspot", now: Date().addingTimeInterval(-60))
            makeFile(caches.appendingPathComponent("tiny-updater/pending/tiny.zip"),
                     bytes: 10_000)
            watch.scan()
            Check.expectTrue(watch.reportable.isEmpty)
        }

        Check.test("updater traffic accumulates and reports when it crosses the line") {
            let watch = makeWatch(caches: temporaryDirectory("caches"),
                                  defaults: freshDefaults())
            watch.begin(networkID: "gw:hotspot")
            Check.expectFalse(watch.recordTraffic(processName: "GoogleUpdater",
                                                  appName: "Google Chrome", bytes: 600_000))
            Check.expectTrue(watch.recordTraffic(processName: "GoogleUpdater",
                                                 appName: "Google Chrome", bytes: 600_000),
                             "crossing the threshold is the moment to publish")
            Check.expectFalse(watch.recordTraffic(processName: "GoogleUpdater",
                                                  appName: "Google Chrome", bytes: 600_000))
            let sighting = watch.reportable.first
            Check.expectEqual(sighting?.bytes, 1_800_000)
            Check.expectEqual(sighting?.app, "Google Chrome")

            watch.recordTraffic(processName: "softwareupdated",
                                appName: "softwareupdated", bytes: 5_000_000)
            Check.expectNil(watch.reportable.first { $0.name == "softwareupdated" }?.app,
                            "no point naming the app when it is the process")
        }

        Check.test("nothing is counted when no metered connection is being watched") {
            let watch = makeWatch(caches: temporaryDirectory("caches"),
                                  defaults: freshDefaults())
            Check.expectFalse(watch.recordTraffic(processName: "GoogleUpdater",
                                                  appName: nil, bytes: 5_000_000))
            Check.expectTrue(watch.sightings.isEmpty)
        }

        Check.test("a dropout keeps the report; leaving and coming back starts a new one") {
            let defaults = freshDefaults()
            let caches = temporaryDirectory("caches")
            defer { try? FileManager.default.removeItem(at: caches) }
            let watch = makeWatch(caches: caches, defaults: defaults)
            watch.begin(networkID: "gw:hotspot")
            watch.recordTraffic(processName: "GoogleUpdater", appName: nil, bytes: 2_000_000)

            watch.begin(networkID: "gw:hotspot")
            Check.expectEqual(watch.reportable.count, 1, "the same connection, still going")

            watch.end()
            Check.expectEqual(watch.reportable.count, 1, "kept for whoever looks at home")

            watch.begin(networkID: "gw:hotspot")
            Check.expectTrue(watch.reportable.isEmpty, "a new session on the same hotspot")
        }

        Check.test("relaunching mid-hotspot carries the report on") {
            let defaults = freshDefaults()
            let caches = temporaryDirectory("caches")
            defer { try? FileManager.default.removeItem(at: caches) }
            let first = makeWatch(caches: caches, defaults: defaults)
            first.begin(networkID: "gw:hotspot")
            first.recordTraffic(processName: "GoogleUpdater", appName: nil, bytes: 2_000_000)
            first.tick(now: Date().addingTimeInterval(UpdateWatch.scanInterval + 1))

            let second = makeWatch(caches: caches, defaults: defaults)
            Check.expectEqual(second.reportable.count, 1, "persisted")
            second.begin(networkID: "gw:hotspot")
            Check.expectEqual(second.reportable.count, 1,
                              "the app quitting is not the connection ending")
            second.begin(networkID: "gw:other-hotspot")
            Check.expectTrue(second.reportable.isEmpty)
        }

        Check.test("the caches are looked at no more often than the interval") {
            let watch = makeWatch(caches: temporaryDirectory("caches"),
                                  defaults: freshDefaults())
            let start = Date()
            watch.begin(networkID: "gw:hotspot", now: start)
            Check.expectFalse(watch.tick(now: start.addingTimeInterval(1)))
            Check.expectTrue(watch.tick(now: start.addingTimeInterval(UpdateWatch.scanInterval)))
            Check.expectFalse(watch.tick(now: start.addingTimeInterval(UpdateWatch.scanInterval + 1)))
        }
    }
}
