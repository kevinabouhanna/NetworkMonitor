import Foundation
import LowDataMode
import NetworkMonitorCore

// MARK: - Parsing shared with the helper

func runLowDataModeParsingTests() {
    Check.suite("LowDataMode parsing") {

        // `scutil --nwi` on the development machine, on home Wi-Fi, address
        // replaced.
        let nwi = """
            Network information

            IPv4 network interface information
                 en0 : flags      : 0x5 (IPv4,DNS)
                       address    : 192.168.1.20
                       reach      : 0x00000002 (Reachable)

               REACH : flags 0x00000002 (Reachable)

            IPv6 network interface information
               No IPv6 states found


               REACH : flags 0x00000000 (Not Reachable)

            Network interfaces: en0
            """

        // `ifconfig -v en0` on the same machine, unconstrained, addresses
        // replaced. The flag lines are verbatim.
        let unconstrained = """
            en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
            \toptions=6460<TSO4,TSO6,CHANNEL_IO,PARTIAL_CSUM,ZEROINVERT_CSUM>
            \tether 02:00:00:00:00:01
            \tinet 192.168.1.20 netmask 0xffffff00 broadcast 192.168.1.255
            \teflags=442008d0<ADV_REPORT,ACCEPT_RTADV,TXSTART,ARPLL,NOACKPRI,CHANNEL_DRV,FASTLN_ON>
            \txflags=4000000<INBAND_WAKE_PKT>
            """

        Check.test("only Ethernet-class names are acted on") {
            for name in ["en0", "en5", "en10", "en123"] {
                Check.expectTrue(LowDataMode.isPhysicalInterface(name), name)
            }
            // Tunnels, AWDL, loopback, and anything that is not purely a name —
            // this check is also the helper's input validation.
            for name in ["utun4", "awdl0", "lo0", "bridge0", "en", "en1234", "EN0",
                         "en0 ", "en0;rm", "en-1", ""] {
                Check.expectFalse(LowDataMode.isPhysicalInterface(name), name)
            }
        }

        Check.test("the primary interface comes from the nwi order") {
            Check.expectEqual(LowDataMode.primaryInterface(fromNWI: nwi), "en0")
        }

        Check.test("a VPN's tunnel is skipped for the link beneath it") {
            Check.expectEqual(
                LowDataMode.primaryInterface(fromNWI: "Network interfaces: utun4 en5 en0"),
                "en5")
        }

        Check.test("no physical interface means no answer") {
            Check.expectNil(LowDataMode.primaryInterface(fromNWI: "Network interfaces: utun4"))
            Check.expectNil(LowDataMode.primaryInterface(fromNWI: "No network information"))
        }

        Check.test("an unconstrained interface reads as neither flag") {
            Check.expectEqual(LowDataMode.flags(fromIfconfig: unconstrained),
                              LowDataMode.Flags())
        }

        Check.test("each flag is found in its own flags line") {
            // The same output with the two names added by hand, where
            // `ifconfig` prints them: EXPENSIVE among the eflags, CONSTRAINED
            // among the xflags.
            let raised = unconstrained
                .replacingOccurrences(of: "<ADV_REPORT,", with: "<ADV_REPORT,EXPENSIVE,")
                .replacingOccurrences(of: "<INBAND_WAKE_PKT>", with: "<CONSTRAINED,INBAND_WAKE_PKT>")
            Check.expectEqual(LowDataMode.flags(fromIfconfig: raised), .both)
        }

        Check.test("ULTRA_CONSTRAINED is not CONSTRAINED") {
            let ultra = unconstrained
                .replacingOccurrences(of: "<INBAND_WAKE_PKT>",
                                      with: "<ULTRA_CONSTRAINED,INBAND_WAKE_PKT>")
            Check.expectEqual(LowDataMode.flags(fromIfconfig: ultra)?.constrained, false)
        }

        Check.test("a flag name outside the flag lines does not count") {
            // The `flags=` line is the interface's ordinary flags, not these.
            let misleading = unconstrained.replacingOccurrences(
                of: "<UP,", with: "<UP,CONSTRAINED,")
            Check.expectEqual(LowDataMode.flags(fromIfconfig: misleading)?.constrained, false)
        }

        Check.test("a missing interface is not read as one with no flags") {
            Check.expectNil(LowDataMode.flags(fromIfconfig: ""))
            Check.expectNil(LowDataMode.flags(
                fromIfconfig: "ifconfig: interface en9 does not exist"))
        }

        Check.test("a report survives the trip from helper to app") {
            let reports: [LowDataMode.Report] = [
                .nothing,
                .holding(.init(interface: "en0", setConstrained: true, setExpensive: true)),
                .holding(.init(interface: "en5", setConstrained: true, setExpensive: false)),
                .holding(.init(interface: "en7", setConstrained: false, setExpensive: true)),
            ]
            for report in reports {
                Check.expectEqual(LowDataMode.Report(output: report.line), report, report.line)
            }
        }

        Check.test("the last report line wins, and other output is ignored") {
            let output = "some warning\nholding nothing\nholding en0 constrained\n"
            Check.expectEqual(
                LowDataMode.Report(output: output),
                .holding(.init(interface: "en0", setConstrained: true, setExpensive: false)))
        }

        Check.test("a malformed report is rejected, not half-understood") {
            for line in ["", "holding", "holding en0", "holding utun0 constrained",
                         "holding en0 constrained bogus", "holding en0 constrained constrained",
                         "holding nothing extra", "held en0 constrained"] {
                Check.expectNil(LowDataMode.Report(output: line), line)
            }
        }

        Check.test("a wired Low Data Mode setting counts only in the current set") {
            // The development machine's shape: the flag for en5 sits in the
            // "Automatic" set while "Home" is the one in use.
            var plist: [String: Any] = [
                "CurrentSet": "/Sets/HOME",
                "Sets": [
                    "HOME": ["Network": ["Interface": ["en0": ["AirPort": [:]]]]],
                    "AUTO": ["Network": ["Interface": ["en5": ["EnableLowDataMode": 1]]]],
                ],
            ]
            Check.expectFalse(LowDataMode.isConfigured(interface: "en5", inPreferences: plist))
            plist["CurrentSet"] = "/Sets/AUTO"
            Check.expectTrue(LowDataMode.isConfigured(interface: "en5", inPreferences: plist))
            Check.expectFalse(LowDataMode.isConfigured(interface: "en0", inPreferences: plist))
            Check.expectFalse(LowDataMode.isConfigured(interface: "en5", inPreferences: [:]))
        }

        if Check.skipsLiveTests {
            Check.skip("this Mac's interfaces read through the real tools",
                       "needs a network; set NETMON_LIVE_TESTS=1")
        } else {
            Check.test("this Mac's interfaces read through the real tools") {
                // Unprivileged, exactly as the app reads them to check the helper.
                guard let primary = InterfaceProbe.primaryInterface() else {
                    Check.expectTrue(true)
                    return
                }
                Check.expectTrue(LowDataMode.isPhysicalInterface(primary))
                Check.expectNotNil(InterfaceProbe.flags(on: primary))
            }
        }
    }
}

