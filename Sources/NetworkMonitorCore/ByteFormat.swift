import Foundation

/// Single source of truth for every byte value the app displays.
///
/// Binary (1024-based) steps with the familiar `KB`/`MB`/`GB` labels, per spec.
/// Strictly byte-based — this app never displays bits.
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
    public static func menuBarRate(_ bytesPerSecond: Double,
                                   width: Int = menuBarNumberWidth) -> String {
        let number: String
        let unit: String
        if bytesPerSecond < 1 {
            number = "0"
            unit = "B"
        } else {
            let (value, scaledUnit) = scale(bytesPerSecond)
            unit = scaledUnit
            if scaledUnit == "B" {
                number = "\(Int(value))"
            } else if abs(value) >= 100 {
                // 3 integer digits already fill the field; a decimal would only jitter.
                number = String(format: "%.0f", value)
            } else {
                number = String(format: "%.1f", value)
            }
        }
        return pad(number, to: width) + " " + padTrailing("\(unit)/s", to: menuBarUnitWidth)
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
