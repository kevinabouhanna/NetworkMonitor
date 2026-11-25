import Foundation

/// The network a nettop sample is taken on (#759).
///
/// A sample can wait for the helper (#753), and reach the store once the Mac is
/// on another network. It isn't that network's traffic, so it stays out of its
/// figures.
public final class SampleNetwork {
    private let lock = NSLock()
    private var id = NetworkFingerprint.offline.id

    public init() {}

    /// Read on nettop's queue, as a sample arrives.
    public var current: String { lock.withLock { id } }

    public func moved(to fingerprint: NetworkFingerprint) {
        lock.withLock { id = fingerprint.id }
    }

    /// Whether a sample taken on one network is still the store's to record.
    /// Offline is a gap, not a network, as in `UsageStore`: what was sampled
    /// around it belongs to the network that comes back.
    public static func keeps(sampleFrom taken: String, on current: String) -> Bool {
        let offline = NetworkFingerprint.offline.id
        return taken == current || taken == offline || current == offline
    }
}
