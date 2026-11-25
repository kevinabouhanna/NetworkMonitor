import Foundation
import PacketUsage

/// Counts what UDP sockets move on your own network, while the app asks (#753).
///
/// It reads what macOS's own `tcpdump` prints, with a fixed filter that only
/// lets through packets between two addresses on your own network: nothing
/// sent to or received from the internet. Only bytes per socket cross XPC, and
/// nothing is written to disk.
final class UDPUsageMonitor {
    /// Without a question for this long, it stops. Long enough to keep a capture
    /// through the gaps of something that sends in bursts.
    static let idleStop: TimeInterval = 120

    private let queue = DispatchQueue(label: "com.kevinabouhanna.NetworkMonitor.udp-usage")
    private var capture: Process?
    private var pipe: Pipe?
    private var buffer = Data()
    private var counts = UDPUsageCounts()
    private var lastFailure: Date?
    private var stopWork: DispatchWorkItem?

    /// The counts so far, or nothing when there's no capture to be had. The
    /// first question starts it, and is answered with counts of zero.
    func snapshot(reply: @escaping (Data) -> Void) {
        queue.async {
            if self.capture?.isRunning != true {
                self.stopOnQueue()
                if self.lastFailure.map({ Date().timeIntervalSince($0) >= 30 }) ?? true { self.startCapture() }
            }
            guard self.capture != nil else { reply(Data()); return }
            self.scheduleStop()
            reply((try? JSONEncoder().encode(self.counts.snapshot)) ?? Data())
        }
    }

    /// Before the daemon quits: `tcpdump` would outlive it.
    func stop() {
        queue.sync { stopOnQueue() }
    }

    private func startCapture() {
        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/tcpdump")
        // No `--immediate-mode`: packets come in batches, which is most of the
        // saving. `UDPUsageCredit` allows for their coming late.
        task.arguments = ["-i", "pktap", "-nn", "-p", "-q", "-t", "-k", "NPDI", "-s", "256", "-l",
                          UDPObservation.filter]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self, weak task] handle in
            let data = handle.availableData
            // The end of it: a tcpdump that died by itself would have this
            // called over and over.
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            guard let self, let task else { return }
            self.queue.async {
                guard self.capture === task else { return }
                self.consume(data)
            }
        }
        task.terminationHandler = { [weak self] task in
            self?.queue.async {
                guard let self, self.capture === task else { return }
                self.lastFailure = Date()
                self.stopOnQueue()
            }
        }
        do {
            try task.run()
            capture = task
            pipe = output
            counts = UDPUsageCounts()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            lastFailure = Date()
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        var rest = buffer[...]
        while let end = rest.firstIndex(of: 10) {
            if let packet = UDPObservation(line: String(decoding: rest[..<end], as: UTF8.self)) {
                counts.record(packet)
            }
            rest = rest[(end + 1)...]
        }
        // A line is under 300 bytes; past this it isn't tcpdump's.
        buffer = rest.count > 65_536 ? Data() : Data(rest)
    }

    private func scheduleStop() {
        stopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.stopOnQueue() }
        stopWork = work
        queue.asyncAfter(deadline: .now() + Self.idleStop, execute: work)
    }

    private func stopOnQueue() {
        stopWork?.cancel()
        stopWork = nil
        pipe?.fileHandleForReading.readabilityHandler = nil
        let task = capture
        capture = nil
        pipe = nil
        buffer = Data()
        if let task, task.isRunning { task.terminate() }
    }
}
