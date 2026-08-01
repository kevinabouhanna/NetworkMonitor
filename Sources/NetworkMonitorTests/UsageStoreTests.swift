import Foundation
import NetworkMonitorCore

func runAppIdentityTests() {
    Check.suite("AppIdentityResolver") {

        // The reason helper collapsing works: the *outermost* .app in the path is
        // the app the user recognises. Chrome runs a dozen helpers, all reported
        // by nettop as the truncated "Google Chrome H" with distinct pids.
        Check.test("collapses a helper into its parent app") {
            let path = "/Applications/Google Chrome.app/Contents/Frameworks/"
                + "Google Chrome Framework.framework/Versions/151.0.7922.47/Helpers/"
                + "Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
            let identity = AppIdentityResolver.identity(forExecutablePath: path,
                                                       fallbackName: "Google Chrome H")
            Check.expectEqual(identity.bundlePath, "/Applications/Google Chrome.app")
            Check.expectFalse(identity.isSystem)
        }

        // All helpers must share one accumulation key, otherwise Chrome appears
        // as a dozen separate rows.
        Check.test("all helpers share one accumulation key") {
            let base = "/Applications/Google Chrome.app/Contents/Frameworks/"
                + "Google Chrome Framework.framework/Versions/151.0.7922.47/Helpers/"
            let renderer = AppIdentityResolver.identity(
                forExecutablePath: base + "Google Chrome Helper (Renderer).app/Contents/MacOS/x",
                fallbackName: "Google Chrome H")
            let gpu = AppIdentityResolver.identity(
                forExecutablePath: base + "Google Chrome Helper (GPU).app/Contents/MacOS/y",
                fallbackName: "Google Chrome H")
            let main = AppIdentityResolver.identity(
                forExecutablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                fallbackName: "Google Chrome")
            Check.expectEqual(renderer.key, gpu.key)
            Check.expectEqual(renderer.key, main.key)
        }

        // Daemons have no bundle and must be flagged so they collapse into the
        // System group — mDNSResponder measured 251 MB against a 6 MB top app.
        Check.test("daemons are flagged as system processes") {
            for path in ["/usr/sbin/mDNSResponder",
                         "/System/Library/PrivateFrameworks/ApplePushService.framework/apsd",
                         "/sbin/launchd"] {
                let identity = AppIdentityResolver.identity(forExecutablePath: path,
                                                           fallbackName: "x")
                Check.expectTrue(identity.isSystem, "\(path) should be a system process")
                Check.expectNil(identity.bundlePath)
            }
            Check.expectEqual(
                AppIdentityResolver.identity(forExecutablePath: "/usr/sbin/mDNSResponder",
                                             fallbackName: "x").displayName,
                "mDNSResponder")
        }

        // pid 0 (kernel_task) has no resolvable path and must not crash.
        Check.test("kernel_task has no resolvable path") {
            Check.expectNil(AppIdentityResolver.executablePath(pid: 0))
        }

        // Verified live: unprivileged proc_pidpath resolves root-owned processes,
        // which is what makes daemon attribution possible without elevation.
        Check.test("resolves this process's own path") {
            let path = AppIdentityResolver.executablePath(pid: getpid())
            Check.expectNotNil(path)
            Check.expectTrue(path?.hasPrefix("/") == true)
        }

        Check.test("resolves launchd, a root-owned process, unprivileged") {
            Check.expectEqual(AppIdentityResolver.executablePath(pid: 1), "/sbin/launchd")
        }
    }
}

