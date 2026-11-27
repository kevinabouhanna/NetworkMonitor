import SwiftUI

/// How the Connections map shades a country (#797): six fixed steps, each ten
/// times the last, with a key. Chosen by Kevin over a log, rank or square-root
/// scale in the design artifact on #797: a shade means the same amount in
/// every period, and countries far apart in amount land on different steps
/// (in his November, the United States, Germany and Russia each on its own).
public enum MapSteps {
    public static let count = 6

    /// Where each step from the second on starts. Bytes: 1 MB, 10 MB, 100 MB,
    /// 1 GB, 10 GB, in the app's own units (1 MB is 1,024 KB, as the hover
    /// text counts). Times blocked: 10, 100, 1,000, 10,000, 100,000.
    public static func edges(_ measure: ServerMeasure) -> [Int64] {
        switch measure {
        case .bytes:
            let mb: Int64 = 1_048_576
            return [mb, 10 * mb, 100 * mb, 1_073_741_824, 10_737_418_240]
        case .blocked:
            return [10, 100, 1_000, 10_000, 100_000]
        }
    }

    /// The step from 0 (lightest) to 5 (deepest); `nil` for nothing at all.
    public static func step(_ value: Int64, _ measure: ServerMeasure) -> Int? {
        guard value > 0 else { return nil }
        return edges(measure).filter { value >= $0 }.count
    }

    /// The key's words for each step, lightest first.
    public static func labels(_ measure: ServerMeasure) -> [String] {
        switch measure {
        case .bytes:
            return [L("Under 1 MB"), L("1–10 MB"), L("10–100 MB"), L("100 MB–1 GB"), L("1–10 GB"), L("10 GB or more")]
        case .blocked:
            return [L("Under 10 times"), L("10–100 times"), L("100–1,000 times"), L("1,000–10,000 times"),
                    L("10,000–100,000 times"), L("100,000 times or more")]
        }
    }

    /// The shades, evenly spaced (in OKLCH) from the palette's palest to its
    /// deepest teal; in Dark Mode from dark to bright. Opaque, so a step
    /// reads the same over any background.
    public static let light: [UInt32] = [0xD4F0F4, 0xAFD5DB, 0x8BBBC2, 0x66A0AB, 0x408793, 0x066E7D]
    public static let dark: [UInt32] = [0x12434C, 0x20606B, 0x2F7E8B, 0x3E9DAC, 0x4EBECF, 0x5FE0F2]

    private static let colors: [Color] = (0..<count).map { AppPalette.dynamic(light: light[$0], dark: dark[$0]) }

    static func color(_ step: Int) -> Color { colors[min(max(step, 0), count - 1)] }
}
