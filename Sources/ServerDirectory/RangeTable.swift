import Foundation

/// Address ranges, each with a label, in a compact file that is mapped into
/// memory rather than read.
///
/// DB-IP publishes its databases as CSV: 711,000 country rows and 477,000
/// owner rows, about 60 MB. `GeoDataBuilder` turns each into one of these, and
/// `ServerDirectory` answers a lookup with a binary search over the starts
/// alone. Only the pages a search touches are ever read from disk.
///
/// Layout, little-endian:
///
///     0    "NMRT"             magic
///     4    UInt16             format version, 1
///     6    UInt16             label index width w: 1, 2 or 4 bytes
///     8    UInt32             IPv4 entries, n4
///     12   UInt32             IPv6 entries, n6
///     16   UInt32             labels, nl
///     20   UInt32             label text, in bytes
///     24   n4 × UInt32        IPv4 range starts, ascending
///          n4 × w             the label index of each; all ones for none
///          n6 × UInt64        IPv6 range starts, first 64 bits, ascending
///          n6 × w             the label index of each; all ones for none
///          (nl + 1) × UInt32  where each label starts in the text, and where it ends
///          label text, UTF-8
///
/// Only starts are stored. A range ends where the next one begins, so gaps in
/// the source are written as entries labelled none.
///
/// The narrowest label width that fits, and IPv6 keyed on its first 64 bits,
/// halve the files. A /64 is one subnet at one site, and DB-IP splits only
/// 419 of its 348,712 IPv6 country ranges inside one; such a /64 takes the
/// label of the range that starts it.
public struct RangeTable {

    /// The label index of an address the source says nothing about.
    public static let none: UInt32 = .max

    static let magic: [UInt8] = Array("NMRT".utf8)
    static let version: UInt16 = 1
    static let headerSize = 24

    public enum ReadError: Error, Equatable {
        case notARangeTable
        case unsupportedVersion(UInt16)
        case truncated
    }