// MARK: - A stand-in for the helper

/// The root helper and the kernel it acts on, simulated, so the app's half of
/// Low Data Mode can be tested without root.
///
/// Follows `NetworkMonitorHelper`'s rules: `constrain` raises only what is down
/// and records only what it raised, moves its hold when the primary interface
/// changes, and reports nothing held when both flags were already up;
/// `unconstrain` lowers only what it recorded.
final class FakeLowDataHelper {
    var installed = true
    /// Nil simulates a helper from before Low Data Mode: `status` works but
    /// names no verbs, and the new verbs are refused by sudo.
    var verbs: [String]? = ["status", "suppress", "restore", "constrain",
                            "unconstrain", "self-heal", "uninstall"]
    var primary: String? = "en0"
    var flags: [String: LowDataMode.Flags] = ["en0": .init(), "en5": .init()]
    var hold: LowDataMode.Hold?
    /// Verbs that fail the next time they are called, once each.
    var failNext: Set<String> = []
    var calls: [String] = []

    func count(_ verb: String) -> Int { calls.filter { $0 == verb }.count }

    func invoke(_ verb: String) -> String? {
        calls.append(verb)
        guard installed else { return nil }
        if failNext.remove(verb) != nil { return nil }
        switch verb {
        case "status":
            var payload: [String: Any] = ["suppressed": false]
            if let verbs {
                payload["verbs"] = verbs
                payload["lowDataMode"] = (hold.map(LowDataMode.Report.holding) ?? .nothing).line
            }
            let data = try! JSONSerialization.data(withJSONObject: payload)
            return String(data: data, encoding: .utf8)
        case "constrain":
            guard verbs != nil, let interface = primary else { return nil }
            if let previous = hold, previous.interface != interface {
                release(previous)
                hold = nil
            }
            let current = flags[interface] ?? .init()
            var next = hold ?? .init(interface: interface,
                                     setConstrained: false, setExpensive: false)
            if !current.constrained { next.setConstrained = true }
            if !current.expensive { next.setExpensive = true }
            guard next.setConstrained || next.setExpensive else {
                hold = nil
                return LowDataMode.Report.nothing.line
            }
            flags[interface] = .both
            hold = next
            return LowDataMode.Report.holding(next).line
        case "unconstrain":
            guard verbs != nil else { return nil }
            if let hold { release(hold) }
            hold = nil
            return LowDataMode.Report.nothing.line
        default:
            return nil
        }
    }

