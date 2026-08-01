import Foundation
import NetworkMonitorCore

/// Live integration test against the real `nettop` binary.
///
/// This exists because of a bug that every unit test passed straight through:
/// `nettop` block-buffers stdout when it is not a terminal, so a `Pipe()`-based
/// implementation produced **zero** samples for many seconds while looking
/// perfectly healthy — the process was running, the parser was correct, and no
/// error was raised anywhere.
///
/// It hides during manual shell testing too, because a short `nettop -L 2` exits
/// and libc flushes at exit. Only a long-lived stream shows it. So the only
/// meaningful guard is to run the real thing and require that data actually
/// arrives.
///
/// The second test in this suite guards the other half of the spawn contract: the
/// stream must not cost a core. nettop spins when its stdin is `/dev/null`, which
/// is invisible to every unit test and to the eye — the samples arrive perfectly
/// while a core burns. See `NettopStream.spawn()`.
/// The tests here need a machine with real network traffic, which a sandboxed
/// CI runner does not have, so they are skipped there. See `Check.skipsLiveTests`.
func runNettopStreamIntegrationTests() {
    Check.suite("NettopStream — live integration") {

        guard !Check.skipsLiveTests else {
            Check.skip("delivers a sample within 8 seconds", "needs live traffic")
            Check.skip("first delivered sample holds deltas, not lifetime totals",
                       "needs live traffic")
            Check.skip("the stream does not burn a core", "needs a live subprocess")
            Check.skip("changing the sample interval leaves exactly one nettop",
                       "needs a live subprocess")
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

        // The regression this guards cost a core for the app's whole life and was
        // invisible everywhere: samples arrive on time, the parser is right, no
        // error is raised. It was measured twice and misattributed once — to the
        // PTY — before stdin turned out to be the cause. nettop polls stdin for
        // keystrokes, and `/dev/null` is always ready, so the poll never blocks.
        //
        // Threshold at 25% of a core: the healthy value is ~0.5%, the broken one
        // ~140%, so anything in between is a real change worth failing on.
        Check.test("the stream does not burn a core") {
            let stream = NettopStream()
            stream.start()
            // Let it spawn, then find nettop among this process's children.
            Thread.sleep(forTimeInterval: 3)

            func run(_ command: String) -> String {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/sh")
                task.arguments = ["-c", command]
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = FileHandle.nullDevice
                try? task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                return String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }

            let pid = run("pgrep -P \(getpid()) nettop | head -1")
            guard !pid.isEmpty else {
                stream.stop()
                Check.expectFalse(pid.isEmpty, "no nettop child found to measure")
                return
            }

            /// `ps` reports `mm:ss.ss`.
            func cpuSeconds() -> Double {
                let parts = run("ps -o cputime= -p \(pid)").split(separator: ":")
                guard parts.count == 2,
                      let minutes = Double(parts[0]), let seconds = Double(parts[1])
                else { return -1 }
                return minutes * 60 + seconds
            }

            let before = cpuSeconds()
            let window: TimeInterval = 6
            Thread.sleep(forTimeInterval: window)
            let after = cpuSeconds()
            stream.stop()

            Check.expectTrue(before >= 0 && after >= 0, "could not read nettop's CPU time")
            guard before >= 0, after >= 0 else { return }

            let share = 100 * (after - before) / window
            Check.expectTrue(share < 25,
                             String(format: "nettop used %.1f%% of a core — it is spinning; "
                                    + "check that stdin blocks", share))
        }

        // `PowerProfile` changes the interval on every plug and unplug, which
        // restarts nettop. A leaked child would double-count every byte for the
        // rest of the session, and the totals would simply read too high with
        // nothing obviously broken.
        Check.test("changing the sample interval leaves exactly one nettop") {
            let stream = NettopStream(sampleInterval: 1)
            let lock = NSLock()
            var samples = 0
            stream.onSample = { _ in lock.lock(); samples += 1; lock.unlock() }
            stream.start()
            Thread.sleep(forTimeInterval: 4)

            lock.lock(); let before = samples; lock.unlock()
            Check.expectTrue(before > 0, "no samples before the interval change")

            stream.setSampleInterval(3)
            // Long enough for the restart, the discarded priming sample and at
            // least one 3 s delta to land.
            Thread.sleep(forTimeInterval: 10)

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", "pgrep -P \(getpid()) nettop | wc -l"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            try? task.run()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? ""
            task.waitUntilExit()
            let children = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1

            lock.lock(); let after = samples; lock.unlock()
            stream.stop()

            Check.expectEqual(children, 1, "expected one nettop child, found \(children)")
            Check.expectTrue(after > before,
                             "the stream stopped delivering after the interval change")
        }
    }
}
