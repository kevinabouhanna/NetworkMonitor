import Foundation

/// Single source of truth for every byte value the app displays.
///
/// The unit every *speed* is shown in, chosen once in Settings: the menu bar's
/// live rates and the speed test alike, so the two never disagree.
///
/// Bytes by default, the unit the rest of the app and macOS count in. Bits for
/// anyone who would rather check against how their connection is sold: a
/// "100 Mbps" plan without arithmetic.
///
/// Amounts of data — the popover's totals, Usage History — are always bytes.
/// Data plans and caps are sold in gigabytes, so "3.2 Gb used" would only be
/// something to convert back before comparing it with the carrier's figure.
public enum SpeedUnit: String, CaseIterable, Identifiable {
    case bits
    case bytes

    public var id: String { rawValue }

    /// The picker's label, and the unit a "not yet" dash is shown beside.
    public var label: String {
        switch self {
        case .bits:  return "Mbps"
        case .bytes: return "MB/s"
        }
    }
}

/// Binary (1024-based) steps with the familiar `KB`/`MB`/`GB` labels, per spec.
/// Byte-based everywhere except speeds shown in bits; see `SpeedUnit`.
public enum ByteFormat {

    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// Splits a byte count into (scaled value, unit label) using 1024-based steps.
    static func scale(_ bytes: Double) -> (value: Double, unit: String) {
        let magnitude = abs(bytes)
        guard magnitude >= 1024 else { return (bytes, units[0]) }

        var value = bytes
        var index = 0
        // Guard on `units.count - 1` so absurd inputs saturate at PB instead of
        // running off the end of the table.
        while abs(value) >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return (value, units[index])
    }

    /// A cumulative total, e.g. `489.3 MB`. Raw bytes get no decimal — "263 B"
    /// reads better than "263.0 B" and the extra digit carries no information.
    public static func bytes(_ count: Int64) -> String {
        let (value, unit) = scale(Double(count))
        if unit == "B" { return "\(Int64(value)) \(unit)" }
        return String(format: "%.1f %@", value, unit)
    }

    /// A transfer rate, e.g. `128 KB/s`.
    public static func rate(_ bytesPerSecond: Double) -> String {
        // Sub-1 B/s is noise from the sampler, not a meaningful rate.
        guard bytesPerSecond >= 1 else { return "0 B/s" }
        let (value, unit) = scale(bytesPerSecond)
        if unit == "B" { return "\(Int(value)) \(unit)/s" }
        return String(format: "%.1f %@/s", value, unit)
    }

    /// Character width of the numeric field in a menu bar rate.
    public static let menuBarNumberWidth = 5
    /// Character width of the unit suffix field ("B/s" … "GB/s").
    public static let menuBarUnitWidth = 4

    /// Constant-width rate for the menu bar, so the status item never shifts.
    ///
    /// Both fields are padded, not just the number. Padding the digits alone is
    /// not enough: the unit suffix changes length as traffic crosses a boundary
    /// ("B/s" → "KB/s"), and in the system font a space is narrower than a
    /// digit, so equal character counts still rendered at 7 different pixel
    /// widths spanning a 28 pt swing. A constant character count combined with
    /// `MenuBarTitle.font` (fully monospaced, not merely monospaced-digit) is
    /// what actually pins the width.
    ///
    /// Precision is traded against magnitude so the numeric field is always
    /// exactly `menuBarNumberWidth` characters: two decimals where they fit
    /// (`14.14`), then one (`128.5`), then none (`1023`). Scaling keeps the value
    /// in [1, 1024), so those three cases are exhaustive. See `fittedNumber`.
    public static func menuBarRate(_ bytesPerSecond: Double,
                                   width: Int = menuBarNumberWidth) -> String {
        let (value, unit) = bytesPerSecond < 1 ? (0, "B") : scale(bytesPerSecond)
        return pad(fittedNumber(value, width: width), to: width) + " "
            + padTrailing("\(unit)/s", to: menuBarUnitWidth)
    }

    /// `value` with as many decimals, two at most, as fit in `width` characters.
    ///
    /// Judged on the formatted string, never on the value: picking the precision
    /// from the value first let 99.996 round up to "100.00" and 999.96 to
    /// "1000.0", one character too wide (#26).
    static func fittedNumber(_ value: Double, width: Int = menuBarNumberWidth) -> String {
        for decimals in [2, 1] {
            let number = String(format: "%.\(decimals)f", value)
            if number.count <= width { return number }
        }
        return String(format: "%.0f", value)
    }

