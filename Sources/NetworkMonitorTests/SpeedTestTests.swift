import AppKit
import Foundation
import NetworkMonitorCore

/// The speed test, tested without spending any data.
///
/// The parser and decoder run against output captured from the real
/// `networkQuality` on macOS 26. The runner and controller run against a
/// stand-in script that behaves like the tool — redraws a status line on a
/// terminal, prints a summary, writes JSON to the `-c` path — so the whole path
/// from pseudo-terminal to popover state is exercised in a second, offline, and
/// on CI. The stand-in stamps every result with a fresh nonce, which is what
/// lets "never a cached result" be checked rather than asserted.
func runSpeedTestTests() {
    runSpeedTestParserTests()
    runSpeedTestDecodeTests()
    runSpeedTestFormatTests()
    runSpeedTestRunnerTests()
    runSpeedTestControllerTests()
}

// MARK: - Captured output

/// Two redraws as the real tool writes them with `-v`: clear-line, carriage
/// return, status. Captured on en7, 2026-10-20.
private let verboseRedraws =
    "\u{1B}[2K\rDownlink: capacity 1.792 Mbps, responsiveness 0 RPM (47.991 KB, 1 flow)"
    + " - Uplink: capacity 0.000 Mbps, responsiveness 0 RPM (0 B, 1 flow)"
    + "\u{1B}[2K\rDownlink: capacity 15.093 Mbps, responsiveness 107 RPM (24.202 MB, 6 flows)"
    + " - Uplink: capacity 28.461 Mbps, responsiveness 107 RPM (38.500 MB, 11 flows)"
    + "\u{1B}[2K\r"

private let summary = """
==== Verbose Results ====\r
Uplink capacity: 27.321 Mbps\r
   Responsiveness: Low\r
Downlink capacity: 14.948 Mbps\r
Responsiveness: Low (543.392 milliseconds | 110 RPM)\r
Idle Latency: 45.483 milliseconds | 1319 RPM\r

"""

/// A real `networkQuality -s -c` run on Wi-Fi, 2026-10-20: the scalars as
/// reported, the idle samples whole, the loaded samples cut to a few each.
private let capturedJSON = """
{"base_rtt": 83.45796203613281, "dl_bytes_transferred": 36949766, "dl_flows": 12,
 "dl_responsiveness": 46.15, "dl_throughput": 17805394, "interface_name": "en0",
 "test_endpoint": "frmrs1-edge-fx-019.aaplimg.com", "ul_bytes_transferred": 51380224,
 "ul_flows": 13, "ul_responsiveness": 48.39, "ul_throughput": 29888894,
 "il_h2_req_resp": [52.99198532104492, 45.512081146240234, 49.31390380859375,
                    49.93701171875, 46.651004791259766, 46.01108932495117,
                    46.54502868652344, 57.02900695800781],
 "lud_foreign_dl_h2_req_resp": [41, 69, 75, 80, 95, 633, 75, 88],
 "lud_foreign_ul_h2_req_resp": [41, 53, 55, 331, 60, 52, 62, 58],
 "other": {"interface-type": {"wifi": 479}, "proxy_state": {"not_proxied": 479}}}
"""

// MARK: - Parser

