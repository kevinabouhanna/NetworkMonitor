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

        // #92: Chrome's only updater component is a privileged helper tool,
        // named by reverse DNS, so its name has a dot in it and no extension.
        Check.test("a privileged helper tool named like an updater is found") {
            let root = temporaryDirectory("apps")
            defer { try? FileManager.default.removeItem(at: root) }
            let chrome = makeApp(in: root, name: "Google Chrome",
                                 identifier: "com.google.Chrome") {
                makeFile($0.appendingPathComponent(
                    "Library/LaunchServices/com.google.Chrome.UpdaterPrivilegedHelper"),
                         executable: true)
            }
            Check.expectEqual(UpdaterScan.inspect(bundleAt: chrome)?.mechanism, .ownUpdater)

            // Not runnable, not an updater, wherever it sits.
            let inert = makeApp(in: root, name: "Inert", identifier: "com.example.inert") {
                makeFile($0.appendingPathComponent(
                    "Library/LaunchServices/com.example.Inert.UpdaterNotes"))
            }
            Check.expectNil(UpdaterScan.inspect(bundleAt: inert))
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
                case .bundle(let id): return .init(name: id == "com.granola.app" ? "Granola" : id)
                case .electronCache: return .init(name: "Granola", bundlePath: "/Applications/Granola.app")
                }
            }
        }

        func freshDefaults() -> UserDefaults {
            UserDefaults(suiteName: "netmon.tests.\(UUID().uuidString)")!
        }

        Check.test("a download whose app's traffic wasn't seen is reported by its size, as at most") {
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
            Check.expectTrue(watch.reportable.first?.isUpperBound ?? false)
        }

        // #95: Slack's update read 271.6 MB, its unpacked size on disk, when
        // Slack used about 120 MB of the hotspot in that hour.
        Check.test("a download is reported by what its app used while it downloaded") {
            let caches = temporaryDirectory("caches")
            defer { try? FileManager.default.removeItem(at: caches) }
            let watch = makeWatch(caches: caches, defaults: freshDefaults())
            let joined = Date().addingTimeInterval(-20 * 60)
            watch.begin(networkID: "gw:hotspot", now: joined)
            // Ordinary use, ten minutes before the download began.
            watch.recordApp(bundlePath: "/Applications/Granola.app", bytes: 5_000_000,
                            now: joined.addingTimeInterval(5 * 60))
            makeFile(caches.appendingPathComponent(
                "@granolaelectron-updater/pending/Granola.zip"), bytes: 3_000_000)
            let written = UpdateCaches.payloads(in: caches)[0].modified
            watch.recordApp(bundlePath: "/Applications/Granola.app", bytes: 1_500_000, now: written)
            // Another app's traffic at the same moment.
            watch.recordApp(bundlePath: "/Applications/Slack.app", bytes: 9_000_000, now: written)
            watch.scan()

            Check.expectEqual(watch.reportable.first?.bytes, 1_500_000)
            Check.expectFalse(watch.reportable.first?.isUpperBound ?? true)
        }

        Check.test("a measurement replaces a size on disk, and then only grows") {
            let caches = temporaryDirectory("caches")
            defer { try? FileManager.default.removeItem(at: caches) }
            let watch = makeWatch(caches: caches, defaults: freshDefaults())
            watch.begin(networkID: "gw:hotspot", now: Date().addingTimeInterval(-60))
            makeFile(caches.appendingPathComponent(
                "@granolaelectron-updater/pending/Granola.zip"), bytes: 3_000_000)
            watch.scan()
            Check.expectTrue(watch.reportable.first?.isUpperBound ?? false)

            let written = UpdateCaches.payloads(in: caches)[0].modified
            watch.recordApp(bundlePath: "/Applications/Granola.app", bytes: 1_200_000, now: written)
            watch.scan()
            Check.expectEqual(watch.reportable.first?.bytes, 1_200_000)
            Check.expectFalse(watch.reportable.first?.isUpperBound ?? true)
            Check.expectEqual(watch.sightings.count, 1)
        }

        Check.test("app traffic isn't counted when no metered connection is being watched") {
            let caches = temporaryDirectory("caches")
            defer { try? FileManager.default.removeItem(at: caches) }
            let watch = makeWatch(caches: caches, defaults: freshDefaults())
            // Seen before the watch began, and stamped in the download's minute.
            watch.recordApp(bundlePath: "/Applications/Granola.app", bytes: 5_000_000, now: Date())
            watch.begin(networkID: "gw:hotspot", now: Date().addingTimeInterval(-60))
            makeFile(caches.appendingPathComponent(
                "@granolaelectron-updater/pending/Granola.zip"), bytes: 3_000_000)
            watch.scan()
            Check.expectEqual(watch.reportable.first?.bytes, 3_000_000)
            Check.expectTrue(watch.reportable.first?.isUpperBound ?? false)
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

// MARK: - UpdateFolderSuppressor

/// Permission bits of a folder, or nil if there is none.
private func mode(of url: URL) -> Int? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    return Int(info.st_mode & 0o7777)
}

