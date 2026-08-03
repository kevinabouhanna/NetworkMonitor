import Foundation
import HostsFile
import NetworkMonitorCore

// MARK: - Heuristic

func runMeteredHeuristicTests() {
    Check.suite("MeteredHeuristic") {

        func verdict(_ signals: MeteredHeuristic.Signals) -> MeteredHeuristic.Verdict {
            MeteredHeuristic.verdict(for: signals)
        }

        Check.test("an explicit override outranks every inference") {
            // Marked metered on a connection nothing else would flag.
            Check.expectEqual(
                verdict(.init(userOverride: true, gatewayIP: "192.168.1.1")),
                .userMarked)
            // And marked *not* metered on one everything would flag: the point
            // of the override is to end the argument, in both directions.
            Check.expectEqual(
                verdict(.init(userOverride: false,
                              isExpensive: true,
                              gatewayIP: "172.20.10.1",
                              interfaceDisplayName: "iPhone USB")),
                .userCleared)
            Check.expectFalse(MeteredHeuristic.Verdict.userCleared.isMetered)
        }

        Check.test("isExpensive is the primary automatic signal") {
            Check.expectEqual(verdict(.init(isExpensive: true)), .expensive)
        }

        Check.test("an iOS Personal Hotspot is recognised by its subnet alone") {
            // The case isExpensive cannot cover: a phone macOS has never met.
            Check.expectEqual(verdict(.init(gatewayIP: "172.20.10.1")), .iOSHotspotSubnet)
            Check.expectEqual(verdict(.init(gatewayIP: "172.20.10.15")), .iOSHotspotSubnet)
        }

        Check.test("the iOS range stops at its /28 boundary") {
            // 172.20.10.16 is outside the /28. A sloppy /24 here would meter
            // every 172.20.10.x network in existence.
            Check.expectEqual(verdict(.init(gatewayIP: "172.20.10.16")), .unmetered)
            Check.expectEqual(verdict(.init(gatewayIP: "172.20.11.1")), .unmetered)
        }

        Check.test("Android tethering ranges are recognised") {
            Check.expectEqual(verdict(.init(gatewayIP: "192.168.42.129")),
                              .androidTetherSubnet)
            Check.expectEqual(verdict(.init(gatewayIP: "192.168.43.1")),
                              .androidTetherSubnet)
        }

        Check.test("an ordinary home gateway is not metered") {
            Check.expectEqual(verdict(.init(gatewayIP: "192.168.1.1")), .unmetered)
            Check.expectEqual(verdict(.init(gatewayIP: "10.0.0.1")), .unmetered)
            Check.expectEqual(verdict(.init(gatewayIP: "192.168.44.1")), .unmetered)
        }

        Check.test("a tethered interface is recognised by name") {
            Check.expectEqual(verdict(.init(interfaceDisplayName: "iPhone USB")),
                              .tetherInterface)
            Check.expectEqual(verdict(.init(interfaceDisplayName: "iPad USB")),
                              .tetherInterface)
        }

        // The regression that would actually hurt. This machine has a wired
        // adapter called "USB 10/100 LAN"; matching the bare word "usb" would
        // meter an Ethernet dongle and suppress updates on a connection that
        // costs nothing — the one failure direction with a real victim.
        Check.test("a USB Ethernet adapter is not mistaken for a tether") {
            Check.expectEqual(verdict(.init(interfaceDisplayName: "USB 10/100 LAN")),
                              .unmetered)
            Check.expectEqual(verdict(.init(interfaceDisplayName: "Wi-Fi")), .unmetered)
            Check.expectEqual(verdict(.init(interfaceDisplayName: "Thunderbolt Bridge")),
                              .unmetered)
        }

        Check.test("Low Data Mode is read as a statement about cost") {
            Check.expectEqual(verdict(.init(isConstrained: true)), .constrained)
        }

        Check.test("ranks are tried in order of how much they can be trusted") {
            // isExpensive (2) outranks the subnet check (3).
            Check.expectEqual(
                verdict(.init(isExpensive: true, gatewayIP: "172.20.10.1")), .expensive)
            // The subnet check (3) outranks the interface name (5).
            Check.expectEqual(
                verdict(.init(gatewayIP: "172.20.10.1", interfaceDisplayName: "Wi-Fi")),
                .iOSHotspotSubnet)
            // The interface name (5) outranks Low Data Mode (6).
            Check.expectEqual(
                verdict(.init(isConstrained: true, interfaceDisplayName: "iPhone USB")),
                .tetherInterface)
        }

        Check.test("every metered verdict reports itself as metered") {
            for verdict in [MeteredHeuristic.Verdict.userMarked, .expensive,
                            .iOSHotspotSubnet, .androidTetherSubnet,
                            .tetherInterface, .constrained] {
                Check.expectTrue(verdict.isMetered, "\(verdict) should be metered")
                Check.expectFalse(verdict.explanation.isEmpty)
            }
            Check.expectFalse(MeteredHeuristic.Verdict.unmetered.isMetered)
        }
    }

    Check.suite("IPv4 parsing") {
        Check.test("well-formed addresses parse") {
            Check.expectEqual(IPv4Address("0.0.0.0")?.raw, 0)
            Check.expectEqual(IPv4Address("255.255.255.255")?.raw, 0xFFFF_FFFF)
            Check.expectEqual(IPv4Address("172.20.10.1")?.raw, 0xAC14_0A01)
        }

        // inet_aton accepts all of these and would make the subnet ranks match
        // things they should not. "010.1.1.1" is octal to some parsers.
        Check.test("malformed and ambiguous addresses are rejected") {
            for text in ["10.1", "1.2.3.4.5", "256.1.1.1", "010.1.1.1",
                         "1.2.3.", "", "a.b.c.d", "1.2.3.-1", "0x1.2.3.4"] {
                Check.expectNil(IPv4Address(text), "should reject \(text)")
            }
        }

        Check.test("range membership respects the mask") {
            let range = IPv4Range(prefix: "172.20.10.0", bits: 28)
            Check.expectTrue(range.contains(IPv4Address("172.20.10.0")!))
            Check.expectTrue(range.contains(IPv4Address("172.20.10.15")!))
            Check.expectFalse(range.contains(IPv4Address("172.20.10.16")!))
        }
    }
}

