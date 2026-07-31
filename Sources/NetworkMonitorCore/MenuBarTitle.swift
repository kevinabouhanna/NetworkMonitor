import AppKit

/// Builds the status item's title.
///
/// Kept out of `AppDelegate` so the width-stability invariant can be measured in
/// the test suite: this is the one piece of the UI where a formatting mistake is
/// immediately visible as the whole menu bar twitching on every sample.
public enum MenuBarTitle {

    /// Fully monospaced, deliberately not `monospacedDigitSystemFont`.
    ///
    /// The monospaced-*digit* variant fixes the width of digits only — letters
    /// and spaces keep their proportional advances, so "128 KB/s" and "0 B/s"
    /// render at different widths no matter how carefully the string is padded.
    /// A fully monospaced font makes equal character counts mean equal pixel
    /// widths, which is what the padding in `ByteFormat.menuBarRate` relies on.
    public static let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

    public static func string(down: Double, up: Double) -> String {
        "↓ \(ByteFormat.menuBarRate(down)) ↑ \(ByteFormat.menuBarRate(up))"
    }

    public static func attributed(down: Double, up: Double) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        // Left, not right. Right alignment makes CoreText discard trailing
        // whitespace when it aligns, which defeats the unit-field padding: a
        // "0 B/s " row (one trailing space) rendered a full character further
        // right than a "128 KB/s" row. The status item sizes itself to the
        // title, so alignment buys nothing and only introduces that shift.
        paragraph.alignment = .left
        return NSAttributedString(string: string(down: down, up: up),
                                  attributes: [.font: font, .paragraphStyle: paragraph])
    }

    /// Rendered width in points, for the width-stability test.
    public static func renderedWidth(down: Double, up: Double) -> Double {
        Double(attributed(down: down, up: up).size().width)
    }
}
