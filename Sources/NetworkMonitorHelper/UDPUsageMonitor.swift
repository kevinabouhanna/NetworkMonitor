import Foundation
import PacketUsage

/// A passive capture while the signed application is asking for UDP counts.
/// Only socket/peer counters cross XPC. There is no packet file.
final class UDPUsageMonitor {
    private struct Peer: Hashable {
        let flow: UDPObservation.Flow
        let effectivePID: Int32?
    }

    private struct Bucket {
        var peers: [Peer: TimedUDPCounts] = [:]
        var packets = 0
        var incomplete = false
    }

    private static let bucketsPerSecond = 50.0
    private let queue = DispatchQueue(label: "com.kevinabouhanna.NetworkMonitor.udp-usage")
    private var capture: Process?
    private var pipe: Pipe?
    private var buffer = Data()
    private var buckets: [Int64: Bucket] = [:]
    private var latestBucket: Int64?
    private var storedPeers = 0
    private var storedPackets = 0
    private var startedAt: Date?
    private var lastFailure: Date?
    private var stopWork: DispatchWorkItem?

    func takeSnapshot(from: Double, to: Double, reply: @escaping (Data) -> Void) {
        queue.async {
            let now = Date()
            let time = now.timeIntervalSince1970
            guard from.isFinite, to.isFinite, 0 < to - from, to - from <= 12,
                  from >= time - 15, to <= time else { reply(Data()); return }
            if self.capture?.isRunning != true {
                self.stop()
                if self.lastFailure.map({ now.timeIntervalSince($0) >= 30 }) ?? true {
                    self.startCapture()
                }
                reply(Data())
                return
            }
            self.scheduleStop()
            let first = Int64((from * Self.bucketsPerSecond).rounded(.down))
            let end = Int64((to * Self.bucketsPerSecond).rounded(.down))
            let relevant = self.buckets.filter { $0.key >= first && $0.key <= end }
            // Retain the ending bucket for the next interval. The timestamp
            // predicate below ensures a packet at the boundary is counted once.
            self.discard(before: end)
            guard let startedAt = self.startedAt, startedAt.timeIntervalSince1970 <= from,
                  !relevant.values.contains(where: \.incomplete) else { reply(Data()); return }
            var totals: [Peer: UDPPeerUsage] = [:]
            for (index, bucket) in relevant {
                for (peer, usage) in bucket.peers {
                    let bytes = index == first || index == end
                        ? usage.bytes(in: from..<to) : (usage.bytesIn, usage.bytesOut)
                    guard bytes.0 > 0 || bytes.1 > 0 else { continue }
                    var total = totals[peer] ?? UDPPeerUsage(socket: peer.flow.socket, address: peer.flow.remoteAddress,
                                                             flow: peer.flow, effectivePID: peer.effectivePID)
                    total.bytesIn += bytes.0
                    total.bytesOut += bytes.1
                    totals[peer] = total
                }
            }
            let snapshot = UDPUsageSnapshot(start: Date(timeIntervalSince1970: from),
                                            end: Date(timeIntervalSince1970: to), peers: Array(totals.values))
            reply((try? JSONEncoder().encode(snapshot)) ?? Data())
        }
    }

    private func startCapture() {
        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/tcpdump")
        task.arguments = ["-i", "pktap", "-nn", "-p", "-q", "-tt", "-k", "NPDI", "-s", "256",
                          "-l", "--immediate-mode", "udp"]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self, weak task] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self, let task else { return }
            self.queue.async {
                guard self.capture === task else { return }
                self.consume(data)
            }
        }
        do {
            try task.run()
            capture = task
            pipe = output
            startedAt = Date()
            scheduleStop()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            lastFailure = Date()
        }
        task.terminationHandler = { [weak self] task in
            self?.queue.async {
                guard let self, self.capture === task else { return }
                self.lastFailure = Date()
                self.stop()
            }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[..<end], as: UTF8.self)
            buffer.removeSubrange(...end)
            guard let packet = UDPObservation(line: line), let timestamp = packet.timestamp,
                  timestamp.isFinite, timestamp > 0, timestamp < 1e10 else { continue }
            let index = Int64((timestamp * Self.bucketsPerSecond).rounded(.down))
            // Keep only enough packets for the slowest sampling profile.
            if latestBucket.map({ index > $0 }) ?? true {
                latestBucket = index
                discard(before: index - Int64(15 * Self.bucketsPerSecond))
            }
            let key = Peer(flow: packet.flow, effectivePID: packet.effectivePID)
            var bucket = buckets.removeValue(forKey: index) ?? Bucket()
            let isNewPeer = bucket.peers[key] == nil
            if storedPackets < 262_144, !isNewPeer || storedPeers < 8_192 {
                bucket.peers[key, default: TimedUDPCounts()].record(timestamp: timestamp, bytes: packet.bytes,
                                                                  inbound: packet.inbound)
                if isNewPeer { storedPeers += 1 }
                storedPackets += 1
                bucket.packets += 1
            } else {
                bucket.incomplete = true
            }
            buckets[index] = bucket
        }
    }

    private func discard(before cutoff: Int64) {
        for key in Array(buckets.keys) where key < cutoff {
            if let discarded = buckets.removeValue(forKey: key) {
                storedPeers -= discarded.peers.count
                storedPackets -= discarded.packets
            }
        }
    }

    private func scheduleStop() {
        stopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        stopWork = work
        // Longer than the app's slowest nettop interval.
        queue.asyncAfter(deadline: .now() + 25, execute: work)
    }

    private func stop() {
        stopWork?.cancel()
        stopWork = nil
        pipe?.fileHandleForReading.readabilityHandler = nil
        if let capture, capture.isRunning { capture.terminate() }
        capture = nil
        pipe = nil
        buffer.removeAll()
        buckets.removeAll()
        latestBucket = nil
        storedPeers = 0
        storedPackets = 0
        startedAt = nil
    }
}
