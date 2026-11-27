/// The contiguous prefix the outbound probe has allowed. A data callback can
/// repeat bytes it has already seen, so only the new suffix advances it.
public struct OutboundByteCount {
    public private(set) var bytes = 0

    public init() {}

    public mutating func advance(offset: Int, count: Int) -> Int? {
        guard offset >= 0, offset <= bytes, count >= 0 else { return nil }
        let (end, overflow) = offset.addingReportingOverflow(count)
        guard !overflow else { return nil }
        let added = max(0, end - bytes)
        bytes += added
        return added
    }
}