func runUsageStoreTests() {
    func temporaryURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("usage-test-\(UUID().uuidString).json")
    }

    func network(_ id: String, expensive: Bool = false) -> NetworkFingerprint {
        NetworkFingerprint(id: id, kind: expensive ? .hotspot : .wifi,
                           gatewayMAC: id, defaultLabel: id,
                           isExpensive: expensive, isConstrained: false)
    }

    func identity(_ name: String, isSystem: Bool = false) -> AppIdentity {
        AppIdentity(key: name, displayName: name,
                    bundlePath: isSystem ? nil : "/Applications/\(name).app",
                    isSystem: isSystem)
    }

    func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    Check.suite("UsageStore — accumulation") {

        Check.test("accumulates interface bytes") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = UsageStore(storeURL: url)
            store.setCurrentNetwork(network("home"))
            store.recordInterface(bytesIn: 1000, bytesOut: 200)
            store.recordInterface(bytesIn: 500, bytesOut: 100)
            Check.expectEqual(store.currentBucket.interfaceBytesIn, 1500)
            Check.expectEqual(store.currentBucket.interfaceBytesOut, 300)
        }

        Check.test("accumulates per-app totals") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = UsageStore(storeURL: url)
            store.setCurrentNetwork(network("home"))
            store.recordApps([(identity("Chrome"), 100, 10), (identity("Slack"), 50, 5)])
            store.recordApps([(identity("Chrome"), 25, 5)])
            Check.expectEqual(store.currentBucket.apps["Chrome"]?.bytesIn, 125)
            Check.expectEqual(store.currentBucket.apps["Chrome"]?.bytesOut, 15)
            Check.expectEqual(store.currentBucket.apps["Slack"]?.total, 55)
        }

        // Traffic arriving before the path monitor has classified the link must
        // be recorded somewhere rather than dropped.
        Check.test("traffic recorded while offline is not lost") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = UsageStore(storeURL: url)
            store.recordInterface(bytesIn: 700, bytesOut: 300)
            Check.expectEqual(store.currentBucket.interfaceTotal, 1000)
        }

        // The path monitor is debounced 2 s, so the first traffic after launch
        // lands in the placeholder bucket. It must be folded into the real
        // network rather than stranded in a permanent "No Connection" entry.
        Check.test("startup traffic folds into the network once identified") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = UsageStore(storeURL: url)
            store.recordInterface(bytesIn: 12_288, bytesOut: 11_264)
            store.recordApps([(identity("Chrome"), 5000, 400)])

            store.setCurrentNetwork(network("home"))

            Check.expectEqual(store.currentBucket.interfaceBytesIn, 12_288,
                              "pre-identification bytes must transfer")
            Check.expectEqual(store.currentBucket.interfaceBytesOut, 11_264)
            Check.expectEqual(store.currentBucket.apps["Chrome"]?.bytesIn, 5000)
            Check.expectNil(store.allNetworks().first { $0.id == "offline" },
                            "placeholder bucket must not linger in the network list")
        }

        // Folding must add to, not overwrite, totals the network already has.
        Check.test("folding merges rather than replaces existing totals") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = UsageStore(storeURL: url)
            store.setCurrentNetwork(network("home"))
            store.recordInterface(bytesIn: 1000, bytesOut: 100)
            store.recordApps([(identity("Chrome"), 900, 90)])

            store.setCurrentNetwork(.offline)              // link drops
            store.recordInterface(bytesIn: 50, bytesOut: 5)
            store.recordApps([(identity("Chrome"), 40, 4)])
            store.setCurrentNetwork(network("home"))       // and returns

            Check.expectEqual(store.currentBucket.interfaceBytesIn, 1050)
            Check.expectEqual(store.currentBucket.interfaceBytesOut, 105)
            Check.expectEqual(store.currentBucket.apps["Chrome"]?.bytesIn, 940)
        }
    }

    Check.suite("UsageStore — per-network buckets") {

        // The headline requirement: dropping off a network and rejoining it must
        // NOT reset that network's total.
        Check.test("rejoining the same network preserves its total") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = UsageStore(storeURL: url)
            store.setCurrentNetwork(network("home"))
            store.recordInterface(bytesIn: 5000, bytesOut: 1000)

            store.setCurrentNetwork(.offline)          // Wi-Fi drops
            store.setCurrentNetwork(network("home"))   // and comes back

            Check.expectEqual(store.currentBucket.interfaceBytesIn, 5000,
                              "reconnecting to the same network must not reset it")
        }

        // Each network counts on its own, and the one in front of the user always
        // counts from the moment the connection was made.
        Check.test("switching networks keeps separate totals") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = UsageStore(storeURL: url)
            store.setCurrentNetwork(network("home"))
            store.recordInterface(bytesIn: 5000, bytesOut: 1000)

            store.setCurrentNetwork(network("hotspot", expensive: true))
            Check.expectEqual(store.currentBucket.interfaceBytesIn, 0, "new network starts fresh")
            store.recordInterface(bytesIn: 200, bytesOut: 50)
            Check.expectEqual(store.currentBucket.interfaceBytesIn, 200,
                              "the other network's bytes must not leak in")
        }

        // Hotspot usage must be independently readable — the basis for the
        // planned "limit app updates on hotspot" feature.
        Check.test("hotspot total is queryable while on another network") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = UsageStore(storeURL: url)
            store.setCurrentNetwork(network("hotspot", expensive: true))
            store.recordInterface(bytesIn: 4_000_000, bytesOut: 500_000)
            store.setCurrentNetwork(network("home"))

            let hotspot = store.allNetworks().first { $0.id == "hotspot" }
            Check.expectEqual(hotspot?.bucket.interfaceTotal, 4_500_000)
            Check.expectEqual(hotspot?.bucket.kind, .hotspot)
        }
    }

    Check.suite("UsageStore — internet versus local") {

        // The headline comes from kernel interface counters, which cannot tell a
        // mirrored screen from a download. Subtracting what nettop proved was local
        // is what makes the number mean "internet".
        Check.test("local bytes are subtracted from the headline") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = UsageStore(storeURL: url)
            store.setCurrentNetwork(network("home"))
            // 4 GB of mirroring plus 100 MB of real browsing, as the kernel sees it.
            store.recordInterface(bytesIn: 4_100_000_000, bytesOut: 50_000_000)
            store.recordApps([(identity("Safari"), 100_000_000, 5_000_000)],
                             localBytesIn: 4_000_000_000, localBytesOut: 45_000_000)

            Check.expectEqual(store.currentBucket.interfaceTotal, 4_150_000_000,
                              "the raw kernel figure must stay intact underneath")
            Check.expectEqual(store.currentBucket.internetBytesIn, 100_000_000)
            Check.expectEqual(store.currentBucket.internetBytesOut, 5_000_000)
        }

        // Two different sources, so the subtraction can overshoot. It must never
        // produce a negative usage figure.
        Check.test("over-subtraction floors at zero") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = UsageStore(storeURL: url)
            store.setCurrentNetwork(network("home"))
            store.recordInterface(bytesIn: 1000, bytesOut: 1000)
            store.recordApps([], localBytesIn: 99_999, localBytesOut: 99_999)
            Check.expectEqual(store.currentBucket.internetTotal, 0)
        }

        // The real failure this guards, measured live before it was fixed:
        // mDNSResponder's multicast socket is multi-homed, so nettop bills its
        // bytes to every interface type it matches and the reported local figure
        // exceeds what crossed the wire. Subtracting it blindly left a headline
        // *smaller than the rows beneath it*.
        Check.test("the headline never falls below the rows it contains") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = UsageStore(storeURL: url)
            store.setCurrentNetwork(network("home"))
            store.recordInterface(bytesIn: 1_702_000, bytesOut: 0)
            store.recordApps([(identity("Chrome"), 1_174_000, 0)],
                             localBytesIn: 1_335_000, localBytesOut: 0)

            let bucket = store.currentBucket
            Check.expectTrue(bucket.internetBytesIn >= bucket.attributedBytesIn,
                             "headline \(bucket.internetBytesIn) < rows \(bucket.attributedBytesIn)")
            Check.expectEqual(bucket.internetBytesIn, 1_174_000)
        }

        // And the other end of the clamp: rows can over-report too (headers,
        // multi-homed sockets), but the headline can never exceed what the kernel
        // actually counted.
        Check.test("the headline never exceeds the kernel's own count") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = UsageStore(storeURL: url)
            store.setCurrentNetwork(network("home"))
            store.recordInterface(bytesIn: 1000, bytesOut: 0)
            store.recordApps([(identity("Chrome"), 9_000_000, 0)])
            Check.expectEqual(store.currentBucket.internetBytesIn, 1000)
        }

        // A mirroring session must not leave an app row behind either.
        Check.test("a purely local app never becomes a row") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = UsageStore(storeURL: url)
            store.setCurrentNetwork(network("home"))
            store.recordApps([], localBytesIn: 4_000_000, localBytesOut: 1_000_000)
            Check.expectTrue(store.currentBucket.apps.isEmpty)
            Check.expectEqual(store.currentBucket.localBytesIn, 4_000_000)
        }

        Check.test("local totals reset and persist like everything else") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = UsageStore(storeURL: url)
            store.setCurrentNetwork(network("home"))
            store.recordApps([], localBytesIn: 5000, localBytesOut: 500)
            store.save()

            let reopened = UsageStore(storeURL: url)
            reopened.setCurrentNetwork(network("home"))
            Check.expectEqual(reopened.currentBucket.localBytesIn, 5000)
            reopened.resetCurrentNetwork()
            Check.expectEqual(reopened.currentBucket.localBytesIn, 0)
            Check.expectEqual(reopened.currentBucket.localBytesOut, 0)
        }
    }

    Check.suite("UsageStore — reset on connection change") {

        // The headline requirement of this behaviour: open a hotspot somewhere
        // new and the per-app figures describe *that* session, not the day.
        Check.test("joining a different network zeroes every app") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = UsageStore(storeURL: url)
            store.setCurrentNetwork(network("home"))
            store.recordInterface(bytesIn: 5000, bytesOut: 1000)
            store.recordApps([(identity("Chrome"), 4000, 800), (identity("Slack"), 900, 90)])

            Check.expectTrue(store.setCurrentNetwork(network("hotspot", expensive: true)),
                             "a different network must report a reset")
            Check.expectEqual(store.currentBucket.interfaceTotal, 0)
            Check.expectTrue(store.currentBucket.apps.isEmpty, "app rows must be cleared")
        }

        // A network with usage history is no exception — mid-day, and without
        // waiting for midnight.
        Check.test("returning to a known network restarts it from zero") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = UsageStore(storeURL: url)
            store.setCurrentNetwork(network("home"))
            store.recordInterface(bytesIn: 5000, bytesOut: 1000)
            store.recordApps([(identity("Chrome"), 4000, 800)])

            store.setCurrentNetwork(network("hotspot", expensive: true))
            store.recordInterface(bytesIn: 200, bytesOut: 50)
            store.setCurrentNetwork(network("home"))

            Check.expectEqual(store.currentBucket.interfaceTotal, 0,
                              "the earlier session on this network must not come back")
            Check.expectTrue(store.currentBucket.apps.isEmpty)
        }

        // An offline gap is a blip, not a place. Were it treated as a switch, a
        // flaky link would zero the counter repeatedly.
        Check.test("an offline gap on the way back is not a switch") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = UsageStore(storeURL: url)
            store.setCurrentNetwork(network("home"))
            store.recordApps([(identity("Chrome"), 4000, 800)])

            Check.expectFalse(store.setCurrentNetwork(.offline), "going offline is not a switch")
            Check.expectFalse(store.setCurrentNetwork(network("home")),
                              "coming back to the same network is not a switch")
            Check.expectEqual(store.currentBucket.apps["Chrome"]?.total, 4800)
        }

        // The 2 s debounce means the first bytes of a new connection are recorded
        // before it is identified. The reset must not take those with it.
        Check.test("traffic recorded before the new network is known survives the reset") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = UsageStore(storeURL: url)
            store.setCurrentNetwork(network("home"))
            store.recordInterface(bytesIn: 9000, bytesOut: 900)

            store.setCurrentNetwork(.offline)                  // link drops
            store.recordInterface(bytesIn: 300, bytesOut: 30)  // now on the hotspot
            store.recordApps([(identity("Chrome"), 250, 25)])
            store.setCurrentNetwork(network("hotspot", expensive: true))

            Check.expectEqual(store.currentBucket.interfaceTotal, 330,
                              "pre-identification bytes belong to the network just joined")
            Check.expectEqual(store.currentBucket.apps["Chrome"]?.total, 275)
        }

        // Quitting is not switching networks. Restoring the day's totals on the
        // same network is the whole point of persisting them.
        Check.test("relaunching on the same network resumes its counter") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = UsageStore(storeURL: url)
            store.setCurrentNetwork(network("home"))
            store.recordInterface(bytesIn: 8192, bytesOut: 2048)
            store.save()

            let reopened = UsageStore(storeURL: url)
            Check.expectFalse(reopened.setCurrentNetwork(network("home")))
            Check.expectEqual(reopened.currentBucket.interfaceTotal, 10_240)
        }

        // Closing the lid at the office and opening it at home is a switch, even
        // though the app never saw the transition.
        Check.test("relaunching on a different network resets") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = UsageStore(storeURL: url)
            store.setCurrentNetwork(network("office"))
            store.recordInterface(bytesIn: 8192, bytesOut: 2048)
            store.save()

            let reopened = UsageStore(storeURL: url)
            Check.expectTrue(reopened.setCurrentNetwork(network("home")))
            Check.expectEqual(reopened.currentBucket.interfaceTotal, 0)
        }

        // "Counting since" is read next to the total, so it has to track the same
        // window the total covers.
        Check.test("counting-since follows the connection, not the day") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let calendar = utcCalendar()
            let store = UsageStore(storeURL: url, calendar: calendar)
            let today = calendar.startOfDay(for: Date())
            let joined = today.addingTimeInterval(11 * 3600)

            store.setCurrentNetwork(network("home"), now: today.addingTimeInterval(3600))
            store.setCurrentNetwork(network("hotspot", expensive: true), now: joined)
            Check.expectEqual(store.countingSince, joined)

            store.setCurrentNetwork(.offline, now: joined.addingTimeInterval(60))
            store.setCurrentNetwork(network("hotspot", expensive: true),
                                    now: joined.addingTimeInterval(120))
            Check.expectEqual(store.countingSince, joined,
                              "a blip must not restart the window")
        }
    }

    Check.suite("UsageStore — rollover and reset") {

        // Anchored to local midnight, not a rolling 86,400 s window that drifts.
        Check.test("rolls over when the local day advances") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let calendar = utcCalendar()
            let store = UsageStore(storeURL: url, calendar: calendar)
            store.setCurrentNetwork(network("home"))

            let today = calendar.startOfDay(for: Date())
            store.recordInterface(bytesIn: 9000, bytesOut: 900, now: today.addingTimeInterval(3600))
            Check.expectEqual(store.currentBucket.interfaceBytesIn, 9000)

            Check.expectTrue(store.rolloverIfNeeded(now: today.addingTimeInterval(86_460)))
            Check.expectEqual(store.currentBucket.interfaceBytesIn, 0)
            Check.expectTrue(store.currentBucket.apps.isEmpty)
        }

        Check.test("no rollover within the same day") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let calendar = utcCalendar()
            let store = UsageStore(storeURL: url, calendar: calendar)
            let today = calendar.startOfDay(for: Date())
            store.setCurrentNetwork(network("home"), now: today)
            store.recordInterface(bytesIn: 100, bytesOut: 100, now: today.addingTimeInterval(3600))
            Check.expectFalse(store.rolloverIfNeeded(now: today.addingTimeInterval(80_000)))
            Check.expectEqual(store.currentBucket.interfaceBytesIn, 100)
        }

        // Rollover must clear *every* network, not only the active one —
        // otherwise a network rejoined next week still shows last week's total.
        Check.test("rollover clears every bucket") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let calendar = utcCalendar()
            let store = UsageStore(storeURL: url, calendar: calendar)
            let today = calendar.startOfDay(for: Date())

            store.setCurrentNetwork(network("home"), now: today)
            store.recordInterface(bytesIn: 1000, bytesOut: 0, now: today)
            store.setCurrentNetwork(network("office"), now: today)
            store.recordInterface(bytesIn: 2000, bytesOut: 0, now: today)

            store.rolloverIfNeeded(now: today.addingTimeInterval(86_460))
            for entry in store.allNetworks() {
                Check.expectEqual(entry.bucket.interfaceTotal, 0, "\(entry.id) not cleared")
            }
        }

        Check.test("manual reset leaves other networks alone") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = UsageStore(storeURL: url)
            store.setCurrentNetwork(network("home"))
            store.recordInterface(bytesIn: 1000, bytesOut: 0)
            store.setCurrentNetwork(network("office"))
            store.recordInterface(bytesIn: 2000, bytesOut: 0)

            store.resetCurrentNetwork()
            Check.expectEqual(store.currentBucket.interfaceBytesIn, 0)
            Check.expectEqual(store.allNetworks().first { $0.id == "home" }?
                                   .bucket.interfaceBytesIn, 1000)
        }
    }

    Check.suite("UsageStore — persistence") {

        // Totals must survive relaunch, or a crash late in the day silently
        // discards the whole day.
        Check.test("persists across instances") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = UsageStore(storeURL: url)
            store.setCurrentNetwork(network("home"))
            store.recordApps([(identity("Chrome"), 4096, 1024)])
            store.recordInterface(bytesIn: 8192, bytesOut: 2048)
            store.save()

            let reopened = UsageStore(storeURL: url)
            reopened.setCurrentNetwork(network("home"))
            Check.expectEqual(reopened.currentBucket.interfaceBytesIn, 8192)
            Check.expectEqual(reopened.currentBucket.apps["Chrome"]?.bytesIn, 4096)
        }

        Check.test("custom labels persist and override the default") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = UsageStore(storeURL: url)
            store.setCurrentNetwork(network("home"))
            Check.expectEqual(store.currentLabel, "home")
            store.setLabel("Kevin's Wi-Fi", for: "home")
            Check.expectEqual(store.currentLabel, "Kevin's Wi-Fi")

            let reopened = UsageStore(storeURL: url)
            reopened.setCurrentNetwork(network("home"))
            Check.expectEqual(reopened.currentLabel, "Kevin's Wi-Fi")
        }

        Check.test("a blank label falls back to the default") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = UsageStore(storeURL: url)
            store.setCurrentNetwork(network("home"))
            store.setLabel("Renamed", for: "home")
            store.setLabel("   ", for: "home")
            Check.expectEqual(store.currentLabel, "home")
        }

        // Upgrading must not cost the user the day's totals. A store written
        // before per-connection counters has no `countingSince` and no
        // `lastNetworkID`, and synthesised decoding would reject it outright —
        // which the corrupt-store path would then turn into a wipe.
        Check.test("a store from before per-connection counters still loads") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let dayStart = Calendar.current.startOfDay(for: Date())
            let stamp = ISO8601DateFormatter().string(from: dayStart)
            let legacy = """
            {"dayStart":"\(stamp)","labels":{},"buckets":{"home":{\
            "interfaceBytesIn":8192,"interfaceBytesOut":2048,"apps":{},\
            "kind":"wifi","defaultLabel":"home","lastSeen":"\(stamp)"}}}
            """
            try? legacy.write(to: url, atomically: true, encoding: .utf8)

            let store = UsageStore(storeURL: url)
            store.setCurrentNetwork(network("home"))
            Check.expectEqual(store.currentBucket.interfaceTotal, 10_240,
                              "an upgrade must not discard the day")
            Check.expectEqual(store.countingSince, dayStart,
                              "old totals are the day's, so they count from midnight")
        }

        // A corrupt store must not prevent launch.
        Check.test("a corrupt store starts clean instead of failing to launch") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            try? "{ not json".write(to: url, atomically: true, encoding: .utf8)
            let store = UsageStore(storeURL: url)
            store.setCurrentNetwork(network("home"))
            Check.expectEqual(store.currentBucket.interfaceTotal, 0)
        }
    }
}