private func runSpeedTestParserTests() {
    Check.suite("SpeedTest — terminal output parser") {

        Check.test("reads the latest verbose redraw") {
            var parser = SpeedTestOutputParser()
            Check.expectTrue(parser.consume(verboseRedraws))
            let progress = parser.progress
            Check.expectEqual(progress?.downloadBitsPerSecond ?? 0, 15_093_000, accuracy: 1)
            Check.expectEqual(progress?.uploadBitsPerSecond ?? 0, 28_461_000, accuracy: 1)
            // 24.202 MB + 38.500 MB, binary steps.
            Check.expectEqual(Double(progress?.bytesTransferred ?? 0),
                              (24.202 + 38.5) * 1_048_576, accuracy: 2)
        }

        // With -s the upload reads exactly "0 B" until its half begins, then the
        // download freezes at its final figure. Captured on Wi-Fi, 2026-10-20.
        Check.test("the stage follows the bytes: ping, then download, then upload") {
            let quiet = SpeedTestOutputParserProbe.parse(
                "Downlink: capacity 0.000 Mbps, responsiveness 0 RPM (0 B, 0 flows)"
                + " - Uplink: capacity 0.000 Mbps, responsiveness 0 RPM (0 B, 0 flows)")
            Check.expectEqual(quiet?.stage, .starting)
            let downloading = SpeedTestOutputParserProbe.parse(
                "Downlink: capacity 14.430 Mbps, responsiveness 140 RPM (9.612 MB, 7 flows)"
                + " - Uplink: capacity 0.000 Mbps, responsiveness 0 RPM (0 B, 0 flows)")
            Check.expectEqual(downloading?.stage, .download)
            let uploading = SpeedTestOutputParserProbe.parse(
                "Downlink: capacity 16.981 Mbps, responsiveness 46 RPM (35.238 MB, 12 flows)"
                + " - Uplink: capacity 28.416 Mbps, responsiveness 274 RPM (16.000 MB, 6 flows)")
            Check.expectEqual(uploading?.stage, .upload)
        }

        Check.test("reads the shorter line printed without -v") {
            let line = SpeedTestOutputParserProbe.parse(
                "Downlink: 7.338 Mbps, 0 RPM - Uplink: 50.308 Mbps, 0 RPM")
            Check.expectEqual(line?.downloadBitsPerSecond ?? 0, 7_338_000, accuracy: 1)
            Check.expectEqual(line?.uploadBitsPerSecond ?? 0, 50_308_000, accuracy: 1)
            Check.expectEqual(line?.bytesTransferred ?? -1, 0)
        }

        Check.test("Kbps and Gbps scale correctly") {
            let line = SpeedTestOutputParserProbe.parse(
                "Downlink: capacity 1.250 Gbps, responsiveness 2400 RPM (1.5 GB, 12 flows)"
                + " - Uplink: capacity 850.000 Kbps, responsiveness 2400 RPM (300 KB, 2 flows)")
            Check.expectEqual(line?.downloadBitsPerSecond ?? 0, 1.25e9, accuracy: 1)
            Check.expectEqual(line?.uploadBitsPerSecond ?? 0, 850_000, accuracy: 1)
        }

        // The tool writes in bursts; a status line split across two reads must
        // still parse whole, and must not parse early as a truncated number.
        Check.test("a line split across reads parses once, whole") {
            var parser = SpeedTestOutputParser()
            let mid = verboseRedraws.index(verboseRedraws.endIndex, offsetBy: -60)
            parser.consume(String(verboseRedraws[..<mid]))
            Check.expectEqual(parser.progress?.downloadBitsPerSecond ?? 0, 1_792_000, accuracy: 1)
            parser.consume(String(verboseRedraws[mid...]))
            Check.expectEqual(parser.progress?.downloadBitsPerSecond ?? 0, 15_093_000, accuracy: 1)
        }

        Check.test("keeps the tool's error line for the popover") {
            var parser = SpeedTestOutputParser()
            parser.consume("Error: The Internet connection appears to be offline.\r\n")
            Check.expectEqual(parser.lastMessage,
                              "Error: The Internet connection appears to be offline.")
            Check.expectNil(parser.progress)
        }

        Check.test("summary lines are not mistaken for an error") {
            var parser = SpeedTestOutputParser()
            parser.consume(verboseRedraws + summary)
            Check.expectNil(parser.lastMessage)
        }
    }
}

/// Feeds one line, terminated, through a fresh parser.
private enum SpeedTestOutputParserProbe {
    static func parse(_ line: String) -> SpeedTestProgress? {
        var parser = SpeedTestOutputParser()
        parser.consume(line + "\r")
        return parser.progress
    }
}

// MARK: - Decoding