func runUpdateFolderSuppressorTests() {
    Check.suite("UpdateFolderSuppressor") {

        let slack = UpdaterScan.Finding(displayName: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap",
                                        bundlePath: "/Applications/Slack.app", mechanism: .squirrel)
        let granola = UpdaterScan.Finding(displayName: "Granola", bundleIdentifier: "com.granola.app",
                                          bundlePath: "/Applications/Granola.app",
                                          mechanism: .electronUpdater,
                                          updaterCacheDirName: "@granolaelectron-updater")

        /// A scratch caches folder, a journal in it, and a suppressor over both.
        func scratch(_ findings: [UpdaterScan.Finding])
            -> (UpdateFolderSuppressor, SuppressionJournal, URL) {
            let caches = temporaryDirectory("caches")
            let journal = SuppressionJournal(url: caches.appendingPathComponent("journal.json"))
            return (UpdateFolderSuppressor(cachesDirectory: caches, findings: { findings }),
                    journal, caches)
        }
        func cleanUp(_ caches: URL) {
            // Locked folders inside would make removing the scratch folder fail.
            let walker = FileManager.default.enumerator(atPath: caches.path)
            while let entry = walker?.nextObject() as? String {
                chmod(caches.appendingPathComponent(entry).path, 0o755)
            }
            try? FileManager.default.removeItem(at: caches)
        }

        Check.test("each updater's download folder is found, without a list of apps") {
            let caches = temporaryDirectory("caches")
            defer { cleanUp(caches) }
            makeDirectory(caches.appendingPathComponent("@granolaelectron-updater/pending"))
            let sparkle = UpdaterScan.Finding(displayName: "VLC", bundleIdentifier: "org.videolan.vlc",
                                              bundlePath: "/Applications/VLC.app", mechanism: .sparkle)
            let unnamed = UpdaterScan.Finding(displayName: "Mystery", bundleIdentifier: "com.example.mystery",
                                              bundlePath: "/Applications/Mystery.app",
                                              mechanism: .electronUpdater)
            let folders = UpdateFolderSuppressor.folders(for: [slack, granola, sparkle, unnamed], in: caches)
            Check.expectEqual(folders.map { $0.path.replacingOccurrences(of: caches.path + "/", with: "") },
                              ["com.tinyspeck.slackmacgap.ShipIt",
                               "@granolaelectron-updater",
                               "@granolaelectron-updater/pending"])
        }

        // Nothing is left to download, and Squirrel's installer works in there.
        Check.test("a folder already holding a downloaded update is left alone") {
            let caches = temporaryDirectory("caches")
            defer { cleanUp(caches) }
            makeDirectory(caches.appendingPathComponent("com.tinyspeck.slackmacgap.ShipIt/update.PNJHfZu/Slack.app"))
            Check.expectTrue(UpdateFolderSuppressor.folders(for: [slack], in: caches).isEmpty)
        }

        Check.test("a folder is locked while metered and put back exactly after") {
            let (suppressor, journal, caches) = scratch([slack])
            defer { cleanUp(caches) }
            let shipIt = caches.appendingPathComponent("com.tinyspeck.slackmacgap.ShipIt")
            makeDirectory(shipIt)
            chmod(shipIt.path, 0o750)

            let result = suppressor.apply(journal: journal, excluding: [])
            Check.expectEqual(result.applied, ["Slack"])
            Check.expectEqual(mode(of: shipIt), 0o550)
            suppressor.revert(journal: journal)
            Check.expectEqual(mode(of: shipIt), 0o750)
            Check.expectTrue(journal.isEmpty)
        }

        // What Squirrel does first, and what the lock exists to make fail.
        Check.test("while locked, an update folder can't be made in it") {
            let (suppressor, journal, caches) = scratch([slack])
            defer { cleanUp(caches) }
            let shipIt = caches.appendingPathComponent("com.tinyspeck.slackmacgap.ShipIt")
            func mkdtempWorks() -> Bool {
                var template = Array(shipIt.appendingPathComponent("update.XXXXXXX").path.utf8CString)
                guard let made = mkdtemp(&template) else { return false }
                rmdir(made)
                return true
            }
            makeDirectory(shipIt)
            Check.expectTrue(mkdtempWorks())
            suppressor.apply(journal: journal, excluding: [])
            Check.expectFalse(mkdtempWorks())
            suppressor.revert(journal: journal)
            Check.expectTrue(mkdtempWorks())
        }

        Check.test("a folder that isn't there yet is made read-only, then removed") {
            let (suppressor, journal, caches) = scratch([slack, granola])
            defer { cleanUp(caches) }
            suppressor.apply(journal: journal, excluding: [])
            let shipIt = caches.appendingPathComponent("com.tinyspeck.slackmacgap.ShipIt")
            let electron = caches.appendingPathComponent("@granolaelectron-updater")
            Check.expectEqual(mode(of: shipIt), 0o555)
            Check.expectEqual(mode(of: electron), 0o555)
            Check.expectNil(mode(of: caches.appendingPathComponent("com.granola.app.ShipIt")))
            // electron-updater's first step, refused.
            Check.expectNil(try? FileManager.default.createDirectory(
                at: electron.appendingPathComponent("pending"), withIntermediateDirectories: true))
            suppressor.revert(journal: journal)
            Check.expectNil(mode(of: shipIt))
            Check.expectNil(mode(of: electron))
        }

        Check.test("a folder already read-only is left exactly as it was") {
            let (suppressor, journal, caches) = scratch([slack])
            defer { cleanUp(caches) }
            let shipIt = caches.appendingPathComponent("com.tinyspeck.slackmacgap.ShipIt")
            makeDirectory(shipIt)
            chmod(shipIt.path, 0o500)
            Check.expectTrue(suppressor.apply(journal: journal, excluding: []).applied.isEmpty)
            Check.expectTrue(journal.isEmpty)
            suppressor.revert(journal: journal)
            Check.expectEqual(mode(of: shipIt), 0o500)
        }

        Check.test("a symlink is never followed") {
            let (suppressor, journal, caches) = scratch([slack])
            defer { cleanUp(caches) }
            let elsewhere = caches.appendingPathComponent("elsewhere")
            makeDirectory(elsewhere)
            try? FileManager.default.createSymbolicLink(
                at: caches.appendingPathComponent("com.tinyspeck.slackmacgap.ShipIt"),
                withDestinationURL: elsewhere)
            suppressor.apply(journal: journal, excluding: [])
            Check.expectEqual(mode(of: elsewhere), 0o755)
            Check.expectTrue(journal.isEmpty)
        }

        Check.test("a mode changed by someone else after the lock is theirs") {
            let (suppressor, journal, caches) = scratch([slack])
            defer { cleanUp(caches) }
            let shipIt = caches.appendingPathComponent("com.tinyspeck.slackmacgap.ShipIt")
            makeDirectory(shipIt)
            suppressor.apply(journal: journal, excluding: [])
            chmod(shipIt.path, 0o700)
            suppressor.revert(journal: journal)
            Check.expectEqual(mode(of: shipIt), 0o700)
            Check.expectTrue(journal.isEmpty)
        }

        Check.test("switched off, it locks nothing") {
            let (suppressor, journal, caches) = scratch([slack])
            defer { cleanUp(caches) }
            let result = suppressor.apply(journal: journal, excluding: [UpdateFolderSuppressor.tierID])
            Check.expectTrue(result.isEmpty)
            Check.expectNil(mode(of: caches.appendingPathComponent("com.tinyspeck.slackmacgap.ShipIt")))
        }

        Check.test("each app is listed once, under one switch") {
            let (suppressor, _, caches) = scratch([slack, granola])
            defer { cleanUp(caches) }
            let items = suppressor.discover()
            Check.expectEqual(items.map(\.displayName), ["Slack", "Granola"])
            Check.expectEqual(Set(items.map(\.id)), [UpdateFolderSuppressor.tierID])
            Check.expectEqual(items.map(\.bundleIdentifiers),
                              [["com.tinyspeck.slackmacgap"], ["com.granola.app"]])
        }

        // The journal is the user's own file, so a path in it is checked
        // before anything is changed from it.
        Check.test("a journal entry outside the caches folder is never acted on") {
            let (suppressor, journal, caches) = scratch([])
            defer { cleanUp(caches) }
            let outside = temporaryDirectory("outside")
            defer { try? FileManager.default.removeItem(at: outside) }
            chmod(outside.path, 0o555)
            try? journal.record(SuppressionRecord(target: .folder(path: outside.path, app: "X"),
                                                  priorValue: .int(0o777), appliedValue: .int(0o555)))
            suppressor.revert(journal: journal)
            Check.expectEqual(mode(of: outside), 0o555)
            chmod(outside.path, 0o755)
        }

        Check.test("a folder record survives the journal being read back") {
            let (_, journal, caches) = scratch([])
            defer { cleanUp(caches) }
            let target = SuppressionRecord.Target.folder(path: "/x/y.ShipIt", app: "Slack")
            try? journal.record(SuppressionRecord(target: target, priorValue: .absent,
                                                  appliedValue: .int(0o555)))
            let reread = SuppressionJournal(url: caches.appendingPathComponent("journal.json"))
            Check.expectEqual(reread.record(for: target)?.appliedValue, .int(0o555))
        }
    }
}
