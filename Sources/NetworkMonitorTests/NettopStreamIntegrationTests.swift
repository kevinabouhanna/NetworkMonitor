import Foundation
import NetworkMonitorCore

/// Live integration test against the real `nettop` binary.
///
/// This exists because of a bug that every unit test passed straight through:
/// `nettop` block-buffers stdout when it is not a terminal, so the original
/// `Pipe()`-based implementation produced **zero** samples for many seconds while
/// looking perfectly healthy — the process was running, the parser was correct,
/// and no error was raised anywhere. Measured at zero output over 9 s through a
/// pipe versus one flush per second through a PTY.
///
/// It hides during manual shell testing too, because a short `nettop -L 2` exits
/// and libc flushes at exit. Only a long-lived stream shows it. So the only
/// meaningful guard is to run the real thing and require that data actually
/// arrives.
/// Both tests here need a machine with real network traffic, which a sandboxed
/// CI runner does not have, so they are skipped there. See `Check.skipsLiveTests`.
func runNettopStreamIntegrationTests() {
    Check.suite("NettopStream — live integration") {

        guard !Check.skipsLiveTests else {
            Check.skip("delivers a sample within 8 seconds", "needs live traffic")
            Check.skip("first delivered sample holds deltas, not lifetime totals",
                       "needs live traffic")
            return
        }

        Check.test("delivers a sample within 8 seconds") {
            let stream = NettopStream()
            let firstSample = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var samples: [[NettopRow]] = []
            var failure: String?

            stream.onFailure = { message in
                lock.lock(); failure = message; lock.unlock()
                firstSample.signal()
            }
            stream.onSample = { rows in
                lock.lock()
                samples.append(rows)
                let isFirst = samples.count == 1
                lock.unlock()
                if isFirst { firstSample.signal() }
            }

            stream.start()
            let arrived = firstSample.wait(timeout: .now() + 8)
            // Give it a moment more so the cadence can be checked.
            Thread.sleep(forTimeInterval: 2.5)
            stream.stop()

            lock.lock()
            let collected = samples
            let reportedFailure = failure
            lock.unlock()

            Check.expectNil(reportedFailure, "stream reported a failure")
            Check.expectTrue(arrived == .success,
                             "no sample within 8 s — nettop is buffering, it needs a PTY")
            Check.expectFalse(collected.isEmpty, "no samples collected")

            // Roughly one sample per second, so ~2 more should land in 2.5 s.
            Check.expectTrue(collected.count >= 2,
                             "expected multiple samples, got \(collected.count)")

            // Rows must be real parsed data, not empty frames.
            if let first = collected.first {
                Check.expectFalse(first.isEmpty, "first sample had no rows")
                Check.expectTrue(first.allSatisfy { $0.pid >= 0 }, "row with negative pid")
                Check.expectTrue(first.contains { !$0.processName.isEmpty },
                                 "no process names parsed")
            }
        }

        // The priming sample carries lifetime totals; if it leaked through, some
        // long-lived daemon would show a huge value in the very first delta.
        Check.test("first delivered sample holds deltas, not lifetime totals") {
            let stream = NettopStream()
            let ready = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var first: [NettopRow]?

            stream.onSample = { rows in
                lock.lock()
                if first == nil { first = rows; lock.unlock(); ready.signal() }
                else { lock.unlock() }
            }
            stream.start()
            _ = ready.wait(timeout: .now() + 8)
            stream.stop()

            lock.lock(); let sample = first; lock.unlock()
            Check.expectNotNil(sample, "no sample arrived")
            guard let sample else { return }

            // One second of traffic on a normal machine. mDNSResponder's
            // *lifetime* total was 263 MB during development, so a leaked
            // cumulative sample would blow past this by orders of magnitude.
            let largest = sample.map { $0.bytesIn + $0.bytesOut }.max() ?? 0
            Check.expectTrue(largest < 200_000_000,
                             "largest single-second delta was \(largest) B — "
                             + "looks like a cumulative sample leaked through")
        }
    }
}