private func runSpeedTestDecodeTests() {
    Check.suite("SpeedTest — result decoding") {

        Check.test("decodes a real run into the usual speed test figures") {
            guard case .success(let result) = SpeedTestResult.decode(Data(capturedJSON.utf8))
            else { return Check.expectTrue(false, "did not decode") }
            Check.expectEqual(result.downloadBitsPerSecond, 17_805_394, accuracy: 0.5)
            Check.expectEqual(result.uploadBitsPerSecond, 29_888_894, accuracy: 0.5)
            // The interquartile mean of the idle HTTP samples, not `base_rtt`
            // (83 ms), which folds handshakes in and is no ping.
            Check.expectEqual(result.ping ?? 0, 48.11, accuracy: 0.01)
            Check.expectEqual(result.jitter ?? 0, 3.84, accuracy: 0.01)
            // The 633 ms stall is in the top quarter and does not move the figure.
            Check.expectEqual(result.downloadPing ?? 0, 79.5, accuracy: 0.01)
            Check.expectEqual(result.uploadPing ?? 0, 56.5, accuracy: 0.01)
            Check.expectEqual(result.bytesTransferred, 36_949_766 + 51_380_224)
            Check.expectEqual(result.interfaceKind, "Wi-Fi")
        }

        Check.test("interquartile mean drops the top and bottom quarters") {
            Check.expectEqual(Latency.interquartileMean([1, 2, 3, 4, 5, 6, 7, 1000]) ?? 0,
                              4.5, accuracy: 0.001)
            Check.expectEqual(Latency.interquartileMean([42]) ?? 0, 42, accuracy: 0.001)
            Check.expectNil(Latency.interquartileMean([]))
        }

        Check.test("jitter is the mean step between consecutive pings") {
            Check.expectEqual(Latency.jitter([40, 50, 40, 50]) ?? 0, 10, accuracy: 0.001)
            Check.expectEqual(Latency.jitter([40, 40, 40]) ?? -1, 0, accuracy: 0.001)
            Check.expectNil(Latency.jitter([40]))
        }

        // The ping pass runs after the test. The jump from the test's last idle
        // sample to the pass's first is a minute's drift, not jitter.
        Check.test("jitter never steps across from one batch of samples to the next") {
            Check.expectEqual(Latency.jitter(batches: [[40, 42], [90, 92]]) ?? 0, 2,
                              accuracy: 0.001)
        }

        Check.test("the ping pass's samples join the test's for ping") {
            let pass = Data(#"{"il_h2_req_resp": [60, 61, 60, 61, 60, 61, 60, 61]}"#.utf8)
            guard case .success(let result) = SpeedTestResult.decode(Data(capturedJSON.utf8),
                                                                    idlePass: pass)
            else { return Check.expectTrue(false, "did not decode") }
            // Sixteen samples, eight from each, summarised as one set.
            let all = [52.99198532104492, 45.512081146240234, 49.31390380859375,
                       49.93701171875, 46.651004791259766, 46.01108932495117,
                       46.54502868652344, 57.02900695800781,
                       60, 61, 60, 61, 60, 61, 60, 61]
            Check.expectEqual(result.ping ?? 0, Latency.interquartileMean(all) ?? -1,
                              accuracy: 0.001)
        }

        Check.test("the load note only speaks up past 100 ms") {
            var result = sample(bytes: 1)
            Check.expectNil(result.loadedPingIncrease)
            result = SpeedTestResult(downloadBitsPerSecond: 1, uploadBitsPerSecond: 1,
                                     ping: 48, jitter: 4, downloadPing: 89, uploadPing: 62,
                                     bytesTransferred: 1, interfaceName: nil, endpoint: nil,
                                     finishedAt: Date())
            Check.expectEqual(result.loadedPingIncrease ?? 0, 41, accuracy: 0.001)
        }

        // A run cut short drops whichever figure had not converged — seen live
        // with `-s` and with `-M`. Half a result is still a result.
        Check.test("a missing upload figure falls back to the last live reading") {
            let json = #"{"dl_throughput": 17802860, "dl_bytes_transferred": 5045993}"#
            let last = SpeedTestProgress(downloadBitsPerSecond: 16_981_000,
                                         uploadBitsPerSecond: 26_301_000)
            guard case .success(let result) = SpeedTestResult.decode(Data(json.utf8),
                                                                    fallback: last)
            else { return Check.expectTrue(false, "did not decode") }
            Check.expectEqual(result.downloadBitsPerSecond, 17_802_860, accuracy: 0.5)
            Check.expectEqual(result.uploadBitsPerSecond, 26_301_000, accuracy: 0.5)
            Check.expectNil(result.ping)
        }

        Check.test("no throughput at all is a failure, naming the tool's error") {
            let json = #"{"error_domain": "NSURLErrorDomain", "error_code": -1009}"#
            Check.expectEqual(SpeedTestResult.decode(Data(json.utf8)).failure,
                              .toolError("NSURLErrorDomain -1009"))
            Check.expectEqual(SpeedTestResult.decode(Data("not json".utf8)).failure,
                              .unreadable)
        }

        Check.test("contention needs both a floor and a share") {
            var result = sample(bytes: 100_000_000)
            result.competingTraffic = [CompetingTraffic(displayName: "Chrome", bytes: 900_000)]
            Check.expectFalse(result.wasContended, "under 1 MB")
            result.competingTraffic = [CompetingTraffic(displayName: "Chrome", bytes: 4_000_000)]
            Check.expectFalse(result.wasContended, "4% of the test")
            result.competingTraffic = [CompetingTraffic(displayName: "Chrome", bytes: 12_000_000)]
            Check.expectTrue(result.wasContended, "12% of the test")
        }
    }
}

private func sample(bytes: Int64 = 1_000_000) -> SpeedTestResult {
    SpeedTestResult(downloadBitsPerSecond: 1, uploadBitsPerSecond: 1, ping: nil, jitter: nil,
                    downloadPing: nil, uploadPing: nil, bytesTransferred: bytes,
                    interfaceName: nil, endpoint: nil, finishedAt: Date())
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

// MARK: - Formatting

private func runSpeedTestFormatTests() {
    Check.suite("SpeedTest — formatting") {

        Check.test("bit rates use 1000-based steps and the precision of the magnitude") {
            Check.expectEqual(ByteFormat.bitRate(16_044_384), "16.0 Mbps")
            Check.expectEqual(ByteFormat.bitRate(9_450_000), "9.45 Mbps")
            Check.expectEqual(ByteFormat.bitRate(940_000_000), "940 Mbps")
            Check.expectEqual(ByteFormat.bitRate(1_250_000_000), "1.25 Gbps")
            Check.expectEqual(ByteFormat.bitRate(850_000), "850 Kbps")
            Check.expectEqual(ByteFormat.bitRate(0), "0.00 bps")
        }

        Check.test("the menu bar's bit rate has the byte rate's character count") {
            let expected = ByteFormat.menuBarRate(0).count
            for value in [0, 999, 1_000, 15_093_000, 940_000_000, 1_250_000_000,
                          9_999_000_000] as [Double] {
                Check.expectEqual(ByteFormat.menuBarBitRate(value).count, expected,
                                  "\(value) → \"\(ByteFormat.menuBarBitRate(value))\"")
            }
        }

        // The whole point of the matching character count: the status item must
        // not change width when a test takes it over, or hands it back.
        Check.test("the speed test title renders at the live title's width, in either unit") {
            let live = MenuBarTitle.renderedWidth(down: 15_000, up: 1_200)
            for unit in SpeedUnit.allCases {
                for (down, up) in [(0.0, 0.0), (15_093_000, 28_461_000), (940e6, 1.25e9)] {
                    let test = Double(MenuBarTitle.speedTestAttributed(
                        downBits: down, upBits: up, unit: unit).size().width)
                    Check.expectEqual(test, live, accuracy: 0.01, "\(unit) \(down)/\(up)")
                }
            }
        }

        // MB/s on the app's own 1024-based scale, so a test in bytes matches the
        // menu bar's live rates rather than an ISP's decimal megabytes.
        Check.test("bytes use the app's binary scale, bits the line-speed convention") {
            Check.expectEqual(ByteFormat.speed(17_805_394, unit: .bits), "17.8 Mbps")
            Check.expectEqual(ByteFormat.speed(17_805_394, unit: .bytes), "2.12 MB/s")
            Check.expectEqual(ByteFormat.speed(940_000_000, unit: .bytes), "112 MB/s")
            Check.expectEqual(ByteFormat.speed(800_000, unit: .bytes), "97.7 KB/s")
            Check.expectEqual(ByteFormat.menuBarSpeed(17_805_394, unit: .bytes),
                              ByteFormat.menuBarRate(17_805_394 / 8))
        }
    }
}

// MARK: - Runner, against a stand-in

/// A script that behaves like `networkQuality -s -v -c<path>`: download redraws
/// with the upload at "0 B", then upload redraws, a summary, then JSON with a
/// nonce no two runs share. Called with `-d -u` it is the ping-only pass and
/// writes idle samples alone. Each invocation appends its arguments, on one
/// line, to `args.log`. `FAKE_NQ_FAIL` beside it fails the test;
/// `FAKE_PING_FAIL` fails only the ping pass.
private func makeStandIn() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("nq-standin-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("networkQuality")
    let body = #"""
    #!/bin/bash
    out=""
    for a in "$@"; do case "$a" in -c*) out="${a#-c}";; esac; done
    here="$(dirname "$0")"
    echo "$*" >> "$here/args.log"
    case " $* " in *" -d "*)
      [ -f "$here/FAKE_PING_FAIL" ] && exit 1
      printf '{"il_h2_req_resp": [22, 23, 22, 23]}' > "$out"
      exit 0;;
    esac
    if [ -f "$here/FAKE_NQ_FAIL" ]; then
      printf 'Error: The Internet connection appears to be offline.\r\n'
      exit 1
    fi
    delay="$(cat "$here/FAKE_NQ_DELAY" 2>/dev/null || echo 0.05)"
    for d in 4.000 8.000 12.000; do
      printf '\033[2K\rDownlink: capacity %s Mbps, responsiveness 300 RPM (1.000 MB, 2 flows) - Uplink: capacity 0.000 Mbps, responsiveness 0 RPM (0 B, 0 flows)' "$d"
      sleep "$delay"
    done
    for u in 1.000 2.000; do
      printf '\033[2K\rDownlink: capacity 12.000 Mbps, responsiveness 300 RPM (3.000 MB, 2 flows) - Uplink: capacity %s Mbps, responsiveness 300 RPM (0.500 MB, 1 flow)' "$u"
      sleep "$delay"
    done
    printf '\033[2K==== Verbose Results ====\r\nUplink Responsiveness: Medium (200.000 milliseconds | 300 RPM)\r\n'
    nonce="$(date +%s)$$$RANDOM"
    printf '{"dl_throughput": 12000000, "ul_throughput": 2000000, "il_h2_req_resp": [20, 21, 20, 21], "lud_foreign_dl_h2_req_resp": [60, 60], "lud_foreign_ul_h2_req_resp": [30, 30], "dl_bytes_transferred": 1000, "ul_bytes_transferred": 500, "test_endpoint": "standin-%s"}' "$nonce" > "$out"
    """#
    try? body.write(to: script, atomically: true, encoding: .utf8)
    chmod(script.path, 0o755)
    return script
}

private func runOnce(_ runner: SpeedTestRunner,
                     timeout: TimeInterval = 10) -> (progress: [SpeedTestProgress],
                                                     result: Result<SpeedTestResult, SpeedTestResult.Failure>?) {
    let done = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var progress: [SpeedTestProgress] = []
    var result: Result<SpeedTestResult, SpeedTestResult.Failure>?
    runner.start { event in
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .progress(let reading): progress.append(reading)
        case .finished(let outcome):
            result = outcome
            done.signal()
        }
    }
    _ = done.wait(timeout: .now() + timeout)
    lock.lock(); defer { lock.unlock() }
    return (progress, result)
}

private func runSpeedTestRunnerTests() {
    Check.suite("SpeedTestRunner — against a stand-in tool") {
        let script = makeStandIn()
        let runner = SpeedTestRunner(executable: script.path)

        Check.test("live readings arrive through the pseudo-terminal") {
            let run = runOnce(runner)
            Check.expectTrue(run.progress.count >= 2, "got \(run.progress.count) readings")
            Check.expectEqual(run.progress.first?.downloadBitsPerSecond ?? 0, 4e6, accuracy: 1)
        }

        Check.test("the result is decoded with ping and both loaded pings") {
            guard case .success(let result) = runOnce(runner).result
            else { return Check.expectTrue(false, "no result") }
            Check.expectEqual(result.downloadBitsPerSecond, 12e6, accuracy: 1)
            // The test's 20/21 samples and the ping pass's 22/23, together.
            Check.expectEqual(result.ping ?? 0, 21.5, accuracy: 0.01)
            Check.expectEqual(result.jitter ?? 0, 1, accuracy: 0.01)
            Check.expectEqual(result.downloadPing ?? 0, 60, accuracy: 0.01)
            Check.expectEqual(result.uploadPing ?? 0, 30, accuracy: 0.01)
        }

        // Download, then upload, as every mainstream speed test runs. The tool's
        // default runs both at once; this pins the flag that stops it.
        Check.test("the test runs download then upload, and a ping-only pass follows") {
            let log = script.deletingLastPathComponent().appendingPathComponent("args.log")
            try? FileManager.default.removeItem(at: log)
            _ = runOnce(runner)
            let calls = ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
                .split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
            Check.expectEqual(calls.count, 2, "calls: \(calls)")
            Check.expectTrue(calls.first?.contains("-s") == true, "test call: \(calls.first ?? [])")
            Check.expectTrue(calls.last?.contains("-d") == true && calls.last?.contains("-u") == true,
                             "ping call: \(calls.last ?? [])")
        }

        Check.test("a failed ping pass still delivers the test's own figures") {
            let flag = script.deletingLastPathComponent().appendingPathComponent("FAKE_PING_FAIL")
            FileManager.default.createFile(atPath: flag.path, contents: Data())
            defer { try? FileManager.default.removeItem(at: flag) }
            guard case .success(let result) = runOnce(runner).result
            else { return Check.expectTrue(false, "no result") }
            Check.expectEqual(result.ping ?? 0, 20.5, accuracy: 0.01)
        }

        Check.test("live readings move from download to upload, then the ping pass") {
            let stages = runOnce(runner).progress.map(\.stage)
            Check.expectEqual(stages.first, .download)
            Check.expectTrue(stages.contains(.upload), "stages: \(stages)")
            Check.expectEqual(stages.last, .finishing)
        }

        // The requirement this feature was asked for: every run is a new
        // measurement. The stand-in stamps each result with a nonce, so equal
        // endpoints would mean a result was reused.
        Check.test("every run is a fresh measurement, never a reused result") {
            var endpoints = Set<String>()
            for _ in 0..<3 {
                if case .success(let result) = runOnce(runner).result, let endpoint = result.endpoint {
                    endpoints.insert(endpoint)
                }
            }
            Check.expectEqual(endpoints.count, 3, "endpoints: \(endpoints)")
        }

        Check.test("nothing from a run is left on disk") {
            let delay = script.deletingLastPathComponent().appendingPathComponent("FAKE_NQ_DELAY")
            try? "0.2".write(to: delay, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: delay) }

            let finished = DispatchSemaphore(value: 0)
            runner.start { event in
                if case .finished = event { finished.signal() }
            }
            usleep(150_000)
            let folder = runner.currentWorkDirectoryForTests
            Check.expectNotNil(folder, "no work folder while running")
            _ = finished.wait(timeout: .now() + 10)
            Check.expectNil(runner.currentWorkDirectoryForTests,
                            "work folder still set after the run")
            if let folder {
                Check.expectFalse(FileManager.default.fileExists(atPath: folder.path),
                                  "the run's folder survived")
            }
        }

        Check.test("a failed run reports the tool's own message") {
            let flag = script.deletingLastPathComponent().appendingPathComponent("FAKE_NQ_FAIL")
            FileManager.default.createFile(atPath: flag.path, contents: Data())
            defer { try? FileManager.default.removeItem(at: flag) }
            Check.expectEqual(runOnce(runner).result?.failure,
                              .toolError("Error: The Internet connection appears to be offline."))
        }

        Check.test("cancelling reports nothing and leaves no process behind") {
            let delay = script.deletingLastPathComponent().appendingPathComponent("FAKE_NQ_DELAY")
            try? "2".write(to: delay, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: delay) }

            let finished = DispatchSemaphore(value: 0)
            runner.start { event in
                if case .finished = event { finished.signal() }
            }
            usleep(300_000)
            runner.cancel()
            Check.expectFalse(runner.isRunning)
            Check.expectEqual(finished.wait(timeout: .now() + 1), .timedOut,
                              "a cancelled run still reported")
        }

        try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
    }
}

// MARK: - Controller

private func runSpeedTestControllerTests() {
    Check.suite("SpeedTestController — phases") {
        let script = makeStandIn()
        let defaults = UserDefaults(suiteName: "speedtest-tests-\(UUID().uuidString)")!

        func controller() -> SpeedTestController {
            SpeedTestController(runner: SpeedTestRunner(executable: script.path),
                                defaults: defaults)
        }

        /// Spins the main run loop until the condition holds, since the
        /// controller delivers on the main queue.
        func waitFor(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition(), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return condition()
        }

        // One unit for every speed, defaulting to bytes so an upgrade leaves the
        // menu bar as it was; a unit chosen for the speed test before it covered
        // the menu bar stays the user's choice.
        Check.test("speeds default to MB/s, and an earlier choice carries over") {
            let fresh = UserDefaults(suiteName: "speedunit-fresh-\(UUID().uuidString)")!
            Check.expectEqual(SpeedTestController(runner: SpeedTestRunner(executable: script.path),
                                                  defaults: fresh).unit, .bytes)
            let chosen = UserDefaults(suiteName: "speedunit-chosen-\(UUID().uuidString)")!
            chosen.set("bits", forKey: "speedTestUnit")
            Check.expectEqual(SpeedTestController(runner: SpeedTestRunner(executable: script.path),
                                                  defaults: chosen).unit, .bits)
        }

        Check.test("a metered connection asks first, and spends nothing until confirmed") {
            let speedTest = controller()
            speedTest.isMetered = { true }
            speedTest.run()
            Check.expectEqual(speedTest.phase, .confirming(estimatedBytes: nil))
            speedTest.confirm()
            Check.expectTrue(speedTest.phase.isRunning)
            speedTest.dismiss()
        }

        Check.test("a run finishes with a result and keeps it as the last one") {
            let speedTest = controller()
            speedTest.run()
            Check.expectTrue(waitFor { if case .finished = speedTest.phase { return true }; return false })
            Check.expectEqual(speedTest.lastResult?.ping ?? 0, 21.5, accuracy: 0.01)
        }

        Check.test("pressing again measures again — the result changes") {
            let speedTest = controller()
            speedTest.run()
            _ = waitFor { speedTest.lastResult != nil }
            let first = speedTest.lastResult?.endpoint
            speedTest.run()
            Check.expectTrue(speedTest.phase.isRunning, "a finished test did not start again")
            _ = waitFor { speedTest.lastResult?.endpoint != first }
            Check.expectFalse(speedTest.lastResult?.endpoint == first)
        }

        Check.test("other apps' traffic during the test is credited, its own is not") {
            let speedTest = controller()
            speedTest.run()
            speedTest.recordBackground([
                ("Google Chrome", "/Applications/Google Chrome.app", 3_000_000),
                ("networkQuality", "/Applications/NetworkMonitor.app\u{1}/usr/bin/networkQuality", 9_000_000),
            ])
            _ = waitFor { speedTest.lastResult != nil }
            Check.expectEqual(speedTest.lastResult?.competingTraffic,
                              [CompetingTraffic(displayName: "Google Chrome", bytes: 3_000_000)])
        }

        // "Back to Apps" leaves the card, not the test.
        Check.test("hiding the card mid-run lets the test finish") {
            let speedTest = controller()
            speedTest.run()
            Check.expectTrue(speedTest.isPresented)
            speedTest.hide()
            Check.expectTrue(speedTest.phase.isRunning, "hiding stopped the test")
            Check.expectFalse(speedTest.isPresented)
            speedTest.present()
            Check.expectTrue(speedTest.isPresented, "the card did not come back")
            speedTest.hide()
            Check.expectTrue(waitFor { speedTest.lastResult != nil }, "the hidden run never finished")
            // Once finished, leaving the card puts the result away, so the next
            // press measures afresh.
            speedTest.present()
            speedTest.hide()
            Check.expectEqual(speedTest.phase, .idle)
        }

        Check.test("a network change ends a run and forgets the last result") {
            let speedTest = controller()
            speedTest.run()
            _ = waitFor { speedTest.lastResult != nil }
            speedTest.networkDidChange()
            Check.expectNil(speedTest.lastResult)
            Check.expectEqual(speedTest.phase, .idle)

            speedTest.run()
            speedTest.networkDidChange()
            Check.expectEqual(speedTest.phase, .failed("The network changed during the test"))
        }

        Check.test("the menu bar shows the run, holds the result, then lets go") {
            let speedTest = controller()
            speedTest.showsInMenuBar = true
            speedTest.run()
            Check.expectTrue(speedTest.isShowingInMenuBar, "not shown while running")
            _ = waitFor { speedTest.lastResult != nil }
            Check.expectEqual(speedTest.menuBarReading?.down ?? 0, 12e6, accuracy: 1)
            speedTest.dismiss()
            Check.expectFalse(speedTest.isShowingInMenuBar, "still shown after dismissal")

            speedTest.showsInMenuBar = false
            speedTest.run()
            Check.expectFalse(speedTest.isShowingInMenuBar, "shown with the setting off")
            speedTest.dismiss()
        }

        try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
    }
}