    /// macOS lowering both flags, as it does when a hotspot drops and rejoins.
    func systemLowersFlags(on interface: String) {
        flags[interface] = .init()
    }

    func makeSuppressor(ownership: InterfaceFlagOwnership,
                        clock: @escaping () -> Date = Date.init) -> LowDataModeSuppressor {
        LowDataModeSuppressor(ownership: ownership,
                              invoke: { [unowned self] in self.invoke($0) },
                              isHelperInstalled: { [unowned self] in self.installed },
                              primaryInterface: { [unowned self] in self.primary },
                              readFlags: { [unowned self] in self.flags[$0] },
                              now: clock)
    }

    private func release(_ hold: LowDataMode.Hold) {
        var current = flags[hold.interface] ?? .init()
        if hold.setConstrained { current.constrained = false }
        if hold.setExpensive { current.expensive = false }
        flags[hold.interface] = current
    }
}

private func temporaryJournal() -> (SuppressionJournal, URL) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("journal-\(UUID().uuidString).json")
    return (SuppressionJournal(url: url), url)
}

// MARK: - Ownership

func runInterfaceFlagOwnershipTests() {
    Check.suite("InterfaceFlagOwnership") {

        let raised = MeteredHeuristic.Signals(isExpensive: true, isConstrained: true,
                                              gatewayIP: "192.168.1.1")

        Check.test("with nothing held, signals pass through untouched") {
            Check.expectEqual(InterfaceFlagOwnership().masking(raised, on: "en0"), raised)
        }

        Check.test("our own flags are taken back out on our interface") {
            let ownership = InterfaceFlagOwnership()
            ownership.hold = .init(interface: "en0", setConstrained: true, setExpensive: true)
            let masked = ownership.masking(raised, on: "en0")
            Check.expectFalse(masked.isConstrained)
            Check.expectFalse(masked.isExpensive)
            Check.expectEqual(MeteredHeuristic.verdict(for: masked), .unmetered)
        }

        Check.test("another interface's flags are its own") {
            let ownership = InterfaceFlagOwnership()
            ownership.hold = .init(interface: "en0", setConstrained: true, setExpensive: true)
            Check.expectEqual(ownership.masking(raised, on: "en5"), raised)
        }

        Check.test("a flag macOS raised itself stays evidence") {
            // A recognised iPhone hotspot: EXPENSIVE was macOS's, only
            // CONSTRAINED is ours.
            let ownership = InterfaceFlagOwnership()
            ownership.hold = .init(interface: "en0", setConstrained: true, setExpensive: false)
            let masked = ownership.masking(raised, on: "en0")
            Check.expectTrue(masked.isExpensive)
            Check.expectFalse(masked.isConstrained)
        }

        Check.test("an unnamed interface is masked, since not masking is what loops") {
            let ownership = InterfaceFlagOwnership()
            ownership.hold = .init(interface: "en0", setConstrained: true, setExpensive: true)
            Check.expectFalse(ownership.masking(raised, on: nil).isExpensive)
        }
    }
}