func runNetworkFingerprintTests() {
    Check.suite("NetworkFingerprint") {

        // Gateway MAC, not BSSID: roaming between access points on one network
        // changes the BSSID constantly but leaves the gateway alone.
        Check.test("roaming between access points keeps one identity") {
            let first = NetworkFingerprint.make(kind: .wifi, gatewayMAC: "50:c7:bf:8a:94:93",
                                                interfaceName: "en0",
                                                isExpensive: false, isConstrained: false)
            let second = NetworkFingerprint.make(kind: .wifi, gatewayMAC: "50:c7:bf:8a:94:93",
                                                 interfaceName: "en0",
                                                 isExpensive: false, isConstrained: false)
            Check.expectEqual(first.id, second.id)
        }

        // Two routers sharing an SSID name are genuinely different networks —
        // the case SSID-based identity gets wrong.
        Check.test("different routers are different networks") {
            let home = NetworkFingerprint.make(kind: .wifi, gatewayMAC: "50:c7:bf:8a:94:93",
                                               interfaceName: "en0",
                                               isExpensive: false, isConstrained: false)
            let cafe = NetworkFingerprint.make(kind: .wifi, gatewayMAC: "aa:bb:cc:dd:ee:ff",
                                               interfaceName: "en0",
                                               isExpensive: false, isConstrained: false)
            Check.expectFalse(home.id == cafe.id)
        }

        // Wi-Fi and Ethernet to the same router share a data cap, so one bucket.
        Check.test("the same router over a different medium shares a bucket") {
            let wifi = NetworkFingerprint.make(kind: .wifi, gatewayMAC: "50:c7:bf:8a:94:93",
                                               interfaceName: "en0",
                                               isExpensive: false, isConstrained: false)
            let wired = NetworkFingerprint.make(kind: .ethernet, gatewayMAC: "50:c7:bf:8a:94:93",
                                                interfaceName: "en5",
                                                isExpensive: false, isConstrained: false)
            Check.expectEqual(wifi.id, wired.id)
        }

        Check.test("falls back to the interface when the gateway is unknown") {
            let fingerprint = NetworkFingerprint.make(kind: .wifi, gatewayMAC: nil,
                                                      interfaceName: "en0",
                                                      isExpensive: false, isConstrained: false)
            Check.expectEqual(fingerprint.id, "if:en0")
        }

        Check.test("a hotspot is labelled and flagged as metered") {
            let hotspot = NetworkFingerprint.make(kind: .hotspot, gatewayMAC: "aa:bb:cc:dd:ee:01",
                                                  interfaceName: "en0",
                                                  isExpensive: true, isConstrained: false)
            Check.expectTrue(hotspot.defaultLabel.hasPrefix("Personal Hotspot"),
                             "got ‘\(hotspot.defaultLabel)’")
            Check.expectTrue(hotspot.isExpensive)
        }

        Check.test("labels include a MAC suffix to disambiguate") {
            let first = NetworkFingerprint.make(kind: .wifi, gatewayMAC: "50:c7:bf:8a:94:93",
                                                interfaceName: "en0",
                                                isExpensive: false, isConstrained: false)
            let second = NetworkFingerprint.make(kind: .wifi, gatewayMAC: "50:c7:bf:8a:94:01",
                                                 interfaceName: "en0",
                                                 isExpensive: false, isConstrained: false)
            Check.expectFalse(first.defaultLabel == second.defaultLabel)
        }
    }
}
