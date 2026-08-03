import Foundation

/// Owns a single long-lived `nettop` subprocess and turns its output into
/// per-second per-process byte deltas.
///
/// One persistent process, not one per poll. Respawning `nettop` every second
/// would force cumulative mode (whose totals are non-monotonic and therefore
/// unusable — see `NettopParser`), pay process-spawn cost 86,400 times a day,
/// and discard a priming sample on every single poll.
public final class NettopStream {

    /// - `-n` numeric addresses. Two reasons: the classifier in `RemoteEndpoint`
    ///   needs an address rather than `ncmrsa-al-in-f5.1e100.net`, and without it
    ///   nettop performs reverse-DNS lookups — a network monitor generating its own
    ///   traffic to describe traffic.
    /// - `-x` raw byte counts, no "MiB" suffixes to re-parse
    /// - `-d` delta mode (required; see `NettopParser`)
    /// - `-L 0` CSV logging mode, unlimited samples
    /// - `-s N` one sample every N seconds, set by `PowerProfile`. Each sample is a
    ///   delta, so a longer interval changes the figures' age, not their total.
    /// - `-t external` all non-loopback interfaces: keeps VPN tunnel traffic,
    ///   drops localhost chatter from dev servers
    /// - `-J …` only the columns we read
    ///
    /// **`-P` is deliberately absent.** It collapses output to one row per process,
    /// which discards the per-socket rows — and those rows carry the remote address
    /// that separates internet traffic from LAN traffic (`RemoteEndpoint`). Without
    /// them, mirroring to an Apple TV over the router reads as internet usage.
    static func arguments(sampleInterval: Int) -> [String] {
        [
            "-n", "-x", "-d", "-L", "0", "-s", "\(max(sampleInterval, 1))",
            "-t", "external",
            "-J", "time,bytes_in,bytes_out",
        ]
    }

    private let executable = "/usr/bin/nettop"
    private let queue = DispatchQueue(label: "com.networkmonitor.nettop")

    private var process: Process?
    private var parser = NettopParser()
    private var stopping = false
    private var restartDelay: TimeInterval = 1
    private var restarting = false

    /// Master side of the pseudo-terminal nettop writes into.
    private var masterFD: Int32 = -1
    /// Write end of nettop's stdin pipe. Held open, never written to: that is what
    /// keeps nettop's poll on stdin blocking instead of spinning. See `spawn()`.
    private var stdinWriteFD: Int32 = -1
    private var readSource: DispatchSourceRead?

    /// Seconds between samples, from `PowerProfile`.
    private var sampleInterval = 1

    /// Called on an internal queue with each completed sample.
    public var onSample: (([NettopRow]) -> Void)?
    /// Called when the subprocess cannot be kept alive.
    public var onFailure: ((String) -> Void)?

    public init(sampleInterval: Int = 1) {
        self.sampleInterval = max(sampleInterval, 1)
    }

    /// Changes the sample interval, restarting `nettop` only if it really changed.
    ///
    /// A restart discards the new process's priming sample, so it loses the traffic
    /// in the gap — which is why the caller should only do this on a power
    /// transition, not on every screen sleep. See `PowerProfile`.
    public func setSampleInterval(_ seconds: Int) {
        let wanted = max(seconds, 1)
        queue.async { [weak self] in
            guard let self, self.sampleInterval != wanted else { return }
            self.sampleInterval = wanted
            guard self.process != nil, !self.stopping else { return }
            self.terminateChild()
            self.teardown()
            self.restartDelay = 1
            self.spawn()
        }
    }

    /// Ends the current child for good, and detaches it on the way out.
    ///
    /// Both halves matter, and each one was a live bug:
    ///
    /// - **Detaching `terminationHandler` first.** An expected death must not be
    ///   routed to `handleTermination`. Left armed, the outgoing child's handler
    ///   fired *after* its replacement had spawned, tore down the replacement's
    ///   descriptors and spawned a third — two nettops billing the same bytes into
    ///   one store, and an orphan that outlived `stop()`.
    /// - **Escalating to `SIGKILL`.** nettop has been observed to survive a plain
    ///   terminate in logging mode. An orphan used to be merely untidy; now that
    ///   `teardown()` closes its stdin, an orphan hits EOF on stdin and spins at
    ///   ~140% of a core for as long as the machine is up (see `spawn()`). Killing
    ///   before the descriptors close keeps that window shut.
    private func terminateChild() {
        guard let task = process else { return }
        process = nil
        task.terminationHandler = nil
        guard task.isRunning else { return }
        task.terminate()
        // Brief, bounded, and only on a path that is already tearing down.
        let deadline = Date().addingTimeInterval(0.3)
        while task.isRunning, Date() < deadline { usleep(20_000) }
        if task.isRunning { kill(task.processIdentifier, SIGKILL) }
    }