// MARK: - The suppressor

func runLowDataModeSuppressorTests() {
    Check.suite("LowDataModeSuppressor") {

        Check.test("a metered connection is put in Low Data Mode and checked") {
            let helper = FakeLowDataHelper()
            let ownership = InterfaceFlagOwnership()
            let suppressor = helper.makeSuppressor(ownership: ownership)
            let (journal, url) = temporaryJournal()
            defer { try? FileManager.default.removeItem(at: url) }

            suppressor.apply(journal: journal, excluding: [])
            Check.expectEqual(helper.count("constrain"), 1)
            Check.expectEqual(suppressor.state, .on(interface: "en0"))
            Check.expectEqual(helper.flags["en0"], .both)
            Check.expectEqual(ownership.hold?.interface, "en0")
            Check.expectNotNil(journal.record(for: .lowDataMode))
        }

        Check.test("re-applying while it holds costs no root call") {
            let helper = FakeLowDataHelper()
            let suppressor = helper.makeSuppressor(ownership: InterfaceFlagOwnership())
            let (journal, url) = temporaryJournal()
            defer { try? FileManager.default.removeItem(at: url) }

            suppressor.apply(journal: journal, excluding: [])
            let callsAfterFirst = helper.calls.count
            suppressor.apply(journal: journal, excluding: [])
            suppressor.apply(journal: journal, excluding: [])
            Check.expectEqual(helper.calls.count, callsAfterFirst,
                              "flags still up on the same link: nothing to do")
        }

        Check.test("flags macOS lowered on a rejoin are raised again") {
            let helper = FakeLowDataHelper()
            let suppressor = helper.makeSuppressor(ownership: InterfaceFlagOwnership())
            let (journal, url) = temporaryJournal()
            defer { try? FileManager.default.removeItem(at: url) }

            suppressor.apply(journal: journal, excluding: [])
            helper.systemLowersFlags(on: "en0")
            suppressor.apply(journal: journal, excluding: [])
            Check.expectEqual(helper.count("constrain"), 2)
            Check.expectEqual(helper.flags["en0"], .both)
            Check.expectEqual(suppressor.state, .on(interface: "en0"))
        }

        Check.test("a system that keeps lowering them is not fought in a loop") {
            var clock = Date(timeIntervalSince1970: 1_000_000)
            let helper = FakeLowDataHelper()
            let suppressor = helper.makeSuppressor(ownership: InterfaceFlagOwnership(),
                                                   clock: { clock })
            let (journal, url) = temporaryJournal()
            defer { try? FileManager.default.removeItem(at: url) }

            for _ in 0..<6 {
                suppressor.apply(journal: journal, excluding: [])
                helper.systemLowersFlags(on: "en0")
                clock.addTimeInterval(5)
            }
            Check.expectEqual(helper.count("constrain"), LowDataModeSuppressor.reassertLimit,
                              "a few asserts inside the window, then it stops asking")
            if case .failed = suppressor.state {} else {
                Check.expectTrue(false, "the user is told rather than left guessing")
            }

            // Once the window has passed it may try again.
            clock.addTimeInterval(LowDataModeSuppressor.reassertWindow)
            suppressor.apply(journal: journal, excluding: [])
            Check.expectEqual(helper.count("constrain"), LowDataModeSuppressor.reassertLimit + 1)
        }

        Check.test("moving to another link moves the hold with it") {
            let helper = FakeLowDataHelper()
            let ownership = InterfaceFlagOwnership()
            let suppressor = helper.makeSuppressor(ownership: ownership)
            let (journal, url) = temporaryJournal()
            defer { try? FileManager.default.removeItem(at: url) }

            suppressor.apply(journal: journal, excluding: [])
            helper.primary = "en5"   // plugged into a phone
            suppressor.apply(journal: journal, excluding: [])
            Check.expectEqual(ownership.hold?.interface, "en5")
            Check.expectEqual(helper.flags["en0"], LowDataMode.Flags(),
                              "the link left behind must not stay constrained")
            Check.expectEqual(helper.flags["en5"], .both)
        }

        Check.test("revert lowers the flags, forgets the hold and clears the journal") {
            let helper = FakeLowDataHelper()
            let ownership = InterfaceFlagOwnership()
            let suppressor = helper.makeSuppressor(ownership: ownership)
            let (journal, url) = temporaryJournal()
            defer { try? FileManager.default.removeItem(at: url) }

            suppressor.apply(journal: journal, excluding: [])
            suppressor.revert(journal: journal)
            Check.expectEqual(helper.count("unconstrain"), 1)
            Check.expectEqual(helper.flags["en0"], LowDataMode.Flags())
            Check.expectNil(ownership.hold)
            Check.expectNil(journal.record(for: .lowDataMode))
            Check.expectEqual(suppressor.state, .off)
            Check.expectFalse(suppressor.holdsUnreleasedState)
        }

        Check.test("a flag that was already up is never ours to lower") {
            // A recognised iPhone hotspot: macOS raised EXPENSIVE itself.
            let helper = FakeLowDataHelper()
            helper.flags["en0"] = LowDataMode.Flags(constrained: false, expensive: true)
            let ownership = InterfaceFlagOwnership()
            let suppressor = helper.makeSuppressor(ownership: ownership)
            let (journal, url) = temporaryJournal()
            defer { try? FileManager.default.removeItem(at: url) }

            suppressor.apply(journal: journal, excluding: [])
            Check.expectEqual(ownership.hold?.setExpensive, false)
            suppressor.revert(journal: journal)
            Check.expectEqual(helper.flags["en0"],
                              LowDataMode.Flags(constrained: false, expensive: true))
        }

        Check.test("a connection already in Low Data Mode is left exactly as it is") {
            let helper = FakeLowDataHelper()
            helper.flags["en0"] = .both
            let ownership = InterfaceFlagOwnership()
            let suppressor = helper.makeSuppressor(ownership: ownership)
            let (journal, url) = temporaryJournal()
            defer { try? FileManager.default.removeItem(at: url) }

            suppressor.apply(journal: journal, excluding: [])
            Check.expectEqual(suppressor.state, .alreadyOn)
            Check.expectNil(ownership.hold)
            Check.expectNil(journal.record(for: .lowDataMode), "nothing of ours to undo")
        }

        Check.test("a release that fails keeps the hold, and the next one finishes it") {
            let helper = FakeLowDataHelper()
            let ownership = InterfaceFlagOwnership()
            let suppressor = helper.makeSuppressor(ownership: ownership)
            let (journal, url) = temporaryJournal()
            defer { try? FileManager.default.removeItem(at: url) }

            suppressor.apply(journal: journal, excluding: [])
            helper.failNext = ["unconstrain"]
            suppressor.revert(journal: journal)
            Check.expectTrue(suppressor.holdsUnreleasedState,
                             "unconfirmed flags are still ours, and still masked")
            Check.expectNotNil(ownership.hold)

            journal.clearAll()   // what `revertAll` does regardless
            suppressor.revert(journal: journal)
            Check.expectFalse(suppressor.holdsUnreleasedState)
            Check.expectEqual(helper.flags["en0"], LowDataMode.Flags())
        }

        Check.test("at launch the helper is asked even with an empty journal") {
            // A previous run crashed while holding. Its flags are still up, and
            // this run has no record of them.
            let helper = FakeLowDataHelper()
            helper.flags["en0"] = .both
            helper.hold = .init(interface: "en0", setConstrained: true, setExpensive: true)
            let suppressor = helper.makeSuppressor(ownership: InterfaceFlagOwnership())
            let (journal, url) = temporaryJournal()
            defer { try? FileManager.default.removeItem(at: url) }

            suppressor.revert(journal: journal)
            Check.expectEqual(helper.count("unconstrain"), 1)
            Check.expectEqual(helper.flags["en0"], LowDataMode.Flags())

            // And only once: after that it knows.
            suppressor.revert(journal: journal)
            Check.expectEqual(helper.count("unconstrain"), 1)
        }

        Check.test("at launch with nothing held, status is the only call") {
            let helper = FakeLowDataHelper()
            let suppressor = helper.makeSuppressor(ownership: InterfaceFlagOwnership())
            let (journal, url) = temporaryJournal()
            defer { try? FileManager.default.removeItem(at: url) }

            suppressor.revert(journal: journal)
            Check.expectEqual(helper.calls, ["status"])
            Check.expectEqual(suppressor.state, .off)
        }

        Check.test("an old helper is never sent a verb its sudoers rule refuses") {
            let helper = FakeLowDataHelper()
            helper.verbs = nil
            let suppressor = helper.makeSuppressor(ownership: InterfaceFlagOwnership())
            let (journal, url) = temporaryJournal()
            defer { try? FileManager.default.removeItem(at: url) }

            suppressor.revert(journal: journal)
            suppressor.apply(journal: journal, excluding: [])
            Check.expectEqual(helper.calls, ["status"])
        }

        Check.test("a helper from before Low Data Mode says so, and is never asked") {
            let helper = FakeLowDataHelper()
            helper.verbs = nil
            let suppressor = helper.makeSuppressor(ownership: InterfaceFlagOwnership())
            let (journal, url) = temporaryJournal()
            defer { try? FileManager.default.removeItem(at: url) }

            Check.expectEqual(suppressor.availability, .helperOutdated)
            suppressor.apply(journal: journal, excluding: [])
            Check.expectEqual(helper.count("constrain"), 0)
            Check.expectTrue(suppressor.discover().isEmpty)
        }

        Check.test("no helper, no calls") {
            let helper = FakeLowDataHelper()
            helper.installed = false
            let suppressor = helper.makeSuppressor(ownership: InterfaceFlagOwnership())
            let (journal, url) = temporaryJournal()
            defer { try? FileManager.default.removeItem(at: url) }

            Check.expectEqual(suppressor.availability, .helperMissing)
            suppressor.apply(journal: journal, excluding: [])
            Check.expectTrue(helper.calls.isEmpty)
        }

        Check.test("switched off by the user, it does nothing") {
            let helper = FakeLowDataHelper()
            let suppressor = helper.makeSuppressor(ownership: InterfaceFlagOwnership())
            let (journal, url) = temporaryJournal()
            defer { try? FileManager.default.removeItem(at: url) }

            suppressor.apply(journal: journal, excluding: [LowDataModeSuppressor.itemID])
            Check.expectEqual(helper.count("constrain"), 0)
        }
    }
}

