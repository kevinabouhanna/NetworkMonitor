import Foundation

/// Runs one speed test with macOS's own `networkQuality` and reports it.
///
/// **Why `networkQuality` and not a measurement of our own.** It ships with every
/// Mac since Monterey, is maintained by Apple, measures against Apple's CDN edge
/// nearest the user, and records ping on separate connections while each
/// direction is saturated — the number that explains a stuttering call, which a
/// plain download timer cannot. The alternatives either need an install (Ookla's CLI, under a
/// licence an MIT app cannot redistribute), publish the user's IP address as open
/// data (M-Lab's NDT), or mean writing and maintaining a measurement engine that
/// would be worse than the one already on the machine.
///
/// **Fresh every time, by construction.** Each call to `start` launches a new
/// process, which opens new connections and moves new bytes; nothing is fetched
/// from a cache on this Mac and no earlier figure is reused. The JSON is written
/// to a directory created for that run alone and deleted as soon as it is read,
/// so a result can only ever come from the run that just finished — a stale file
/// left by a crashed run has nowhere to be found.
public final class SpeedTestRunner {

    /// `-v` adds the byte counts to the live status line, which is what lets the
    /// popover show what the test has cost so far. `-c<path>` writes the
    /// machine-readable result to a file, keeping stdout free for that status
    /// line; the path must be attached to the flag, as the tool's own usage line
    /// shows (`-c [optional filename]`) — a separate argument is not picked up.
    ///
    /// `-s` runs the download to completion and only then the upload, as every
    /// mainstream speed test does. The tool's default runs both at once, which
    /// suits Apple's purpose — judging the line under full two-way load — but
    /// makes each direction compete with the other: download acknowledgements
    /// queue behind upload data, so on an asymmetric or deeply buffered line both
    /// figures read low. Sequential runs also yield a separate loaded ping per
    /// direction, which a combined run cannot. One sequential run was seen to
    /// omit `ul_throughput`; `SpeedTestResult.decode` covers that from the last
    /// live reading. `-M` stays absent — a capped run drops whichever figures
    /// had not converged.
    static func arguments(resultPath: String) -> [String] {
        ["-s", "-v", "-c" + resultPath]
    }

    /// The ping-only pass: no download, no upload, so it moves no test data and
    /// takes under a second (0.86 s measured). It exists for its eight idle
    /// samples, which steady the ping and jitter; see `SpeedTestResult.decode`.
    static func pingArguments(resultPath: String) -> [String] {
        ["-d", "-u", "-c" + resultPath]
    }

    /// The ping pass is a nicety. Past this, the result goes out without it.
    static let pingTimeout: TimeInterval = 10

    /// Longest a run may take before it is abandoned. A sequential run normally
    /// finishes in 30–45 s; this only exists so a hung run cannot hold the button
    /// forever.
    static let timeout: TimeInterval = 90

    public enum Event {
        case progress(SpeedTestProgress)
        case finished(Result<SpeedTestResult, SpeedTestResult.Failure>)
    }

    private let executable: String
    private let queue = DispatchQueue(label: "com.networkmonitor.speedtest")

    private var process: Process?
    private var masterFD: Int32 = -1
    private var stdinWriteFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var parser = SpeedTestOutputParser()
    private var workDirectory: URL?
    private var onEvent: ((Event) -> Void)?
    private var timeoutWork: DispatchWorkItem?
    /// Held open for the ping pass's stdin, for the reason given in `spawn`.
    private var pingStdin: Pipe?
    /// Increments per run, so a late callback from a cancelled run is ignored.
    private var generation = 0

    public init(executable: String = "/usr/bin/networkQuality") {
        self.executable = executable
    }