// MARK: - Journal

func runSuppressionJournalTests() {
    Check.suite("SuppressionJournal") {

        func scratchJournal() -> (SuppressionJournal, URL) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("suppression-\(UUID().uuidString).json")
            return (SuppressionJournal(url: url), url)
        }

        let sparkleTarget = SuppressionRecord.Target.preference(domain: "org.videolan.vlc",
                                                                key: "SUEnableAutomaticChecks")

        // The unrecoverable case, now recoverable. Losing the journal while
        // suppressions are applied used to mean they stayed applied forever: the
        // suppressors skip a target whose value already equals theirs, so nothing
        // is re-recorded and revert has nothing to act on.
        Check.test("a lost journal is recovered from its backup") {
            let (journal, url) = scratchJournal()
            defer {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(
                    at: url.appendingPathExtension("backup"))
            }

            // Two saves, so a backup of the first exists alongside the second.
            try? journal.record(SuppressionRecord(target: sparkleTarget,
                                                  priorValue: .bool(true),
                                                  appliedValue: .bool(false)))
            try? journal.record(SuppressionRecord(
                target: .preference(domain: "com.example.two", key: "k"),
                priorValue: .int(5), appliedValue: .int(0)))

            // The primary is destroyed the way a truncated write would leave it.
            try? Data("{ not json".utf8).write(to: url)

            let reloaded = SuppressionJournal(url: url)
            Check.expectFalse(reloaded.isEmpty,
                              "a corrupt journal must fall back, not read as empty")
            Check.expectEqual(reloaded.record(for: sparkleTarget)?.priorValue,
                              .bool(true),
                              "the prior value has to survive, or nothing can be undone")
        }

        Check.test("a record survives a reload") {
            let (journal, url) = scratchJournal()
            defer { try? FileManager.default.removeItem(at: url) }

            try? journal.record(SuppressionRecord(target: sparkleTarget,
                                                  priorValue: .bool(true),
                                                  appliedValue: .bool(false)))
            // The write-ahead promise: it is on disk before the caller acts, so
            // a crash here still leaves a reverting instruction behind.
            let reloaded = SuppressionJournal(url: url)
            Check.expectEqual(reloaded.records.count, 1)
            Check.expectEqual(reloaded.record(for: sparkleTarget)?.priorValue, .bool(true))
        }

        Check.test("recording the same target twice does not duplicate it") {
            let (journal, url) = scratchJournal()
            defer { try? FileManager.default.removeItem(at: url) }

            try? journal.record(SuppressionRecord(target: sparkleTarget,
                                                  priorValue: .bool(true),
                                                  appliedValue: .bool(false)))
            try? journal.record(SuppressionRecord(target: sparkleTarget,
                                                  priorValue: .absent,
                                                  appliedValue: .bool(false)))
            Check.expectEqual(journal.records.count, 1)
        }

        Check.test("a value somebody else changed is not ours to restore") {
            let record = SuppressionRecord(target: sparkleTarget,
                                           priorValue: .bool(true),
                                           appliedValue: .bool(false))
            // Still what we wrote — safe to put back.
            Check.expectTrue(SuppressionJournal.revertible(record, currentValue: .bool(false)))
            // The user turned it back on themselves while metered. Restoring
            // `true` here would be right by accident; restoring is still wrong,
            // because the next case shows why the rule has to be mechanical.
            Check.expectFalse(SuppressionJournal.revertible(record, currentValue: .bool(true)))
            Check.expectFalse(SuppressionJournal.revertible(record, currentValue: .absent))
        }

        Check.test("absent is distinct from false") {
            // Restoring `absent` must remove the key, not write `false`: an app
            // that never had the flag should not end up holding one.
            Check.expectFalse(SuppressedValue.absent == SuppressedValue.bool(false))
            Check.expectNil(SuppressedValue.absent.plistValue)
        }

        Check.test("clearing removes only the named target") {
            let (journal, url) = scratchJournal()
            defer { try? FileManager.default.removeItem(at: url) }

            let other = SuppressionRecord.Target.configFile(
                path: "/tmp/settings.json", key: "update.mode")
            try? journal.record(SuppressionRecord(target: sparkleTarget,
                                                  priorValue: .bool(true),
                                                  appliedValue: .bool(false)))
            try? journal.record(SuppressionRecord(target: other,
                                                  priorValue: .bool(true),
                                                  appliedValue: .bool(false)))
            journal.clear(sparkleTarget)
            Check.expectEqual(journal.records.count, 1)
            Check.expectNotNil(journal.record(for: other))
        }

        Check.test("an unreadable journal reads as empty rather than fatal") {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("corrupt-\(UUID().uuidString).json")
            try? Data("not json".utf8).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            // Refusing to launch would strand the user with suppressions in
            // place and nothing able to lift them.
            Check.expectTrue(SuppressionJournal(url: url).isEmpty)
        }
    }
}