    /// Idempotent: calling `start()` on an already-running stream does nothing, so
    /// callers can call it freely without ever ending up with two nettop processes
    /// double-counting every sample.
    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopping = false
            self.restarting = false
            guard self.process == nil else { return }
            Self.reapOrphans()
            self.spawn()
        }
    }

    /// Kills any nettop left behind by a previous run of this app.
    ///
    /// `stop()` and the signal handlers in `main.swift` tear the child down on
    /// every ordinary exit, but nothing can run after `SIGKILL` — a force quit,
    /// a crash, or `kill -9`. What survives is not harmless: an orphaned nettop
    /// holds a pseudo-terminal whose reader is gone and spins at **over a full
    /// core, indefinitely**. One was found on the development machine at 115.8%
    /// having run for four hours, which is what prompted this.
    ///
    /// Reaping at launch rather than only at uninstall means the worst case is
    /// bounded by how long until the app is next started, instead of until
    /// somebody notices their fans.
    ///
    /// Only processes whose parent is `launchd` are killed: a live nettop still
    /// owned by a running instance has a real parent, and the single-instance
    /// guard means that instance is not us.
    static func reapOrphans() {
        let prefix = "nettop -n -x -d"
        guard let output = runCapturing("/bin/ps", ["-axo", "pid=,ppid=,command="])
        else { return }
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3,
                  let pid = Int32(fields[0]), let ppid = Int32(fields[1]),
                  ppid == 1,
                  line.contains(prefix)
            else { continue }
            kill(pid, SIGKILL)
        }
    }

    private static func runCapturing(_ path: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    public var isRunning: Bool {
        queue.sync { process != nil }
    }

    public func stop() {
        queue.sync {
            stopping = true
            // Kill before closing descriptors, so an ignored terminate cannot leave
            // an orphan spinning on a closed stdin. See `terminateChild()`.
            terminateChild()
            teardown()
        }
    }

    /// Launches nettop attached to a pseudo-terminal, with a stdin that blocks.
    ///
    /// **stdout must be a PTY.** nettop block-buffers stdout whenever it is not a
    /// terminal, so a long-lived `-L 0` stream delivers **nothing** for many
    /// seconds at a time — measured at one 16 KB block every ~30 s through a pipe,
    /// versus one flush per second through a PTY. Short `-L 2` invocations appear
    /// to work only because libc flushes at process exit, which is why this hides
    /// during shell testing. `-L` still forces CSV logging mode "even if standard
    /// output is a terminal", so the output stays parseable.
    ///
    /// **stdin must block.** This is what used to make nettop cost ~1.36 cores
    /// continuously — the number that justified switching per-app tracking off on
    /// battery, and so switching it off exactly where per-app cost matters. It was
    /// never the PTY. nettop polls stdin for keystrokes, and `/dev/null` is
    /// *always* ready to read, so the poll returns instantly forever and the
    /// process spins in system time. Handing it the read end of a pipe nobody
    /// writes to makes that poll block. Measured over 20 s per configuration:
    ///
    /// | stdout | stdin | cost | delivery |
    /// |---|---|---|---|
    /// | pipe | `/dev/null` | 142.70% of a core | ~4 s |
    /// | pipe | blocking pipe | 0.40% | ~5 s |
    /// | PTY | `/dev/null` | 140.90% | 1 s |
    /// | **PTY** | **blocking pipe** | **0.55%** | **1 s** |
    ///
    /// A 256× saving with no loss of cadence, which is why per-app tracking now
    /// simply always runs and `PerAppTrackingMode` is gone. Note that an `.app`
    /// launched by Finder or launchd already has `/dev/null` on stdin, so
    /// inheriting rather than redirecting would reproduce the spin — the pipe has
    /// to be explicit.
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

        // The blocking stdin. The parent holds the write end open and never writes
        // to it, so nettop's poll on stdin never becomes ready.
        var stdinFDs: [Int32] = [-1, -1]
        guard pipe(&stdinFDs) == 0 else {
            close(master); close(slave)
            onFailure?("pipe failed: \(String(cString: strerror(errno)))")
            scheduleRestart()
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = Self.arguments(sampleInterval: sampleInterval)
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        task.standardOutput = slaveHandle
        task.standardError = slaveHandle
        task.standardInput = FileHandle(fileDescriptor: stdinFDs[0], closeOnDealloc: false)

        parser.resetForRestart()
        masterFD = master
        stdinWriteFD = stdinFDs[1]

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
            // The child has its own dup of the stdin read end.
            close(stdinFDs[0])
        } catch {
            close(slave)
            close(stdinFDs[0])
            teardown()
            onFailure?("could not launch nettop: \(error.localizedDescription)")
            scheduleRestart()
        }
    }

    /// Reads with `read(2)` rather than `FileHandle.availableData`, which raises an
    /// Objective-C exception on a read error — uncatchable from Swift, so a
    /// disappearing child would take the app down with it.
    private func readAvailable() {
        guard masterFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = read(masterFD, &buffer, buffer.count)

        if count > 0 {
            // A pipe carries exactly what nettop wrote, but stripping CR stays as
            // cheap insurance against one ending up inside a parsed field.
            let bytes = buffer[0..<count].filter { $0 != 0x0D }
            guard let text = String(bytes: bytes, encoding: .utf8) else { return }
            for sample in parser.consume(text) {
                restartDelay = 1   // a real sample proves the stream is healthy
                onSample?(sample)
            }
            return
        }

        // 0 = EOF, which is how a pipe reports the child exiting. EAGAIN/EINTR are
        // spurious wakeups.
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
        // Closing this signals EOF on the dead child's stdin, and stops the
        // descriptor leaking across the restart cycle.
        if stdinWriteFD >= 0 {
            close(stdinWriteFD)
            stdinWriteFD = -1
        }
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
