import Foundation

/// Owns a single long-lived `nettop` subprocess and turns its output into
/// per-second per-process byte deltas.
///
/// One persistent process, not one per poll. Respawning `nettop` every second
/// would force cumulative mode (whose totals are non-monotonic and therefore
/// unusable — see `NettopParser`), pay process-spawn cost 86,400 times a day,
/// and discard a priming sample on every single poll.
public final class NettopStream {

    /// - `-P` collapse to one row per process
    /// - `-x` raw byte counts, no "MiB" suffixes to re-parse
    /// - `-d` delta mode (required; see `NettopParser`)
    /// - `-L 0` CSV logging mode, unlimited samples
    /// - `-s 1` one sample per second
    /// - `-t external` all non-loopback interfaces: keeps VPN tunnel traffic,
    ///   drops localhost chatter from dev servers
    /// - `-J …` only the columns we read
    static let arguments = [
        "-P", "-x", "-d", "-L", "0", "-s", "1",
        "-t", "external",
        "-J", "time,bytes_in,bytes_out",
    ]

    private let executable = "/usr/bin/nettop"
    private let queue = DispatchQueue(label: "com.networkmonitor.nettop")

    private var process: Process?
    private var parser = NettopParser()
    private var stopping = false
    private var restartDelay: TimeInterval = 1
    private var restarting = false

    /// Master side of the pseudo-terminal nettop writes into.
    private var masterFD: Int32 = -1
    private var readSource: DispatchSourceRead?

    /// Called on an internal queue with each completed sample.
    public var onSample: (([NettopRow]) -> Void)?
    /// Called when the subprocess cannot be kept alive.
    public var onFailure: ((String) -> Void)?

    public init() {}

    /// Idempotent: calling `start()` on an already-running stream does nothing,
    /// so the tracking-mode logic can call it freely without ever ending up with
    /// two nettop processes double-counting every sample.
    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopping = false
            self.restarting = false
            guard self.process == nil else { return }
            self.spawn()
        }
    }

    public var isRunning: Bool {
        queue.sync { process != nil }
    }

    public func stop() {
        queue.sync {
            stopping = true
            teardown()
            // nettop ignores a plain terminate while in logging mode often
            // enough that leaving it would orphan the child on quit.
            process?.terminate()
            process = nil
        }
    }

    /// Launches nettop attached to a pseudo-terminal.
    ///
    /// A plain `Pipe()` does not work. nettop block-buffers stdout whenever it is
    /// not a terminal, so a long-lived `-L 0` stream delivers **nothing** for many
    /// seconds at a time — measured at zero output over 9 s through a pipe, versus
    /// one flush per second through a PTY. Short `-L 2` invocations appear to work
    /// only because libc flushes at process exit, which is why this bug hides
    /// during shell testing.
    ///
    /// Handing nettop a PTY makes it line-buffer while `-L` still forces CSV
    /// logging mode ("even if standard output is a terminal"), so we keep the
    /// parseable output and get it promptly.
    private func spawn() {
        guard !stopping else { return }
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            onFailure?("nettop not found at \(executable)")
            return
        }

        var master: Int32 = 0
        var slave: Int32 = 0
        // A narrow terminal could wrap the CSV rows and corrupt parsing, so ask
        // for one far wider than any row nettop produces.
        var size = winsize(ws_row: 200, ws_col: 2000, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            onFailure?("openpty failed: \(String(cString: strerror(errno)))")
            scheduleRestart()
            return
        }

        // Raw mode: stop the line discipline translating \n into \r\n and
        // echoing, so the parser sees exactly what nettop wrote.
        var settings = termios()
        if tcgetattr(slave, &settings) == 0 {
            cfmakeraw(&settings)
            _ = tcsetattr(slave, TCSANOW, &settings)
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = Self.arguments
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        task.standardOutput = slaveHandle
        task.standardError = slaveHandle
        // No stdin: nettop must not wait on interactive keystrokes.
        task.standardInput = FileHandle.nullDevice

        parser.resetForRestart()
        masterFD = master

        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { close(master) }
        source.resume()
        readSource = source

        task.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.handleTermination() }
        }

        do {
            try task.run()
            process = task
            // The parent must drop its copy of the slave, otherwise the PTY
            // never reports EOF when nettop exits and a dead child looks alive.
            close(slave)
        } catch {
            close(slave)
            teardown()
            onFailure?("could not launch nettop: \(error.localizedDescription)")
            scheduleRestart()
        }
    }

    /// Reads with `read(2)` rather than `FileHandle.availableData`.
    ///
    /// When the child exits, the master side of a PTY reports `EIO` instead of a
    /// clean EOF, and `availableData` raises an Objective-C exception on that —
    /// which cannot be caught in Swift and would terminate the app.
    private func readAvailable() {
        guard masterFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = read(masterFD, &buffer, buffer.count)

        if count > 0 {
            // The PTY is raw, but strip any stray CR defensively so a carriage
            // return can never end up inside a parsed field.
            let bytes = buffer[0..<count].filter { $0 != 0x0D }
            guard let text = String(bytes: bytes, encoding: .utf8) else { return }
            for sample in parser.consume(text) {
                restartDelay = 1   // a real sample proves the stream is healthy
                onSample?(sample)
            }
            return
        }

        // 0 = EOF, -1 with EIO = child gone. EAGAIN is a spurious wakeup.
        if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
        handleTermination()
    }

    private func handleTermination() {
        guard !stopping else { return }
        teardown()
        scheduleRestart()
    }

    private func teardown() {
        readSource?.cancel()   // cancel handler closes masterFD
        readSource = nil
        masterFD = -1
    }

    /// Exponential backoff so a persistently failing `nettop` can't spin.
    ///
    /// Guarded by `restarting` because termination can be signalled twice — once
    /// by the read source seeing EIO and once by `terminationHandler` — and two
    /// restarts would leave a duplicate nettop double-counting every sample.
    private func scheduleRestart() {
        queue.async { [weak self] in
            guard let self, !self.stopping, !self.restarting else { return }
            self.restarting = true
            self.process = nil
            let delay = self.restartDelay
            self.restartDelay = min(delay * 2, 30)
            self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.stopping else { return }
                self.restarting = false
                self.spawn()
            }
        }
    }
}