    public static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/networkQuality")
    }

    /// How every run's working folder in the temporary directory is named.
    static let folderPrefix = "NetworkMonitor-speedtest-"

    /// Removes run folders left behind by a run that never finished, such as
    /// one the app was force-quit in the middle of (#29). Every run that ends
    /// deletes its own; this is for the ones that couldn't.
    ///
    /// Only folders untouched for `age` go. A run lasts at most 100 s (the 90 s
    /// limit plus the ping pass), and another process may be mid-run in the same
    /// temporary directory: a development build, or the test suite.
    public static func removeLeftoverFolders(
        in directory: URL = FileManager.default.temporaryDirectory,
        olderThan age: TimeInterval = 600, now: Date = Date()
    ) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys) else { return }
        for url in entries where url.lastPathComponent.hasPrefix(folderPrefix) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) > age else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    public var isRunning: Bool {
        queue.sync { process != nil }
    }

    /// Starts a run. Events arrive on an internal queue. A run already in
    /// progress is ended first, so there is never more than one.
    public func start(_ onEvent: @escaping (Event) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.endChild()
            self.generation += 1
            self.onEvent = onEvent
            self.spawn(generation: self.generation)
        }
    }

    /// Ends the run without reporting a result.
    public func cancel() {
        queue.sync {
            generation += 1
            onEvent = nil
            endChild()
        }
    }

    /// Launches the tool attached to a pseudo-terminal, as `NettopStream` does
    /// for `nettop` and for the same reason: through a pipe the tool stays
    /// silent until it exits, which would leave the popover with nothing to draw
    /// for the whole run. The stdin is a pipe nobody writes to, so nothing that
    /// polls it can spin; see `NettopStream.spawn()` for the measurements.
    private func spawn(generation: Int) {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            finish(.failure(.toolError("networkQuality is not available on this Mac")))
            return
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.folderPrefix + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
        } catch {
            finish(.failure(.toolError("Could not create a working folder")))
            return
        }
        workDirectory = directory
        let resultURL = directory.appendingPathComponent("result.json")

        var master: Int32 = 0
        var slave: Int32 = 0
        // Wide, so the ~170-character status line is never wrapped mid-number.
        var size = winsize(ws_row: 50, ws_col: 1000, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            finish(.failure(.toolError("Could not open a terminal for the test")))
            return
        }
        var settings = termios()
        if tcgetattr(slave, &settings) == 0 {
            cfmakeraw(&settings)
            _ = tcsetattr(slave, TCSANOW, &settings)
        }
        // Non-blocking, so the final drain in `collect` cannot hang on a read.
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)

        var stdinFDs: [Int32] = [-1, -1]
        guard pipe(&stdinFDs) == 0 else {
            close(master); close(slave)
            finish(.failure(.toolError("Could not open a terminal for the test")))
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = Self.arguments(resultPath: resultURL.path)
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        task.standardOutput = slaveHandle
        task.standardError = slaveHandle
        task.standardInput = FileHandle(fileDescriptor: stdinFDs[0], closeOnDealloc: false)

        parser = SpeedTestOutputParser()
        masterFD = master
        stdinWriteFD = stdinFDs[1]

        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { close(master) }
        source.resume()
        readSource = source

        task.terminationHandler = { [weak self] finished in
            self?.queue.async {
                guard let self, self.generation == generation else { return }
                self.collect(status: finished.terminationStatus, resultURL: resultURL)
            }
        }

        do {
            try task.run()
            process = task
            close(slave)
            close(stdinFDs[0])
        } catch {
            close(slave)
            close(stdinFDs[0])
            teardown()
            finish(.failure(.toolError("Could not start networkQuality")))
            return
        }

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation, self.process != nil else { return }
            self.endChild()
            self.finish(.failure(.toolError("The test took too long and was stopped")))
        }
        timeoutWork = timeout
        queue.asyncAfter(deadline: .now() + Self.timeout, execute: timeout)
    }

    private func readAvailable() {
        guard masterFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let count = read(masterFD, &buffer, buffer.count)
        guard count > 0 else {
            if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
            // EOF or EIO: the child has gone. The termination handler reports it.
            readSource?.cancel()
            readSource = nil
            masterFD = -1
            return
        }
        guard let text = String(bytes: buffer[0..<count], encoding: .utf8) else { return }
        if parser.consume(text), let progress = parser.progress {
            onEvent?(.progress(progress))
        }
    }

    /// Reads the run's own JSON, then takes the ping-only pass.
    private func collect(status: Int32, resultURL: URL) {
        // Drain anything still buffered, so the last reading and any error line
        // are not lost to a termination that raced the last read.
        if masterFD >= 0 {
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = read(masterFD, &buffer, buffer.count)
                guard count > 0, let text = String(bytes: buffer[0..<count], encoding: .utf8)
                else { break }
                parser.consume(text)
            }
        }
        // The summary's last line has no terminator of its own.
        parser.consume("\n")
        process = nil
        let data = try? Data(contentsOf: resultURL)

        guard let data else {
            teardown()
            let message = parser.lastMessage ?? "networkQuality exited with status \(status)"
            finish(.failure(.toolError(message)))
            return
        }
        // A test that produced nothing usable is reported now; there is no
        // point steadying the ping of a run that failed.
        if case .failure(let failure) = SpeedTestResult.decode(data, fallback: parser.progress) {
            teardown()
            finish(.failure(failure))
            return
        }
        spawnPingPass(testData: data)
    }

    /// Runs `networkQuality -d -u` and folds its idle samples into the result.
    ///
    /// Through a plain pipe rather than a terminal: only its JSON is wanted, and
    /// it writes that to the file at exit. Anything going wrong here — the tool
    /// failing, the timeout — still delivers the test's own result, just with
    /// the eight samples it already had.
    private func spawnPingPass(testData: Data) {
        // The test's own deadline no longer applies; the pass has its own.
        timeoutWork?.cancel()
        var progress = parser.progress ?? SpeedTestProgress()
        progress.isFinishing = true
        onEvent?(.progress(progress))

        let generation = self.generation
        guard let directory = workDirectory else {
            deliver(testData, idlePass: nil)
            return
        }
        let pingURL = directory.appendingPathComponent("ping.json")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = Self.pingArguments(resultPath: pingURL.path)
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        let stdin = Pipe()
        task.standardInput = stdin
        pingStdin = stdin

        task.terminationHandler = { [weak self] _ in
            self?.queue.async {
                guard let self, self.generation == generation else { return }
                self.process = nil
                self.deliver(testData, idlePass: try? Data(contentsOf: pingURL))
            }
        }
        do {
            try task.run()
            process = task
        } catch {
            deliver(testData, idlePass: nil)
            return
        }

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation, self.process != nil else { return }
            self.endChild(keepingWorkDirectory: true)
            self.deliver(testData, idlePass: nil)
        }
        timeoutWork = timeout
        queue.asyncAfter(deadline: .now() + Self.pingTimeout, execute: timeout)
    }

    /// Decodes, removes every trace of the run, and reports.
    private func deliver(_ testData: Data, idlePass: Data?) {
        let result = SpeedTestResult.decode(testData, idlePass: idlePass,
                                            fallback: parser.progress)
        teardown()
        finish(result)
    }

    private func finish(_ result: Result<SpeedTestResult, SpeedTestResult.Failure>) {
        timeoutWork?.cancel()
        timeoutWork = nil
        let handler = onEvent
        onEvent = nil
        handler?(.finished(result))
    }

    /// Terminates the child, escalating to SIGKILL, and releases everything —
    /// the run's folder too, unless the caller still has to read from it.
    private func endChild(keepingWorkDirectory: Bool = false) {
        timeoutWork?.cancel()
        timeoutWork = nil
        if let task = process {
            process = nil
            task.terminationHandler = nil
            if task.isRunning {
                task.terminate()
                let deadline = Date().addingTimeInterval(0.3)
                while task.isRunning, Date() < deadline { usleep(20_000) }
                if task.isRunning { kill(task.processIdentifier, SIGKILL) }
            }
        }
        if !keepingWorkDirectory { teardown() }
    }

    private func teardown() {
        readSource?.cancel()   // the cancel handler closes masterFD
        readSource = nil
        masterFD = -1
        if stdinWriteFD >= 0 {
            close(stdinWriteFD)
            stdinWriteFD = -1
        }
        pingStdin = nil
        if let directory = workDirectory {
            try? FileManager.default.removeItem(at: directory)
            workDirectory = nil
        }
    }

    /// The working folder of the current run, for the test that proves it is
    /// removed. Nil between runs. Not to be read from inside an event handler,
    /// which already runs on `queue`.
    public var currentWorkDirectoryForTests: URL? {
        queue.sync { workDirectory }
    }
}
