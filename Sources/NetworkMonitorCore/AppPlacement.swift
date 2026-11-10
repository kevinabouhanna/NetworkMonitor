import AppKit
import Combine

/// Where NetworkMonitor shows (#69): **Settings › General › Show NetworkMonitor
/// in**. Never neither, as Kevin asked: with no status item and no Dock icon
/// there'd be no way back to the app.
public enum AppPlacement: String, CaseIterable, Identifiable {
    /// The readout in the menu bar, and a Dock icon only while a window is
    /// open. The default, and how the app always was.
    case menuBar
    /// Nothing in the menu bar: a Dock icon all the time, showing the live
    /// speeds or the app's icon, as `DockIcon` says (#523).
    case dock
    /// The readout in the menu bar, and a Dock icon all the time.
    case both

    public var id: String { rawValue }

    /// The status item, with its readout, popover and right-click menu.
    public var showsMenuBar: Bool { self != .dock }
    /// A Dock icon all the time, not only while a window is open.
    public var showsDock: Bool { self != .menuBar }
    /// The live speeds on the Dock icon: only when they aren't in the menu
    /// bar, and the Dock icon is to show them (#523).
    public func drawsSpeedsOnDock(_ icon: DockIcon) -> Bool { self == .dock && icon == .speeds }

    public var label: String {
        switch self {
        case .menuBar: return L("Menu bar")
        case .dock:    return L("Dock")
        case .both:    return L("Both")
        }
    }
}

/// What the Dock icon shows in Dock mode (#523): **Settings › General › Dock
/// icon**, a choice that's there only while Dock is chosen.
public enum DockIcon: String, CaseIterable, Identifiable {
    /// The whole icon is the readout. The default.
    case speeds
    /// The app's own icon, with no speeds.
    case appIcon

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .speeds:  return L("Speeds")
        case .appIcon: return L("App icon")
        }
    }
}

/// The choice, kept in the app's defaults. A launch argument
/// (`-showIn dock`) overrides it for one run, without saving anything, for a
/// check of a development build.
public final class AppPlacementSetting: ObservableObject {
    public static let key = "showIn"
    public static let shared = AppPlacementSetting()

    private let defaults: UserDefaults

    /// Takes effect at once: `AppDelegate` follows it.
    @Published public var placement: AppPlacement {
        didSet {
            guard placement != oldValue else { return }
            // Saved only while it differs from the default, as the colours
            // are, so a future default reaches everyone who never chose.
            if placement == .menuBar {
                defaults.removeObject(forKey: Self.key)
            } else {
                defaults.set(placement.rawValue, forKey: Self.key)
            }
        }
    }

    public static let dockIconKey = "dockIcon"

    /// What the Dock icon shows in Dock mode (#523). Kept when another mode
    /// is chosen, for the next time Dock is.
    @Published public var dockIcon: DockIcon {
        didSet {
            guard dockIcon != oldValue else { return }
            if dockIcon == .speeds {
                defaults.removeObject(forKey: Self.dockIconKey)
            } else {
                defaults.set(dockIcon.rawValue, forKey: Self.dockIconKey)
            }
        }
    }

    /// The speeds on the Dock icon, as the two choices make it.
    public var drawsSpeedsOnDock: Bool { placement.drawsSpeedsOnDock(dockIcon) }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        placement = defaults.string(forKey: Self.key).flatMap(AppPlacement.init) ?? .menuBar
        dockIcon = defaults.string(forKey: Self.dockIconKey).flatMap(DockIcon.init) ?? .speeds
    }
}

/// The readout's two lines and their colours: what the menu bar draws, and the
/// Dock icon in Dock mode (#69, #523).
public struct SpeedReadout: Equatable {
    public let down: String
    public let up: String
    public let tints: MenuBarTints

    public init(down: String, up: String, tints: MenuBarTints) {
        self.down = down
        self.up = up
        self.tints = tints
    }
}


/// The Dock icon in Dock mode with **Dock icon: Speeds** (#523): the whole
/// icon is the readout, on a plain rounded square that follows light and
/// dark, with no app icon behind it. Each speed is its arrow and figure, as
/// large as fits, with its unit under it: two lines of the menu bar's eleven
/// characters would leave the figures half as tall.
///
/// The Dock draws a tile's content view only when told to
/// (`NSDockTile.display()`), so this costs nothing between readings; see
/// `AppDelegate.drawDockReadout()` for how often that is.
public final class DockSpeedView: NSView {
    public var readout: SpeedReadout? {
        didSet { if readout != oldValue { needsDisplay = true } }
    }

    /// The icon's rounded square, as a fraction of the tile on each side
    /// (100 of 1,024 px, as macOS draws every app icon), and its corners.
    static let iconInset: CGFloat = 100 / 1024
    static let cornerRadius: CGFloat = 185 / 1024
    /// Space between the text and the square's sides, as a fraction of the tile.
    static let textPadding: CGFloat = 0.06
    /// A unit's size, as a fraction of its figure's.
    static let unitScale: CGFloat = 0.55
    /// The widest figure there can be, so the size and the left edge stay put
    /// whatever the figures.
    static let template = "↓ 88888"