// MARK: - With the controller

func runLowDataModeMeteringTests() {
    Check.suite("MeteringController — Low Data Mode") {

        struct Rig {
            let controller: MeteringController
            let store: UsageStore
            let helper: FakeLowDataHelper
            let ownership: InterfaceFlagOwnership
            let urls: [URL]
        }

        func makeRig(fingerprint: NetworkFingerprint) -> Rig {
            let temp = FileManager.default.temporaryDirectory
            let storeURL = temp.appendingPathComponent("usage-\(UUID().uuidString).json")
            let journalURL = temp.appendingPathComponent("journal-\(UUID().uuidString).json")
            let caches = temp.appendingPathComponent("caches-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: caches,
                                                     withIntermediateDirectories: true)
            let store = UsageStore(storeURL: storeURL)
            store.setCurrentNetwork(fingerprint)

            let defaults = UserDefaults(suiteName: "netmon.tests.\(UUID().uuidString)")!
            defaults.set(true, forKey: MeteringController.enabledKey)

            let helper = FakeLowDataHelper()
            let ownership = InterfaceFlagOwnership()
            let watch = UpdateWatch(cachesDirectory: caches, defaults: defaults,
                                    resolveOwner: { "\($0)" })
            let controller = MeteringController(
                store: store,
                journal: SuppressionJournal(url: journalURL),
                suppressors: [helper.makeSuppressor(ownership: ownership)],
                defaults: defaults,
                ownership: ownership,
                updateWatch: watch)
            return Rig(controller: controller, store: store, helper: helper,
                       ownership: ownership, urls: [storeURL, journalURL, caches])
        }

        // An iPhone hotspot macOS did not recognise: identified by its subnet,
        // with neither flag up until we raise them.
        func hotspot(constrained: Bool = false, expensive: Bool = false) -> NetworkFingerprint {
            .make(kind: .hotspot, gatewayMAC: "00:00:5e:00:53:64", interfaceName: "en0",
                  isExpensive: expensive, isConstrained: constrained,
                  gatewayIP: "172.20.10.1", interfaceDisplayName: "Wi-Fi")
        }
        func home(constrained: Bool, expensive: Bool) -> NetworkFingerprint {
            .make(kind: .wifi, gatewayMAC: "00:00:5e:00:53:2a", interfaceName: "en0",
                  isExpensive: expensive, isConstrained: constrained,
                  gatewayIP: "192.168.1.1", interfaceDisplayName: "Wi-Fi")
        }

        Check.test("our own flags never make home Wi-Fi look metered") {
            // The loop this whole ownership business exists to prevent: leave
            // the hotspot for home on the same en0, with our flags still up for
            // the two seconds before anything notices.
            let rig = makeRig(fingerprint: hotspot())
            defer { rig.urls.forEach { try? FileManager.default.removeItem(at: $0) } }

            rig.controller.evaluate()
            Check.expectNotNil(rig.ownership.hold)

            rig.store.setCurrentNetwork(home(constrained: true, expensive: true))
            rig.controller.networkDidChange()

            Check.expectEqual(rig.controller.verdict, .unmetered)
            Check.expectFalse(rig.controller.isSuppressing)
            Check.expectEqual(rig.helper.count("unconstrain"), 1)
            Check.expectNil(rig.ownership.hold)
            Check.expectEqual(rig.helper.flags["en0"], LowDataMode.Flags())
        }

        Check.test("the verdict keeps its own reason while the flags are ours") {
            let rig = makeRig(fingerprint: hotspot())
            defer { rig.urls.forEach { try? FileManager.default.removeItem(at: $0) } }

            rig.controller.evaluate()
            // The path monitor now sees our flags on the same network.
            rig.store.setCurrentNetwork(hotspot(constrained: true, expensive: true))
            rig.controller.networkDidChange()
            Check.expectEqual(rig.controller.verdict, .iOSHotspotSubnet,
                              "not 'macOS reports this as a hotspot' — we said that")
        }

        Check.test("macOS agreeing is reported as confirmation") {
            let rig = makeRig(fingerprint: hotspot())
            defer { rig.urls.forEach { try? FileManager.default.removeItem(at: $0) } }

            rig.controller.evaluate()
            Check.expectEqual(rig.controller.lowDataMode, .on(interface: "en0"))
            Check.expectFalse(rig.controller.lowDataModeConfirmed,
                              "the path has not caught up yet")

            rig.store.setCurrentNetwork(hotspot(constrained: true, expensive: true))
            rig.controller.networkDidChange()
            Check.expectTrue(rig.controller.lowDataModeConfirmed)
        }

        Check.test("an unconfirmed release is retried on the next evaluation") {
            let rig = makeRig(fingerprint: hotspot())
            defer { rig.urls.forEach { try? FileManager.default.removeItem(at: $0) } }

            rig.controller.evaluate()
            rig.helper.failNext = ["unconstrain"]
            rig.store.setCurrentNetwork(home(constrained: true, expensive: true))
            rig.controller.networkDidChange()
            Check.expectNotNil(rig.ownership.hold, "kept, and still masked")
            Check.expectEqual(rig.controller.verdict, .unmetered,
                              "masking must hold even while the release is pending")

            rig.controller.networkDidChange()
            Check.expectNil(rig.ownership.hold)
            Check.expectEqual(rig.helper.flags["en0"], LowDataMode.Flags())
        }

        Check.test("quitting lets go of Low Data Mode") {
            let rig = makeRig(fingerprint: hotspot())
            defer { rig.urls.forEach { try? FileManager.default.removeItem(at: $0) } }

            rig.controller.start()
            Check.expectNotNil(rig.ownership.hold)
            rig.controller.stop()
            Check.expectNil(rig.ownership.hold)
            Check.expectEqual(rig.helper.flags["en0"], LowDataMode.Flags())
        }

        Check.test("switching it off releases it while the rest stays on") {
            let rig = makeRig(fingerprint: hotspot())
            defer { rig.urls.forEach { try? FileManager.default.removeItem(at: $0) } }

            rig.controller.evaluate()
            rig.controller.setSuppressionEnabled(false, for: LowDataModeSuppressor.itemID)
            Check.expectNil(rig.ownership.hold)
            Check.expectTrue(rig.controller.isSuppressing)
            Check.expectEqual(rig.controller.lowDataMode, .off)
        }

        Check.test("it is a switch of its own, not a row in the app list") {
            let rig = makeRig(fingerprint: hotspot())
            defer { rig.urls.forEach { try? FileManager.default.removeItem(at: $0) } }

            Check.expectFalse(rig.controller.toggleItems()
                .contains { $0.id == LowDataModeSuppressor.itemID })
        }
    }
}

