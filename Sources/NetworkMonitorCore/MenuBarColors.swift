import AppKit
import Combine

/// The two colours the menu bar readout is drawn in, download over upload.
public struct MenuBarTints: Equatable {
    public let down: NSColor
    public let up: NSColor

    public init(down: NSColor, up: NSColor) {
        self.down = down
        self.up = up
    }

    /// The live rates' colours until someone changes them.
    public static let live = MenuBarTints(down: MenuBarTitle.downTint, up: MenuBarTitle.upTint)

    /// While Block Everything is on (#198): red, so it's never left on by
    /// mistake, whatever colours were chosen.
    public static let blockingEverything = MenuBarTints(
        down: NSColor(srgbRed: 1.0, green: 0.36, blue: 0.33, alpha: 1),
        up: NSColor(srgbRed: 1.0, green: 0.62, blue: 0.6, alpha: 1))

    /// What a speed test can use instead, in order of preference. Cyan first,
    /// the test's colour before the live colours could be changed, so nobody
    /// who keeps the defaults sees anything new. Each pair is a strong colour
    /// over a pale one of the same hue, as the live pair is.
    public static let testChoices = [
        MenuBarTints(down: MenuBarTitle.testDownTint, up: MenuBarTitle.testUpTint),
        MenuBarTints(down: MenuBarColors.color(hex: "#FF6FD8")!, up: MenuBarColors.color(hex: "#FFC2EF")!),
        MenuBarTints(down: MenuBarColors.color(hex: "#FFB340")!, up: MenuBarColors.color(hex: "#FFE0A8")!),
        MenuBarTints(down: MenuBarColors.color(hex: "#A78BFA")!, up: MenuBarColors.color(hex: "#DCD0FF")!),
    ]

    /// How far, in OKLab, each of a test's colours must be from both live ones.
    ///
    /// The download line is what the eye goes to, so its colour has to change
    /// plainly. The pale upload colours sit close together by design (the
    /// default light grey and pale cyan are 0.064 apart), so they only need to
    /// differ. With the defaults the test's cyan is 0.159 from the light grey.
    public static let clearDown = 0.15
    public static let clearUp = 0.05

    /// The tints a speed test uses while the live rates are drawn in `live`:
    /// the first choice that stays clear of both live colours (#45).
    ///
    /// Two live colours can't block every choice except in a narrow band of
    /// combinations, a few hundred of 133,225 tried. Then it's the choice that
    /// comes nearest, which still falls short by less than 0.005.
    public static func test(clearOf live: MenuBarTints) -> MenuBarTints {
        func margin(_ test: MenuBarTints) -> Double {
            let liveColors = [live.down, live.up]
            let down = liveColors.map { MenuBarColors.distance(test.down, $0) - clearDown }.min()!
            let up = liveColors.map { MenuBarColors.distance(test.up, $0) - clearUp }.min()!
            return min(down, up)
        }
        return testChoices.first { margin($0) >= 0 } ?? testChoices.max { margin($0) < margin($1) }!
    }
}

/// The colours of the menu bar's live rates, chosen in Settings › General
/// (#45), and the tints a speed test uses in their place.
///
/// A test takes the menu bar over at the same width, so colour is the only thing
/// that says the figures are a test's: a capacity, not what is moving now. Its
/// tints follow the live colours so the two never look alike; see
/// `MenuBarTints.test(clearOf:)`.
///
/// A colour is saved only while it differs from the default, so a future
/// default reaches everyone who never picked one.
public final class MenuBarColors: ObservableObject {

    @Published public var download: NSColor {
        didSet { colorsDidChange(download, key: Keys.download, default: MenuBarTints.live.down) }
    }
    @Published public var upload: NSColor {
        didSet { colorsDidChange(upload, key: Keys.upload, default: MenuBarTints.live.up) }
    }
    /// What a speed test is drawn in for the current live colours.
    @Published public private(set) var test: MenuBarTints

    /// Called whenever the menu bar should be redrawn.
    public var didChange: (() -> Void)?

    public var live: MenuBarTints { MenuBarTints(down: download, up: upload) }

    public var isDefault: Bool { live.hex == MenuBarTints.live.hex }

    private let defaults: UserDefaults

    private enum Keys {
        static let download = "menuBarDownloadColor"
        static let upload = "menuBarUploadColor"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let download = defaults.string(forKey: Keys.download).flatMap(Self.color(hex:))
            ?? MenuBarTints.live.down
        let upload = defaults.string(forKey: Keys.upload).flatMap(Self.color(hex:))
            ?? MenuBarTints.live.up
        self.download = download
        self.upload = upload
        test = MenuBarTints.test(clearOf: MenuBarTints(down: download, up: upload))
    }

    public func reset() {
        download = MenuBarTints.live.down
        upload = MenuBarTints.live.up
    }

    private func colorsDidChange(_ color: NSColor, key: String, default: NSColor) {
        if Self.hex(color) == Self.hex(`default`) {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(Self.hex(color), forKey: key)
        }
        let test = MenuBarTints.test(clearOf: live)
        if test != self.test { self.test = test }
        didChange?()
    }

    // MARK: Colour values

    /// `#RRGGBB` in sRGB, which is how a colour is saved. A colour from the
    /// colour panel can be in any colour space; it is converted, and clamped.
    public static func hex(_ color: NSColor) -> String {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(srgb.redComponent),
                      byte(srgb.greenComponent), byte(srgb.blueComponent))
    }

    public static func color(hex: String) -> NSColor? {
        guard hex.count == 7, hex.hasPrefix("#"),
              let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// A colour as it is saved and drawn: sRGB, eight bits a channel, opaque.
    public static func normalized(_ color: NSColor) -> NSColor {
        Self.color(hex: hex(color))!
    }

    /// How different two colours look: the straight-line distance in OKLab,
    /// where equal distances look about equally different. 0.02 is about the
    /// smallest difference anyone notices; black to white is 1.
    public static func distance(_ a: NSColor, _ b: NSColor) -> Double {
        let (l1, a1, b1) = oklab(a), (l2, a2, b2) = oklab(b)
        return ((l1 - l2) * (l1 - l2) + (a1 - a2) * (a1 - a2) + (b1 - b2) * (b1 - b2)).squareRoot()
    }

    /// Björn Ottosson's sRGB to OKLab conversion.
    private static func oklab(_ color: NSColor) -> (Double, Double, Double) {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        func linear(_ c: CGFloat) -> Double {
            let c = Double(min(max(c, 0), 1))
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = linear(srgb.redComponent), g = linear(srgb.greenComponent), b = linear(srgb.blueComponent)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }
}

private extension MenuBarTints {
    var hex: [String] { [MenuBarColors.hex(down), MenuBarColors.hex(up)] }
}
