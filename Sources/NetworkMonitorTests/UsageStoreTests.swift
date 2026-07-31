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

        // Switching to a different network shows that network's own total, and
        // switching back restores the original rather than restarting at zero.
        Check.test("switching networks keeps separate totals") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = UsageStore(storeURL: url)
            store.setCurrentNetwork(network("home"))
            store.recordInterface(bytesIn: 5000, bytesOut: 1000)

            store.setCurrentNetwork(network("hotspot", expensive: true))
            Check.expectEqual(store.currentBucket.interfaceBytesIn, 0, "new network starts fresh")
            store.recordInterface(bytesIn: 200, bytesOut: 50)
            Check.expectEqual(store.currentBucket.interfaceBytesIn, 200)

            store.setCurrentNetwork(network("home"))
            Check.expectEqual(store.currentBucket.interfaceBytesIn, 5000,
                              "returning restores the original bucket")
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
