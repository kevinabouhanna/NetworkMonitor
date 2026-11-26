import Foundation
@testable import NetworkMonitorCore

func runBackgroundDownloadsTests() {
    let midnight = Date(timeIntervalSince1970: 1_798_761_600)
    let source = "/usr/libexec/nsurlsessiond"
    let zero = ByteCounts(bytesIn: 0, bytesOut: 0)
    let bytes = ByteCounts(bytesIn: 100, bytesOut: 10)

    func socket(_ port: Int, counts: ByteCounts) -> BackgroundSocket {
        let key = BackgroundSocket.Key(pid: 42, interface: "en0", transport: .quic,
                                       local: BackgroundSocket.Address("192.0.2.4")!, localPort: port, remotePort: 443)
        return BackgroundSocket(key: key, peer: BackgroundSocket.Address("203.0.113.8")!, counts: counts)
    }

    func close(_ port: Int, owner: String?, at time: Date, duration: Double = 9,
               interface: String = "en0", local: String = "192.0.2.4",
               peer: String = "IPv4#bead") -> BackgroundDownloads.CloseRecord? {
        let tag = owner.map { ", bundle id: \($0)" } ?? ""
        return BackgroundDownloads.CloseRecord.parse(pid: 42, time: time, message: """
            [C17 01234567-89AB-CDEF-0123-456789ABCDEF IPv4#bead:443 quic-connection\(tag), url hash: 11111111] cancelled
                [C17.1.1.1 01234567-89AB-CDEF-0123-456789ABCDEF \(local):\(port)<->\(peer):443]
                Connected Path: satisfied, viable, interface: \(interface)[802.11], ipv4
                Duration: \(duration)s, QUIC @0.000s took 0.000s
                bytes in/out: 99999/99999, packets in/out: 20/2
            """)
    }

    Check.suite("Background URLSession — sockets and ownership") {
        Check.test("nettop retains direct internet sockets for the daemon, including quiet ones") {
            var parser = NettopParser()
            _ = parser.consume("""
                time,,interface,bytes_in,bytes_out,
                11:59:59,nsurlsessiond.42,,1000,100,
                time,,interface,bytes_in,bytes_out,
                12:00:00,nsurlsessiond.42,,600,60,
                12:00:00,quic4 192.0.2.4:51000<->203.0.113.8:443,en0,100,10,
                12:00:00,tcp4 192.0.2.4:51001<->203.0.113.8:443,en0,0,0,
                12:00:00,tcp4 192.0.2.4:51002<->192.168.0.1:443,en0,100,10,
                12:00:00,tcp4 192.0.2.4:51003<->203.0.113.8:443,utun2,100,10,
                12:00:00,OtherApp.43,,600,60,
                12:00:00,quic4 192.0.2.4:52000<->203.0.113.8:443,en0,100,10,
                """ + "\n")
            let rows = parser.flush() ?? []
            Check.expectEqual(rows.first?.backgroundSockets.map(\.key.localPort), [51000, 51001])
            Check.expectEqual(rows.first?.backgroundSockets.last?.counts, zero)
            Check.expectEqual(rows.last?.backgroundSockets.count, 0)
            guard var daemon = rows.first else { return Check.expectTrue(false, "no daemon row") }
            let identity = AppIdentity(key: source, displayName: "nsurlsessiond", bundlePath: nil, isSystem: true)
            let summary = SampleSummary([daemon]) { _ in identity }
            Check.expectEqual(summary.backgroundDownloads.first?.source, source)
            daemon.localBytesIn = daemon.bytesIn - 1
            let inconsistent = SampleSummary([daemon]) { _ in identity }
            Check.expectNil(inconsistent.backgroundDownloads.first?.source, "socket credit exceeds the daemon's recorded bytes")
        }

        Check.test("two concurrent sockets get distinct owners and keep their original slots") {
            var tracker = BackgroundDownloads()
            let first = UsageHistory.AppSlot(hour: 1, session: 10, generation: 0)
            let second = UsageHistory.AppSlot(hour: 2, session: 11, generation: 0)
            let a = socket(51_000, counts: bytes)
            let b = socket(51_001, counts: ByteCounts(bytesIn: 20, bytesOut: 1))
            Check.expectTrue(tracker.update([.init(sockets: [a, b], source: source)],
                                            slot: first, now: midnight - 1).isEmpty)
            Check.expectTrue(tracker.update([.init(sockets: [a, b], source: source)],
                                            slot: second, now: midnight).isEmpty)
            let ended = tracker.update([], slot: nil, now: midnight + 1)
            let records = [close(51_000, owner: "com.example.first", at: midnight + 0.2)!,
                           close(51_001, owner: "com.example.second", at: midnight + 0.4)!]
            Check.expectEqual(ended.count, 2)
            for socket in ended {
                let index = socket.key.localPort - 51_000
                Check.expectEqual(BackgroundDownloads.owner(for: socket, in: records + records), records[index].owner)
                Check.expectEqual(Set(socket.charges.keys.map(\.slot)), Set([first, second]))
                Check.expectEqual(socket.charges[.init(slot: first, source: source)], index == 0 ? a.counts : b.counts)
            }
            Check.expectTrue(tracker.update([], slot: nil, now: midnight + 2).isEmpty)
        }

        Check.test("incorrect lifetimes, interfaces, and ambiguous owners are left under the daemon") {
            var tracker = BackgroundDownloads()
            let slot = UsageHistory.AppSlot(hour: 1, session: 10, generation: 0)
            _ = tracker.update([.init(sockets: [socket(51_000, counts: bytes)], source: source)],
                               slot: slot, now: midnight)
            let ended = tracker.update([], slot: nil, now: midnight + 1)
            guard let socket = ended.first else { return Check.expectTrue(false, "no closed socket") }
            let report = close(51_000, owner: "com.example.first", at: midnight + 0.5)!
            Check.expectNil(BackgroundDownloads.owner(for: socket, in: []))
            Check.expectNil(BackgroundDownloads.owner(for: socket, in: [
                close(51_000, owner: "com.example.reused", at: midnight + 0.6, duration: 0.1)!]))
            Check.expectNil(BackgroundDownloads.owner(for: socket, in: [
                close(51_000, owner: "com.example.other", at: midnight + 0.5, interface: "en1")!]))
            Check.expectNil(BackgroundDownloads.owner(for: socket, in: [
                report, close(51_000, owner: "com.example.other", at: midnight + 0.6)!]))
            Check.expectEqual(BackgroundDownloads.owner(for: socket, in: [report]), "com.example.first")
            Check.expectNil(BackgroundDownloads.owner(for: socket, in: [
                close(51_000, owner: "com.example.other", at: midnight + 0.5, local: "192.0.2.5")!]))
            Check.expectNil(BackgroundDownloads.owner(for: socket, in: [
                close(51_000, owner: "com.example.other", at: midnight + 0.5, peer: "203.0.113.20")!]))
            Check.expectNil(BackgroundDownloads.owner(for: socket, in: [
                report, close(51_000, owner: nil, at: midnight + 0.5)!]))
        }

        Check.test("IPv6 spelling and zone do not change the local address's identity") {
            let report = close(51_000, owner: "com.example.first", at: midnight + 0.5,
                               local: "[2001:0db8:0:0::1%en0]", peer: "IPv6#bead")
            Check.expectEqual(report?.key.local, BackgroundSocket.Address("2001:db8::1"))
        }

        Check.test("a simultaneous collision or samples with no eligible bytes create no credit") {
            var tracker = BackgroundDownloads()
            let slot = UsageHistory.AppSlot(hour: 1, session: 10, generation: 0)
            let a = socket(51_000, counts: bytes)
            _ = tracker.update([.init(sockets: [a], source: source)], slot: slot, now: midnight)
            _ = tracker.update([.init(sockets: [a, a], source: source)], slot: slot, now: midnight + 1)
            _ = tracker.update([.init(sockets: [a], source: nil)], slot: slot, now: midnight + 2)
            Check.expectTrue(tracker.update([], slot: nil, now: midnight + 3).isEmpty)
        }

        Check.test("a socket across more hours than it may span stays whole under the daemon") {
            var tracker = BackgroundDownloads()
            let a = socket(51_000, counts: bytes)
            for hour in 0...BackgroundDownloads.maxCharges {
                _ = tracker.update([.init(sockets: [a], source: source)],
                                   slot: UsageHistory.AppSlot(hour: Int64(hour), session: 10, generation: 0),
                                   now: midnight + Double(hour))
            }
            Check.expectTrue(tracker.update([], slot: nil, now: midnight + 100).isEmpty,
                             "none of it moves, rather than the first hours only")
        }

        Check.test("an app's own copy is found by bundle ID; nsurlsessiond itself never is") {
            Check.expectNil(AppIdentityResolver.backgroundOwner(bundleID: "com.apple.nsurlsessiond"))
            Check.expectNil(AppIdentityResolver.backgroundOwner(bundleID: "com.example.no-such-app-\(UUID().uuidString)"))
            // A service with no app, by its running program and signature.
            // launchd always runs, and is signed com.apple.xpc.launchd.
            Check.expectEqual(AppIdentityResolver.runningProgram(signedAs: "com.apple.xpc.launchd"), "/sbin/launchd")
            Check.expectNil(AppIdentityResolver.runningProgram(signedAs: "com.example.launchd"),
                            "the right name with another signature")
        }
    }

    Check.suite("Background URLSession — Usage History") {
        Check.test("reassignment preserves direction totals and the exact original network and hour") {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("background-history-\(UUID()).sqlite")
            defer {
                for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
            }
            let history = UsageHistory(databaseURL: url, calendar: calendar)
            let daemon = AppIdentity(key: source, displayName: "nsurlsessiond", bundlePath: nil, isSystem: true)
            let owner = AppIdentity(key: "/Applications/Example.app", displayName: "Example",
                                    bundlePath: "/Applications/Example.app", isSystem: false)
            func network(_ id: String) -> NetworkFingerprint {
                NetworkFingerprint(id: id, kind: .wifi, gatewayMAC: id, defaultLabel: id,
                                   isExpensive: false, isConstrained: false)
            }
            func record(_ time: Date) -> UsageHistory.AppSlot {
                history.recordInterface(bytesIn: 170, bytesOut: 15, now: time)
                return history.recordAppSample([(daemon, 170, 15)], servers: [:],
                                               localBytesIn: 0, localBytesOut: 0,
                                               backgroundDownloads: nil, now: time)!
            }
            func report(_ time: Date) -> HistoryReport {
                history.report(for: HistoryPeriod(scale: .day, containing: time, calendar: calendar))
            }
            let boundary = calendar.startOfDay(for: midnight)
            history.join(network("first"), label: "first", switched: false, now: boundary - 1)
            let first = record(boundary - 1)
            history.flush(now: boundary - 1)
            history.join(network("second"), label: "second", switched: true, now: boundary)
            let second = record(boundary)
            history.recordBackgroundOwner(owner, charges: [
                .init(slot: first, source: source): bytes,
                .init(slot: second, source: source): ByteCounts(bytesIn: 30, bytesOut: 4),
            ])
            let before = report(boundary - 1)
            let after = report(boundary)
            Check.expectEqual(before.appRowsForTest("Example"), ByteCounts(bytesIn: 100, bytesOut: 10))
            Check.expectEqual(after.appRowsForTest("Example"), ByteCounts(bytesIn: 30, bytesOut: 4))
            Check.expectEqual(before.systemRows.first?.total, 75)
            Check.expectEqual(after.systemRows.first?.total, 151)
            Check.expectEqual([before.total, after.total], [185, 185])
            Check.expectEqual(before.networks.map(\.id), ["first"])
            Check.expectEqual(after.networks.map(\.id), ["second"])

            history.recordBackgroundOwner(owner, charges: [
                .init(slot: second, source: source): ByteCounts(bytesIn: 160, bytesOut: 1)])
            Check.expectEqual(report(boundary).appRowsForTest("Example"), ByteCounts(bytesIn: 30, bytesOut: 4))
            history.clear(now: boundary)
            _ = record(boundary)
            history.recordBackgroundOwner(owner, charges: [.init(slot: second, source: source): bytes])
            Check.expectTrue(report(boundary).apps.isEmpty, "a correction from before Clear History was applied")
        }

        Check.test("a rolled-back sample cannot debit an earlier row in the same hour") {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("background-rollback-\(UUID()).sqlite")
            defer {
                for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
            }
            let history = UsageHistory(databaseURL: url)
            let daemon = AppIdentity(key: source, displayName: "nsurlsessiond", bundlePath: nil, isSystem: true)
            let owner = AppIdentity(key: "/Applications/Example.app", displayName: "Example",
                                    bundlePath: "/Applications/Example.app", isSystem: false)
            let time = Calendar.current.startOfDay(for: Date()) + 60
            history.recordApps([(daemon, 170, 15)], now: time)
            history.flush(now: time)

            do {
                let connection = try SQLiteDatabase(url: url)
                try connection.execute("""
                    CREATE TRIGGER fail_sample BEFORE INSERT ON app_traffic WHEN NEW.bytes_in = 42
                    BEGIN SELECT RAISE(ABORT, 'test rollback'); END;
                    """)
                let slot = history.recordAppSample([(daemon, 42, 1)], servers: [:], localBytesIn: 0,
                                                   localBytesOut: 0, backgroundDownloads: nil, now: time + 1)
                guard let slot else { return Check.expectTrue(false, "no slot for the failed sample") }
                history.flush(now: time + 1)
                try connection.execute("DROP TRIGGER fail_sample")

                history.recordBackgroundOwner(owner, charges: [
                    .init(slot: slot, source: source): ByteCounts(bytesIn: 42, bytesOut: 1),
                ])
                let report = history.report(for: HistoryPeriod(scale: .day, containing: time))
                Check.expectEqual(report.systemRows.first?.total, 185)
                Check.expectTrue(report.apps.isEmpty, "the failed sample debited earlier traffic")
            } catch {
                Check.expectTrue(false, "could not set up rollback fixture: \(error)")
            }
        }
    }
}

private extension HistoryReport {
    func appRowsForTest(_ name: String) -> ByteCounts? {
        apps.first { $0.displayName == name }.map { ByteCounts(bytesIn: $0.bytesIn, bytesOut: $0.bytesOut) }
    }
}