// MARK: - Installing the helper from the app

func runHelperInstallerTests() {
    Check.suite("HelperInstaller") {

        Check.test("arguments survive both layers of quoting") {
            // Run for real, minus the administrator part: the same AppleScript,
            // the same /bin/sh, so what comes out is what root would have run.
            let arguments = ["/bin/echo", "/Applications/Net\"work Monitor.app/x.sh",
                             "it's", "back\\slash", "$HOME", "`id`", "a;b"]
            let source = HelperInstaller.appleScript(running: arguments,
                                                     prompt: "Say \"yes\"")
                .replacingOccurrences(of: " with administrator privileges", with: "")
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            Check.expectNil(error, "\(String(describing: error))")
            Check.expectEqual(result?.stringValue,
                              arguments.dropFirst().joined(separator: " "),
                              "nothing expanded, nothing split, nothing lost")
        }

        Check.test("the request asks for administrator privileges, with a reason") {
            let source = HelperInstaller.appleScript(running: ["/usr/bin/true"],
                                                     prompt: "Because.")
            Check.expectTrue(source.hasSuffix("with administrator privileges"))
            Check.expectTrue(source.contains("with prompt \"Because.\""))
        }

        Check.test("the helper's version is shared with the app") {
            // The app decides "outdated" by comparing against this; the helper
            // reports it from the same target.
            Check.expectTrue(HelperProtocol.version >= 2,
                             "Low Data Mode's verbs arrived in version 2")
        }
    }
}