    private let data: Data
    private let labelWidth: Int
    public let ipv4Count: Int
    public let ipv6Count: Int
    public let labelCount: Int
    private let ipv4Labels: Int
    private let ipv6Starts: Int
    private let ipv6Labels: Int
    private let labelOffsets: Int
    private let labelText: Int

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    public init(data: Data) throws {
        guard data.count >= Self.headerSize,
              Array(data.prefix(4)) == Self.magic
        else { throw ReadError.notARangeTable }
        let header = data.withUnsafeBytes { raw in
            (version: raw.loadUnaligned(fromByteOffset: 4, as: UInt16.self).littleEndian,
             width: Int(raw.loadUnaligned(fromByteOffset: 6, as: UInt16.self).littleEndian),
             v4: Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian),
             v6: Int(raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self).littleEndian),
             labels: Int(raw.loadUnaligned(fromByteOffset: 16, as: UInt32.self).littleEndian),
             text: Int(raw.loadUnaligned(fromByteOffset: 20, as: UInt32.self).littleEndian))
        }
        guard header.version == Self.version else {
            throw ReadError.unsupportedVersion(header.version)
        }
        guard [1, 2, 4].contains(header.width) else { throw ReadError.notARangeTable }
        self.data = data
        labelWidth = header.width
        ipv4Count = header.v4
        ipv6Count = header.v6
        labelCount = header.labels
        ipv4Labels = Self.headerSize + 4 * header.v4
        ipv6Starts = ipv4Labels + header.width * header.v4
        ipv6Labels = ipv6Starts + 8 * header.v6
        labelOffsets = ipv6Labels + header.width * header.v6
        labelText = labelOffsets + 4 * (header.labels + 1)
        guard data.count >= labelText + header.text else { throw ReadError.truncated }
    }

    /// The label of the range holding `address`, or nil if it has none.
    public func label(for address: IPAddress) -> String? {
        labelIndex(for: address).map(label(at:))
    }

    /// The index of that label, for callers that group or cache by it.
    public func labelIndex(for address: IPAddress) -> UInt32? {
        data.withUnsafeBytes { raw -> UInt32? in
            let found: Int?
            let labels: Int
            switch address {
            case .v4(let value):
                found = Self.lastStart(atOrBelow: value, count: ipv4Count) {
                    raw.loadUnaligned(fromByteOffset: Self.headerSize + 4 * $0, as: UInt32.self).littleEndian
                }
                labels = ipv4Labels
            case .v6(let value):
                found = Self.lastStart(atOrBelow: value.high, count: ipv6Count) {
                    raw.loadUnaligned(fromByteOffset: ipv6Starts + 8 * $0, as: UInt64.self).littleEndian
                }
                labels = ipv6Labels
            }
            guard let found else { return nil }
            let offset = labels + labelWidth * found
            let index: UInt32
            switch labelWidth {
            case 1:
                let value = raw.loadUnaligned(fromByteOffset: offset, as: UInt8.self)
                index = value == .max ? Self.none : UInt32(value)
            case 2:
                let value = raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian
                index = value == .max ? Self.none : UInt32(value)
            default:
                index = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
            }
            return index == Self.none ? nil : index
        }
    }

    public func label(at index: UInt32) -> String {
        data.withUnsafeBytes { raw in
            let entry = labelOffsets + 4 * Int(index)
            let start = Int(raw.loadUnaligned(fromByteOffset: entry, as: UInt32.self).littleEndian)
            let end = Int(raw.loadUnaligned(fromByteOffset: entry + 4, as: UInt32.self).littleEndian)
            let bytes = UnsafeRawBufferPointer(rebasing: raw[(labelText + start)..<(labelText + end)])
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// Binary search for the last entry whose start is at or below `value`.
    private static func lastStart<Value: Comparable>(atOrBelow value: Value, count: Int,
                                                     start: (Int) -> Value) -> Int? {
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if start(middle) <= value { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }
}

/// Builds a `RangeTable` file from ranges in any order.
public struct RangeTableWriter {

    public enum WriteError: Error, Equatable {
        /// A range whose start and end are different address families.
        case mixedFamilies
        case endBeforeStart
    }

    private var ipv4: [(start: UInt32, end: UInt32, label: UInt32)] = []
    private var ipv6: [(start: IPv6Value, end: IPv6Value, label: UInt32)] = []
    private var labels: [String] = []
    private var labelIndex: [String: UInt32] = [:]

    public init() {}

    /// Adds one range. A nil label marks addresses the source places nowhere,
    /// such as DB-IP's `ZZ`.
    public mutating func add(from start: IPAddress, to end: IPAddress, label: String?) throws {
        var index = RangeTable.none
        if let label { index = intern(label) }
        switch (start, end) {
        case let (.v4(first), .v4(last)):
            guard first <= last else { throw WriteError.endBeforeStart }
            ipv4.append((first, last, index))
        case let (.v6(first), .v6(last)):
            guard first <= last else { throw WriteError.endBeforeStart }
            ipv6.append((first, last, index))
        default:
            throw WriteError.mixedFamilies
        }
    }

    private mutating func intern(_ label: String) -> UInt32 {
        if let index = labelIndex[label] { return index }
        let index = UInt32(labels.count)
        labels.append(label)
        labelIndex[label] = index
        return index
    }

    public func encoded() -> Data {
        let v4 = Self.entries(ipv4.map { ($0.start, $0.end, $0.label) },
                              lowest: UInt32(0), highest: UInt32.max) { $0 + 1 }
        let v6 = Self.byFirst64Bits(Self.entries(ipv6.map { ($0.start, $0.end, $0.label) },
                                                 lowest: IPv6Value(high: 0, low: 0),
                                                 highest: IPv6Value.max) { $0.successor })
        // All ones means none, so the width must leave that value free.
        let width = labels.count < Int(UInt8.max) ? 1 : labels.count < Int(UInt16.max) ? 2 : 4
        func appendLabel(_ index: UInt32, to out: inout Data) {
            switch width {
            case 1:  out.appendLittleEndian(index == RangeTable.none ? UInt8.max : UInt8(index))
            case 2:  out.appendLittleEndian(index == RangeTable.none ? UInt16.max : UInt16(index))
            default: out.appendLittleEndian(index)
            }
        }

        var text = Data()
        var offsets: [UInt32] = [0]
        for label in labels {
            text.append(contentsOf: Array(label.utf8))
            offsets.append(UInt32(text.count))
        }

        var out = Data()
        out.append(contentsOf: RangeTable.magic)
        out.appendLittleEndian(RangeTable.version)
        out.appendLittleEndian(UInt16(width))
        out.appendLittleEndian(UInt32(v4.count))
        out.appendLittleEndian(UInt32(v6.count))
        out.appendLittleEndian(UInt32(labels.count))
        out.appendLittleEndian(UInt32(text.count))
        for entry in v4 { out.appendLittleEndian(entry.start) }
        for entry in v4 { appendLabel(entry.label, to: &out) }
        for entry in v6 { out.appendLittleEndian(entry.start) }
        for entry in v6 { appendLabel(entry.label, to: &out) }
        for offset in offsets { out.appendLittleEndian(offset) }
        out.append(text)
        return out
    }

    /// Sorts the ranges, writes every gap as a `none` entry, and merges
    /// neighbours with the same label, so a lookup never needs a range's end.
    ///
    /// Where two source ranges overlap, the earlier one wins the overlap. DB-IP
    /// publishes none, so this only decides what a malformed file does.
    private static func entries<Value: Comparable>(
        _ ranges: [(Value, Value, UInt32)], lowest: Value, highest: Value,
        successor: (Value) -> Value
    ) -> [(start: Value, label: UInt32)] {
        var entries: [(start: Value, label: UInt32)] = []
        func append(_ start: Value, _ label: UInt32) {
            if entries.last?.label == label { return }
            entries.append((start, label))
        }
        // The first address not yet covered; nil once the highest one is.
        var next: Value? = lowest
        for (start, end, label) in ranges.sorted(by: { $0.0 < $1.0 }) {
            guard let expected = next else { break }
            guard end >= expected else { continue }
            let first = Swift.max(start, expected)
            if first > expected { append(expected, RangeTable.none) }
            append(first, label)
            next = end == highest ? nil : successor(end)
        }
        if let next { append(next, RangeTable.none) }
        return entries
    }

    /// IPv6 entries keyed on their first 64 bits. Where several start inside
    /// one /64, the first keeps it.
    private static func byFirst64Bits(_ entries: [(start: IPv6Value, label: UInt32)])
        -> [(start: UInt64, label: UInt32)] {
        var keyed: [(start: UInt64, label: UInt32)] = []
        for entry in entries {
            if let last = keyed.last {
                if last.start == entry.start.high || last.label == entry.label { continue }
            }
            keyed.append((entry.start.high, entry.label))
        }
        return keyed
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