// MARK: - Preference suppressor

func runPreferenceSuppressorTests() {
    Check.suite("PreferenceSuppressor") {

        let suppressor = PreferenceSuppressor()
        // A domain owned by nothing, so the round trip touches no real app.
        let domain = "com.kevinabouhanna.NetworkMonitor.tests"
        let key = "SUEnableAutomaticChecks"

        Check.test("a value round-trips through CFPreferences") {
            suppressor.write(.bool(false), domain: domain, key: key)
            Check.expectEqual(suppressor.read(domain: domain, key: key), .bool(false))
            suppressor.write(.bool(true), domain: domain, key: key)
            Check.expectEqual(suppressor.read(domain: domain, key: key), .bool(true))
        }

        Check.test("restoring absent removes the key") {
            suppressor.write(.bool(false), domain: domain, key: key)
            suppressor.write(.absent, domain: domain, key: key)
            Check.expectEqual(suppressor.read(domain: domain, key: key), .absent)
        }

        // The revert path, end to end, against a real preference domain.
        //
        // Everything else in this suite tests `read`/`write` in isolation, and the
        // controller tests use a fake whose `revert()` only increments a counter.
        // So the code whose failure means "my Mac silently stopped updating" had
        // no coverage at all. These three drive `revert(journal:)` itself.
        func scratchJournal() -> (SuppressionJournal, URL) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("revert-\(UUID().uuidString).json")
            return (SuppressionJournal(url: url), url)
        }

        Check.test("revert restores a prior value and empties the journal") {
            let (journal, url) = scratchJournal()
            defer { try? FileManager.default.removeItem(at: url) }
            let target = SuppressionRecord.Target.preference(domain: domain, key: key)

            // The user had automatic checks on.
            suppressor.write(.bool(true), domain: domain, key: key)
            try? journal.record(SuppressionRecord(target: target,
                                                  priorValue: .bool(true),
                                                  appliedValue: .bool(false)))
            suppressor.write(.bool(false), domain: domain, key: key)

            suppressor.revert(journal: journal)
            Check.expectEqual(suppressor.read(domain: domain, key: key), .bool(true),
                              "their own setting must come back on")
            Check.expectNil(journal.record(for: target))
            suppressor.write(.absent, domain: domain, key: key)
        }

        // The asymmetry that matters most: a key that never existed has to be
        // *removed*, not set to `false`. Setting it would leave the app holding an
        // explicit "never check" it was never given.
        Check.test("revert removes a key that was absent before") {
            let (journal, url) = scratchJournal()
            defer { try? FileManager.default.removeItem(at: url) }
            let target = SuppressionRecord.Target.preference(domain: domain, key: key)

            suppressor.write(.absent, domain: domain, key: key)
            try? journal.record(SuppressionRecord(target: target,
                                                  priorValue: .absent,
                                                  appliedValue: .bool(false)))
            suppressor.write(.bool(false), domain: domain, key: key)

            suppressor.revert(journal: journal)
            Check.expectEqual(suppressor.read(domain: domain, key: key), .absent,
                              "an absent key must be removed, never set to false")
        }

        // Somebody else's later decision outranks ours, and this is the rule that
        // makes concurrent edits safe rather than a race.
        Check.test("revert leaves a value the user changed after we did") {
            let (journal, url) = scratchJournal()
            defer { try? FileManager.default.removeItem(at: url) }
            let target = SuppressionRecord.Target.preference(domain: domain, key: key)

            try? journal.record(SuppressionRecord(target: target,
                                                  priorValue: .bool(true),
                                                  appliedValue: .bool(false)))
            // The user has since turned it off themselves, deliberately.
            suppressor.write(.int(42), domain: domain, key: key)

            suppressor.revert(journal: journal)
            Check.expectEqual(suppressor.read(domain: domain, key: key), .int(42),
                              "their change wins; ours is forgotten")
            Check.expectNil(journal.record(for: target))
            suppressor.write(.absent, domain: domain, key: key)
        }

        Check.test("a string value round-trips, for Microsoft AutoUpdate") {
            suppressor.write(.string("Manual"), domain: domain, key: "HowToCheck")
            Check.expectEqual(suppressor.read(domain: domain, key: "HowToCheck"),
                              .string("Manual"))
            suppressor.write(.absent, domain: domain, key: "HowToCheck")
        }

        Check.test("a boolean reads back as a boolean, not a number") {
            // CFBoolean arrives as NSNumber. Were it recorded as .string or an
            // int, "is this still what we wrote" would fail on every revert and
            // nothing would ever be restored.
            suppressor.write(.bool(false), domain: domain, key: key)
            let read = suppressor.read(domain: domain, key: key)
            if case .bool = read {} else { Check.expectTrue(false, "expected .bool, got \(read)") }
            suppressor.write(.absent, domain: domain, key: key)
        }

        Check.test("discovery finds real Sparkle apps without crashing") {
            // Environment-dependent by nature, so this asserts the shape rather
            // than a count: every discovered target must name a domain and a key.
            for target in suppressor.targets() {
                Check.expectFalse(target.domain.isEmpty)
                Check.expectFalse(target.key.isEmpty)
                Check.expectFalse(target.displayName.isEmpty)
            }
        }
    }
}

