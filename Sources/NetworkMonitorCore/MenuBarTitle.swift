import AppKit

/// Builds the status item's title: two stacked lines, download above upload.
///
/// Kept out of `AppDelegate` so the width-stability invariant can be measured in
/// the test suite: this is the one piece of the UI where a formatting mistake is
/// immediately visible as the whole menu bar twitching on every sample.
public enum MenuBarTitle {

    /// The menu bar is 22 pt tall, so the stacked pair must fit inside that.
    ///
    /// Measured two-line heights at natural leading: 8.0 pt → 20.0, 8.5 pt →
    /// 20.0, 9.0 pt → 22.0, 9.5 pt → 24.0. 8.5 pt is the largest size that
    /// leaves any margin. 9 pt measures as *exactly* 22 pt and the top line's
    /// ascenders were visibly clipped once the button's own insets applied.
    static let fontSize: CGFloat = 8.5

    /// Height budget for the status item, for the fit test.
    public static let menuBarHeight: CGFloat = 22

    /// Fully monospaced, deliberately not `monospacedDigitSystemFont`.
    ///
    /// The monospaced-*digit* variant fixes the width of digits only — letters
    /// and spaces keep their proportional advances, so "128 KB/s" and "0 B/s"
    /// render at different widths no matter how carefully the string is padded.
    /// A fully monospaced font makes equal character counts mean equal pixel
    /// widths, which is what the padding in `ByteFormat.menuBarRate` relies on.
    public static let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

    /// Download line colour, `#51FF70`.
    public static let downTint = NSColor(srgbRed: 0x51 / 255, green: 0xFF / 255,
                                         blue: 0x70 / 255, alpha: 1)
    /// Upload line colour, `#E5E5E5`.
    ///
    /// Fixed sRGB values as specified, so they do not adapt to appearance. Both
    /// are light and read well on a dark menu bar; on a light menu bar the upload
    /// line is close to the background.
    public static let upTint = NSColor(srgbRed: 0xE5 / 255, green: 0xE5 / 255,
                                       blue: 0xE5 / 255, alpha: 1)

    public static func downLine(_ bytesPerSecond: Double) -> String {
        "↓ \(ByteFormat.menuBarRate(bytesPerSecond))"
    }

    public static func upLine(_ bytesPerSecond: Double) -> String {
        "↑ \(ByteFormat.menuBarRate(bytesPerSecond))"
    }

    /// The two lines joined, download first.
    public static func string(down: Double, up: Double) -> String {
        "\(downLine(down))\n\(upLine(up))"
    }

    /// The two lines, each tinted separately.
    public static func attributed(down: Double, up: Double) -> NSAttributedString {
        let paragraph = MenuBarTitle.paragraphStyle()
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(
            string: downLine(down) + "\n",
            attributes: [.font: font, .paragraphStyle: paragraph,
                         .foregroundColor: downTint]))
        result.append(NSAttributedString(
            string: upLine(up),
            attributes: [.font: font, .paragraphStyle: paragraph,
                         .foregroundColor: upTint]))
        return result
    }

    private static func paragraphStyle() -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        // Left, not right. Right alignment makes CoreText discard trailing
        // whitespace when it aligns, which defeats the unit-field padding: a
        // "0 B/s " row (one trailing space) rendered a full character further
        // right than a "128 KB/s" row. The status item sizes itself to the
        // title, so alignment buys nothing and only introduces that shift.
        paragraph.alignment = .left
        // Natural leading, deliberately not a forced min/maximumLineHeight.
        // Clamping the line height to less than the font's ascent+descent
        // compressed the box and clipped the top line's ascenders.
        paragraph.lineSpacing = 0
        return paragraph
    }

    /// The title drawn into an image, which is what the status item displays.
    ///
    /// `NSButton` lays a multi-line attributed title out using single-line
    /// baseline assumptions and drew the block above its own bounds, clipping the
    /// top line's ascenders — at every font size tried, including ones whose
    /// measured height fit inside 22 pt. Drawing into a correctly sized image
    /// and letting the button centre that image removes the guesswork entirely.
    ///
    /// `isTemplate = false` is what preserves the green; a template image would
    /// be recoloured to the monochrome menu bar tint.
    public static func image(down: Double, up: Double) -> NSImage {
        let text = attributed(down: down, up: up)
        let textSize = text.size()
        let size = NSSize(width: ceil(textSize.width), height: menuBarHeight)

        let image = NSImage(size: size)
        image.lockFocus()
        // Flipped-text-in-unflipped-context: the rect's origin is bottom-left and
        // the string fills it downward from the top, so centring the rect
        // vertically centres the glyphs.
        let inset = (size.height - textSize.height) / 2
        text.draw(in: NSRect(x: 0, y: inset,
                             width: size.width, height: textSize.height))
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// Rendered width in points, for the width-stability test.
    public static func renderedWidth(down: Double, up: Double) -> Double {
        Double(attributed(down: down, up: up).size().width)
    }

    /// Rendered height in points, for the menu-bar-fit test.
    public static func renderedHeight(down: Double, up: Double) -> Double {
        Double(attributed(down: down, up: up).size().height)
    }
}