    public override init(frame: NSRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Whether to draw for dark: the view's own appearance, which follows the
    /// app's, which follows the Mac's.
    var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    public override func draw(_ dirtyRect: NSRect) {
        let dark = isDark
        let square = Self.squareRect(in: bounds)
        let radius = bounds.width * Self.cornerRadius
        // A shadow under the square, as every icon in the Dock has.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = bounds.width * 0.02
        shadow.shadowOffset = NSSize(width: 0, height: -bounds.width * 0.01)
        shadow.set()
        Self.background(dark: dark).setFill()
        NSBezierPath(roundedRect: square, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()

        guard let readout else { return }
        let layout = Self.layout(for: readout, in: bounds)
        let tints = [readout.tints.down, readout.tints.up].map { MenuBarColors.readable($0, onDark: dark) }
        for (line, tint) in zip(layout.lines, tints) {
            NSAttributedString(string: line.figure, attributes: [.font: layout.figureFont, .foregroundColor: tint])
                .draw(at: line.figureOrigin)
            NSAttributedString(string: line.unit, attributes: [.font: layout.unitFont, .foregroundColor: tint])
                .draw(at: line.unitOrigin)
        }
    }

    /// The square's colour: near black in dark, near white in light.
    public static func background(dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
             : NSColor(srgbRed: 0.98, green: 0.98, blue: 0.98, alpha: 1)
    }

    /// Where the icon's rounded square goes on a tile of `bounds`.
    public static func squareRect(in bounds: NSRect) -> NSRect {
        bounds.insetBy(dx: bounds.width * iconInset, dy: bounds.height * iconInset)
    }

    /// One speed: its arrow and figure, and its unit, each in its own box.
    public struct Line {
        public let figure: String
        public let unit: String
        public let figureOrigin: NSPoint
        public let unitOrigin: NSPoint
        public let figureFrame: NSRect
        public let unitFrame: NSRect
    }

    public struct Layout {
        public let figureFont: NSFont
        public let unitFont: NSFont
        public let lines: [Line]
    }

    /// A readout line, "↓ 12.34 MB/s", as its figure, "↓ 12.34", and unit,
    /// "MB/s". The figure keeps its padding, as figure spaces, so it's always
    /// the width of `template`.
    static func split(_ line: String) -> (figure: String, unit: String) {
        var trimmed = Substring(line)
        while trimmed.last == " " { trimmed.removeLast() }
        guard let space = trimmed.lastIndex(of: " ") else { return (spaced(String(trimmed)), "") }
        return (spaced(String(trimmed[..<space])), String(trimmed[trimmed.index(after: space)...]))
    }

    /// The readout pads its figures with spaces to one width in a monospaced
    /// font. Here, in a narrower one with figures of one width, figure spaces
    /// keep that padding the width of a digit.
    static func spaced(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "\u{2007}")
    }

    /// Condensed, bold and with figures of one width: the most legible way to
    /// get a figure across a Dock icon.
    static func font(ofSize size: CGFloat, weight: NSFont.Weight = .bold) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight, width: .condensed)
        let tabular = base.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
        ]]])
        return NSFont(descriptor: tabular, size: size) ?? base
    }

    /// The figures as large as fit the square, across and down: download's
    /// figure, its unit under it at the figure's right edge, then upload's,
    /// the four centred as a block.
    public static func layout(for readout: SpeedReadout, in bounds: NSRect) -> Layout {
        let box = squareRect(in: bounds).insetBy(dx: bounds.width * textPadding, dy: bounds.width * textPadding)
        let parts = [split(readout.down), split(readout.up)]
        func width(_ text: String, _ font: NSFont) -> CGFloat {
            NSAttributedString(string: text, attributes: [.font: font]).size().width
        }
        func height(_ font: NSFont) -> CGFloat { font.ascender - font.descender }

        let reference: CGFloat = 20
        let measuring = font(ofSize: reference)
        let measuringUnit = font(ofSize: reference * unitScale, weight: .semibold)
        let widest = ([spaced(template)] + parts.map(\.figure)).map { width($0, measuring) }.max() ?? 1
        let across = box.width / max(widest, 1)
        let down = box.height / (2 * (height(measuring) + height(measuringUnit)))
        let size = floor(reference * min(across, down) * 10) / 10
        let figureFont = font(ofSize: size)
        let unitFont = font(ofSize: size * unitScale, weight: .semibold)

        // From a fixed left edge, so the figures never shift as they change.
        let figureWidth = max(width(spaced(template), figureFont), parts.map { width($0.figure, figureFont) }.max() ?? 0)
        let left = box.midX - figureWidth / 2
        let right = left + figureWidth
        let figureHeight = height(figureFont), unitHeight = height(unitFont)
        var top = box.midY + (figureHeight + unitHeight)
        let lines = parts.map { part -> Line in
            let figureFrame = NSRect(x: left, y: top - figureHeight,
                                     width: width(part.figure, figureFont), height: figureHeight)
            top -= figureHeight
            let unitWidth = width(part.unit, unitFont)
            let unitFrame = NSRect(x: right - unitWidth, y: top - unitHeight, width: unitWidth, height: unitHeight)
            top -= unitHeight
            return Line(figure: part.figure, unit: part.unit,
                        figureOrigin: figureFrame.origin, unitOrigin: unitFrame.origin,
                        figureFrame: figureFrame, unitFrame: unitFrame)
        }
        return Layout(figureFont: figureFont, unitFont: unitFont, lines: lines)
    }

    /// The icon as a picture, at `side` points and twice that in pixels, for
    /// the tests and for checking it by eye (`DesignShots --dock-icons`).
    public static func image(_ readout: SpeedReadout, side: CGFloat, dark: Bool) -> NSImage {
        let view = DockSpeedView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.readout = readout
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side * 2), pixelsHigh: Int(side * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