// MARK: - Controller

/// Records what it was asked to do, so the controller's ordering can be checked
/// without touching anything real.
final class FakeSuppressor: UpdateSuppressor {
    let name = "Fake"
    var applyCount = 0
    var revertCount = 0
    /// Order of calls, which is what the replay-then-re-evaluate rule is about.
    var calls: [String] = []

    /// Ids this fake was told to leave alone on the most recent pass.
    var lastExcluded: Set<String> = []

    func discover() -> [CoveredItem] {
        [CoveredItem(id: "fake/thing", displayName: "Thing", mechanism: "Fake")]
    }

    func apply(journal: SuppressionJournal, excluding: Set<String>) -> SuppressionResult {
        lastExcluded = excluding
        var result = SuppressionResult()
        guard !excluding.contains("fake/thing") else { return result }
        applyCount += 1
        calls.append("apply")
        result.applied = ["Thing"]
        return result
    }

    func revert(journal: SuppressionJournal) {
        revertCount += 1
        calls.append("revert")
    }
}

func runMeteringControllerTests() {
    Check.suite("MeteringController") {

        /// Also hands back the store, for the tests that have to move the machine
        /// to a different network partway through.
        func makeControllerWithStore(enabled: Bool,
                                     fingerprint: NetworkFingerprint)
        -> (MeteringController, FakeSuppressor, UsageStore, [URL]) {
            let storeURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("usage-\(UUID().uuidString).json")
            let journalURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("journal-\(UUID().uuidString).json")
            let store = UsageStore(storeURL: storeURL)
            store.setCurrentNetwork(fingerprint)

            let defaults = UserDefaults(suiteName: "netmon.tests.\(UUID().uuidString)")!
            defaults.set(enabled, forKey: MeteringController.enabledKey)

            let fake = FakeSuppressor()
            let controller = MeteringController(
                store: store,
                journal: SuppressionJournal(url: journalURL),
                suppressors: [fake],
                defaults: defaults)
            return (controller, fake, store, [storeURL, journalURL])
        }

        func makeController(enabled: Bool,
                            fingerprint: NetworkFingerprint)
        -> (MeteringController, FakeSuppressor, [URL]) {
            let (controller, fake, _, urls) =
                makeControllerWithStore(enabled: enabled, fingerprint: fingerprint)
            return (controller, fake, urls)
        }

        let hotspot = NetworkFingerprint.make(kind: .hotspot,
                                              gatewayMAC: "9a:50:2e:c2:af:64",
                                              interfaceName: "en0",
                                              isExpensive: true,
                                              isConstrained: false)
        let home = NetworkFingerprint.make(kind: .wifi,
                                           gatewayMAC: "50:c7:bf:8a:94:93",
                                           interfaceName: "en0",
                                           isExpensive: false,
                                           isConstrained: false,
                                           gatewayIP: "192.168.1.1",
                                           interfaceDisplayName: "Wi-Fi")

        Check.test("a metered network with the setting on suppresses") {
            let (controller, fake, urls) = makeController(enabled: true, fingerprint: hotspot)
            defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
            controller.evaluate()
            Check.expectTrue(controller.isSuppressing)
            Check.expectEqual(controller.verdict, .expensive)
            Check.expectEqual(fake.applyCount, 1)
        }

        Check.test("a metered network with the setting off does nothing") {
            let (controller, fake, urls) = makeController(enabled: false, fingerprint: hotspot)
            defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
            controller.evaluate()
            Check.expectFalse(controller.isSuppressing)
            Check.expectEqual(fake.applyCount, 0)
        }

        Check.test("an unmetered network with the setting on does nothing") {
            let (controller, fake, urls) = makeController(enabled: true, fingerprint: home)
            defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
            controller.evaluate()
            Check.expectFalse(controller.isSuppressing)
            Check.expectEqual(fake.applyCount, 0)
            Check.expectEqual(controller.verdict, .unmetered)
        }

        Check.test("switching the setting off lifts suppression immediately") {
            let (controller, fake, urls) = makeController(enabled: true, fingerprint: hotspot)
            defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
            controller.evaluate()
            Check.expectTrue(controller.isSuppressing)
            controller.isEnabled = false
            Check.expectFalse(controller.isSuppressing)
            Check.expectTrue(fake.revertCount >= 1)
        }

        // The ordering rule the whole feature rests on. Replaying the journal at
        // launch without re-evaluating would hand the updates back while still
        // sitting on the hotspot.
        Check.test("start replays the journal, then re-evaluates, then re-applies") {
            let (controller, fake, urls) = makeController(enabled: true, fingerprint: hotspot)
            defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
            controller.start()
            Check.expectEqual(fake.calls.first, "revert")
            Check.expectTrue(fake.calls.contains("apply"))
            Check.expectTrue(controller.isSuppressing)
            controller.stop()
        }

        // The per-app opt-out. Switching one app off has to put *that app* back,
        // not merely stop suppressing it on the next pass.
        Check.test("switching one app off reverts it and stops re-applying it") {
            let (controller, fake, urls) = makeController(enabled: true, fingerprint: hotspot)
            defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

            controller.evaluate()
            Check.expectEqual(fake.applyCount, 1)
            Check.expectTrue(controller.isSuppressionEnabled(for: "fake/thing"))

            controller.setSuppressionEnabled(false, for: "fake/thing")
            Check.expectFalse(controller.isSuppressionEnabled(for: "fake/thing"))
            Check.expectTrue(fake.revertCount >= 1,
                             "switching an app off must restore it immediately")
            Check.expectEqual(fake.lastExcluded, ["fake/thing"])

            // Still on a hotspot: further passes must leave it alone.
            let appliesWhileExcluded = fake.applyCount
            controller.evaluate()
            Check.expectEqual(fake.applyCount, appliesWhileExcluded,
                              "an excluded app must not be re-suppressed")

            controller.setSuppressionEnabled(true, for: "fake/thing")
            Check.expectTrue(fake.applyCount > appliesWhileExcluded,
                             "switching it back on must suppress it again")
            Check.expectTrue(controller.excluded.isEmpty)
        }

        // A phone hotspot drops every time the phone sleeps. Treating that gap as
        // an unmetered network lifted every suppression and re-applied it seconds
        // later — rewriting each app's preferences on every blip, and leaving the
        // reconnect uncovered at the one moment a queued check fires.
        Check.test("a dropout to offline holds suppression instead of lifting it") {
            let (controller, fake, store, urls) =
                makeControllerWithStore(enabled: true, fingerprint: hotspot)
            defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

            controller.evaluate()
            Check.expectTrue(controller.isSuppressing)
            let revertsBeforeDropout = fake.revertCount

            store.setCurrentNetwork(.offline)
            controller.networkDidChange()

            Check.expectTrue(controller.isSuppressing,
                             "a dropout must not hand the updates back")
            Check.expectEqual(fake.revertCount, revertsBeforeDropout)
            Check.expectEqual(controller.verdict, .expensive,
                              "the verdict should hold, not flip to unmetered")

            // Coming back to the same hotspot must not have needed a revert first.
            store.setCurrentNetwork(hotspot)
            controller.networkDidChange()
            Check.expectTrue(controller.isSuppressing)
            Check.expectEqual(fake.revertCount, revertsBeforeDropout)
        }

        // The other direction: offline must not *start* anything either, or a
        // launch with no link would apply against a verdict it cannot compute.
        Check.test("offline at launch neither applies nor reverts") {
            let (controller, fake, urls) =
                makeController(enabled: true, fingerprint: .offline)
            defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
            controller.evaluate()
            Check.expectFalse(controller.isSuppressing)
            Check.expectEqual(fake.applyCount, 0)
        }

        Check.test("an override marks an ordinary network metered") {
            let (controller, fake, urls) = makeController(enabled: true, fingerprint: home)
            defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
            controller.evaluate()
            Check.expectFalse(controller.isSuppressing)

            controller.setOverride(true)
            Check.expectEqual(controller.verdict, .userMarked)
            Check.expectTrue(controller.isSuppressing)
            Check.expectEqual(fake.applyCount, 1)
        }

        Check.test("an override can also clear a network the heuristic flagged") {
            let (controller, fake, urls) = makeController(enabled: true, fingerprint: hotspot)
            defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
            controller.evaluate()
            Check.expectTrue(controller.isSuppressing)

            controller.setOverride(false)
            Check.expectEqual(controller.verdict, .userCleared)
            Check.expectFalse(controller.isSuppressing)
            Check.expectTrue(fake.revertCount >= 1)
        }

        Check.test("the override survives in the store, keyed by network") {
            let storeURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("usage-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: storeURL) }
            let store = UsageStore(storeURL: storeURL)
            store.setCurrentNetwork(home)
            store.setMeteredOverride(true, for: home.id)

            // Marking a network metered must not wipe its history, which is why
            // the override lives beside the buckets and not inside the
            // fingerprint that decides when to reset one.
            let reloaded = UsageStore(storeURL: storeURL)
            Check.expectEqual(reloaded.meteredOverride(for: home.id), true)
            Check.expectNil(reloaded.meteredOverride(for: hotspot.id))
        }
    }
}

// MARK: - /etc/hosts editing

func runHostsFileTests() {
    Check.suite("HostsFile") {

        // A realistic starting point: the stock macOS file.
        let stock = """
        ##
        # Host Database
        ##
        127.0.0.1\tlocalhost
        255.255.255.255\tbroadcasthost
        ::1             localhost

        """

        Check.test("applying adds a delimited block and keeps the original") {
            let result = HostsFile.applying(["update.code.visualstudio.com"], to: stock)
            Check.expectTrue(result.hasPrefix(stock), "user's own entries must be untouched")
            Check.expectTrue(result.contains("0.0.0.0\tupdate.code.visualstudio.com"))
            Check.expectTrue(HostsFile.containsBlock(result))
        }

        Check.test("both address families are blocked") {
            // A name blocked only on IPv4 still resolves over IPv6 and the app
            // connects anyway, which would look like the feature silently
            // failing.
            let result = HostsFile.applying(["downloads.claude.ai"], to: stock)
            Check.expectTrue(result.contains("0.0.0.0\tdownloads.claude.ai"))
            Check.expectTrue(result.contains("::1\tdownloads.claude.ai"))
        }

        Check.test("removing the block restores the file byte for byte") {
            let applied = HostsFile.applying(["a.example", "b.example"], to: stock)
            Check.expectEqual(HostsFile.withoutBlock(applied), stock)
        }

        Check.test("applying twice is idempotent") {
            let once = HostsFile.applying(["a.example"], to: stock)
            let twice = HostsFile.applying(["a.example"], to: once)
            Check.expectEqual(once, twice, "repeat application must not stack blocks")
            Check.expectEqual(HostsFile.withoutBlock(twice), stock)
        }

        Check.test("changing the host list replaces rather than appends") {
            let first = HostsFile.applying(["old.example"], to: stock)
            let second = HostsFile.applying(["new.example"], to: first)
            Check.expectFalse(second.contains("old.example"))
            Check.expectTrue(second.contains("new.example"))
            Check.expectEqual(HostsFile.withoutBlock(second), stock)
        }

        Check.test("a file with no block is returned unchanged") {
            Check.expectEqual(HostsFile.withoutBlock(stock), stock)
            Check.expectFalse(HostsFile.containsBlock(stock))
        }

        Check.test("a truncated block is removed rather than half-left") {
            // A crash between writing the block and finishing could leave a
            // begin marker with no end. Guessing where it ended could strand
            // live 0.0.0.0 entries, which breaks a hostname permanently with
            // nothing to point at.
            let broken = stock + HostsFile.beginMarker + "\n0.0.0.0\ta.example\n"
            let cleaned = HostsFile.withoutBlock(broken)
            Check.expectFalse(cleaned.contains("a.example"))
            Check.expectFalse(cleaned.contains(HostsFile.beginMarker))
        }

        Check.test("entries after the block survive its removal") {
            let applied = HostsFile.applying(["a.example"], to: stock)
            let withTail = applied + "10.0.0.5\tnas.local\n"
            let cleaned = HostsFile.withoutBlock(withTail)
            Check.expectTrue(cleaned.contains("10.0.0.5\tnas.local"),
                             "a user entry added after the block must survive")
            Check.expectFalse(cleaned.contains("a.example"))
        }

        Check.test("an empty file gains a well-formed block") {
            let result = HostsFile.applying(["a.example"], to: "")
            Check.expectTrue(result.hasPrefix(HostsFile.beginMarker))
            Check.expectTrue(result.hasSuffix("\n"))
            Check.expectEqual(HostsFile.withoutBlock(result), "")
        }

        Check.test("a file with no trailing newline is not run together") {
            let noNewline = "127.0.0.1\tlocalhost"
            let result = HostsFile.applying(["a.example"], to: noNewline)
            Check.expectTrue(result.contains("localhost\n" + HostsFile.beginMarker),
                             "block must start on its own line")
        }
    }
}

// MARK: - Surgical JSON config editing

/// `ConfigFileSuppressor.revert()` end to end against a temporary file.
///
/// Previously only its `JSONConfigEdit` helper was covered, so the code that
/// actually decides whether the user's `settings.json` gets its line taken back
/// out was untested — on the tier that edits a file rather than a preference.
func runConfigFileSuppressorTests() {
    Check.suite("ConfigFileSuppressor revert") {

        let suppressor = ConfigFileSuppressor()
        let key = "update.mode"
        let applied = "\"none\""

        func scratchFile(_ contents: String) -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("cfg-\(UUID().uuidString).json")
            try? contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        func scratchJournal() -> (SuppressionJournal, URL) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("cfg-journal-\(UUID().uuidString).json")
            return (SuppressionJournal(url: url), url)
        }

        // CRLF and two-space indent, like the real VS Code file on this machine,
        // so a revert that normalised line endings would be caught.
        let original = "{\r\n  \"editor.formatOnSave\": true,\r\n  \"files.eol\": \"\\n\"\r\n}"

        Check.test("revert removes our line and restores the file byte for byte") {
            let file = scratchFile(original)
            let (journal, journalURL) = scratchJournal()
            defer {
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: journalURL)
            }
            let target = SuppressionRecord.Target.configFile(path: file.path, key: key)

            let edited = JSONConfigEdit.inserting(key: key, literal: applied,
                                                  into: original)!
            try? edited.write(to: file, atomically: true, encoding: .utf8)
            try? journal.record(SuppressionRecord(target: target,
                                                  priorValue: .absent,
                                                  appliedValue: .string(applied)))

            suppressor.revert(journal: journal)
            let after = try? String(contentsOf: file, encoding: .utf8)
            Check.expectEqual(after, original,
                              "the user's file must come back exactly as it was")
            Check.expectNil(journal.record(for: target))
        }

        Check.test("revert leaves a value the user changed themselves") {
            let mine = JSONConfigEdit.inserting(key: key, literal: "\"manual\"",
                                                 into: original)!
            let file = scratchFile(mine)
            let (journal, journalURL) = scratchJournal()
            defer {
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: journalURL)
            }
            let target = SuppressionRecord.Target.configFile(path: file.path, key: key)
            // We recorded "none", but the file now says "manual".
            try? journal.record(SuppressionRecord(target: target,
                                                  priorValue: .absent,
                                                  appliedValue: .string(applied)))

            suppressor.revert(journal: journal)
            let after = try? String(contentsOf: file, encoding: .utf8)
            Check.expectEqual(after, mine,
                              "their deliberate setting must not be deleted")
        }

        // A file that vanished between apply and revert must not crash or leave a
        // record behind that would be retried forever.
        Check.test("a missing file clears its record without failing") {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("gone-\(UUID().uuidString).json")
            let (journal, journalURL) = scratchJournal()
            defer { try? FileManager.default.removeItem(at: journalURL) }
            let target = SuppressionRecord.Target.configFile(path: file.path, key: key)
            try? journal.record(SuppressionRecord(target: target,
                                                  priorValue: .absent,
                                                  appliedValue: .string(applied)))

            suppressor.revert(journal: journal)
            Check.expectNil(journal.record(for: target))
        }
    }
}