    /// A live rate for the menu bar in the chosen unit, at the same constant
    /// width either way.
    ///
    /// Sub-1 B/s is sampler noise in bits as much as in bytes, so it reads as
    /// zero in both — otherwise a stray byte would show as "8.00 b/s" and
    /// repaint the menu bar for nothing.
    public static func menuBarRate(_ bytesPerSecond: Double, unit: SpeedUnit) -> String {
        switch unit {
        case .bytes: return menuBarRate(bytesPerSecond)
        case .bits:  return menuBarBitRate(bytesPerSecond < 1 ? 0 : bytesPerSecond * 8)
        }
    }

    // MARK: Bits

    private static let bitUnits = ["bps", "Kbps", "Mbps", "Gbps", "Tbps"]

    /// Splits a bit rate into (scaled value, unit) using 1000-based steps, the
    /// convention for line speeds.
    static func scaleBits(_ bitsPerSecond: Double) -> (value: Double, unit: Int) {
        var value = max(bitsPerSecond, 0)
        var index = 0
        while value >= 1000, index < bitUnits.count - 1 {
            value /= 1000
            index += 1
        }
        return (value, index)
    }

    /// Precision traded against magnitude, as in `menuBarRate`: `9.45`, `16.0`, `940`.
    private static func bitNumber(_ value: Double) -> String {
        if value >= 100 { return String(format: "%.0f", value) }
        if value >= 10 { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }

    /// A speed-test figure split for display: the number large, the unit small.
    public static func bitRateParts(_ bitsPerSecond: Double) -> (number: String, unit: String) {
        let (value, unit) = scaleBits(bitsPerSecond)
        return (bitNumber(value), bitUnits[unit])
    }

    /// A speed-test figure on one line, e.g. `16.0 Mbps`.
    public static func bitRate(_ bitsPerSecond: Double) -> String {
        let parts = bitRateParts(bitsPerSecond)
        return "\(parts.number) \(parts.unit)"
    }

    // MARK: Speed test, in the chosen unit

    /// A speed-test figure split for display, in bits or in the app's own
    /// 1024-based bytes. Bytes use the same scale as the menu bar's live rates,
    /// so a test in MB/s reads in the same terms as the figures beside it.
    public static func speedParts(_ bitsPerSecond: Double,
                                  unit: SpeedUnit) -> (number: String, unit: String) {
        switch unit {
        case .bits:
            return bitRateParts(bitsPerSecond)
        case .bytes:
            let (value, label) = scale(max(bitsPerSecond, 0) / 8)
            return (bitNumber(value), "\(label)/s")
        }
    }

    /// A speed-test figure on one line, e.g. `16.0 Mbps` or `2.10 MB/s`.
    public static func speed(_ bitsPerSecond: Double, unit: SpeedUnit) -> String {
        let parts = speedParts(bitsPerSecond, unit: unit)
        return "\(parts.number) \(parts.unit)"
    }

    /// A speed-test figure for the menu bar, at the live title's exact width in
    /// either unit.
    public static func menuBarSpeed(_ bitsPerSecond: Double, unit: SpeedUnit) -> String {
        switch unit {
        case .bits:  return menuBarBitRate(bitsPerSecond)
        case .bytes: return menuBarRate(bitsPerSecond / 8)
        }
    }

    /// A speed-test figure at exactly the character count of `menuBarRate`, so
    /// the status item keeps its width when the test takes it over.
    ///
    /// "Mb/s" rather than "Mbps" for the same reason: four characters, the width
    /// of the unit field the byte rates already use.
    public static func menuBarBitRate(_ bitsPerSecond: Double) -> String {
        let (value, unit) = scaleBits(bitsPerSecond)
        let label = ["b/s", "Kb/s", "Mb/s", "Gb/s", "Tb/s"][unit]
        return pad(fittedNumber(value), to: menuBarNumberWidth) + " "
            + padTrailing(label, to: menuBarUnitWidth)
    }

    private static func pad(_ string: String, to width: Int) -> String {
        guard string.count < width else { return string }
        return String(repeating: " ", count: width - string.count) + string
    }

    private static func padTrailing(_ string: String, to width: Int) -> String {
        guard string.count < width else { return string }
        return string + String(repeating: " ", count: width - string.count)
    }
}