func runJSONConfigEditTests() {
    Check.suite("JSONConfigEdit") {

        let plain = """
        {
            "editor.fontSize": 13,
            "workbench.colorTheme": "Default Dark+"
        }
        """

        Check.test("a key is read back as its literal") {
            Check.expectEqual(JSONConfigEdit.value(of: "editor.fontSize", in: plain), "13")
            Check.expectEqual(JSONConfigEdit.value(of: "workbench.colorTheme", in: plain),
                              "\"Default Dark+\"")
            Check.expectNil(JSONConfigEdit.value(of: "update.mode", in: plain))
        }

        Check.test("inserting adds the key and leaves the rest byte-identical") {
            let edited = JSONConfigEdit.inserting(key: "update.mode",
                                                  literal: "\"none\"", into: plain)!
            Check.expectEqual(JSONConfigEdit.value(of: "update.mode", in: edited), "\"none\"")
            Check.expectTrue(edited.contains("\"editor.fontSize\": 13"))
            Check.expectTrue(edited.contains("\"workbench.colorTheme\": \"Default Dark+\""))
        }

        Check.test("insert then remove restores the file exactly") {
            let edited = JSONConfigEdit.inserting(key: "update.mode",
                                                  literal: "\"none\"", into: plain)!
            Check.expectEqual(JSONConfigEdit.removing(key: "update.mode", from: edited), plain)
        }

        // VS Code's settings.json is JSONC. Parsing and re-emitting it would
        // drop the user's comments and reorder 81 keys — a destructive change
        // to a file we were only asked to add one line to.
        Check.test("comments and formatting survive a round trip") {
            let jsonc = """
            {
                // my favourite size
                "editor.fontSize": 13,

                /* block comment */
                "files.autoSave": "afterDelay",
            }
            """
            let edited = JSONConfigEdit.inserting(key: "update.mode",
                                                  literal: "\"none\"", into: jsonc)!
            Check.expectTrue(edited.contains("// my favourite size"))
            Check.expectTrue(edited.contains("/* block comment */"))
            Check.expectEqual(JSONConfigEdit.removing(key: "update.mode", from: edited), jsonc)
        }

        Check.test("an empty object gets no stray comma") {
            let edited = JSONConfigEdit.inserting(key: "update.mode",
                                                  literal: "\"none\"", into: "{}")!
            Check.expectFalse(edited.contains(","), "no following entry means no comma")
            Check.expectEqual(JSONConfigEdit.removing(key: "update.mode", from: edited), "{}")
        }

        Check.test("removing a key that is not there changes nothing") {
            Check.expectEqual(JSONConfigEdit.removing(key: "update.mode", from: plain), plain)
        }

        Check.test("a boolean literal works, for Claude's disableAutoUpdates") {
            let edited = JSONConfigEdit.inserting(key: "disableAutoUpdates",
                                                  literal: "true", into: plain)!
            Check.expectEqual(JSONConfigEdit.value(of: "disableAutoUpdates", in: edited), "true")
            Check.expectEqual(JSONConfigEdit.removing(key: "disableAutoUpdates", from: edited),
                              plain)
        }

        // The real file on this machine, if present: 81 keys, and the round
        // trip has to be exact on it specifically.
        Check.test("the real VS Code settings.json round-trips exactly") {
            let path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Code/User/settings.json")
            guard let onDisk = try? String(contentsOf: path, encoding: .utf8) else {
                return
            }
            // Strip the key before measuring anything. `ConfigFileSuppressor` may
            // be holding this very file down right now — on a hotspot with
            // metering on, it is — and then the file already carries
            // `update.mode`, so inserting and removing would correctly return a
            // file *without* it and fail against an "original" that had it.
            //
            // Asserting against a baseline instead of the raw bytes keeps the test
            // measuring what it is named after: that a round trip on this
            // machine's real, messy, 81-key file is exact. It just no longer
            // reports the feature working as a test failure.
            let baseline = JSONConfigEdit.removing(key: "update.mode", from: onDisk) ?? onDisk

            guard let edited = JSONConfigEdit.inserting(key: "update.mode",
                                                        literal: "\"none\"", into: baseline)
            else { Check.expectTrue(false, "insertion failed on the real file"); return }
            Check.expectEqual(JSONConfigEdit.value(of: "update.mode", in: edited), "\"none\"")
            Check.expectEqual(JSONConfigEdit.removing(key: "update.mode", from: edited), baseline,
                              "the user's own settings file must come back untouched")
        }
    }
}

// MARK: - Preference value typing

func runSuppressedValueTests() {
    Check.suite("SuppressedValue typing") {

        let suppressor = PreferenceSuppressor()
        let domain = "com.kevinabouhanna.NetworkMonitor.tests"

        // The bug this exists to prevent: Chrome's Keystone `checkInterval` is
        // a number (18000). Read through NSNumber.boolValue it becomes `true`,
        // and restoring would write `true` into a numeric setting — corrupting
        // a preference this app does not own.
        Check.test("a number round-trips as a number, not a boolean") {
            suppressor.write(.int(18000), domain: domain, key: "checkInterval")
            let read = suppressor.read(domain: domain, key: "checkInterval")
            Check.expectEqual(read, .int(18000))
            suppressor.write(.absent, domain: domain, key: "checkInterval")
        }

        Check.test("a boolean still round-trips as a boolean") {
            suppressor.write(.bool(false), domain: domain, key: "flag")
            Check.expectEqual(suppressor.read(domain: domain, key: "flag"), .bool(false))
            suppressor.write(.bool(true), domain: domain, key: "flag")
            Check.expectEqual(suppressor.read(domain: domain, key: "flag"), .bool(true))
            suppressor.write(.absent, domain: domain, key: "flag")
        }

        Check.test("zero is not confused with false") {
            suppressor.write(.int(0), domain: domain, key: "checkInterval")
            Check.expectEqual(suppressor.read(domain: domain, key: "checkInterval"), .int(0))
            Check.expectFalse(suppressor.read(domain: domain, key: "checkInterval") == .bool(false))
            suppressor.write(.absent, domain: domain, key: "checkInterval")
        }
    }
}
