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
/// icon is the readout, drawn like the app's own icon: its squircle and
/// lighting, near black in dark mode and near white in light, following the
/// Mac's appearance. Each speed is an arrow like the icon's and its figure,
/// as large as fits, with its unit under it.
///
/// The Dock gets one 256 px picture of the tile (128 pt at 2x, however it's
/// given) and shrinks it to its own size, 116 px for a 58 pt Dock: measured
/// with `NSDockTile` and `applicationIconImage` alike, so nothing drawn here
/// can match the Dock's pixels. What keeps it sharp is size and weight: three
/// significant figures, which the Dock has room to show twice as tall as the
/// readout's five, in SF Pro Rounded bold, and every edge on a whole pixel of
/// the picture.
///
/// The Dock draws a tile's content view only when told to
/// (`NSDockTile.display()`), so this costs nothing between readings; see
/// `AppDelegate.drawDockReadout()` for how often that is.
public final class DockSpeedView: NSView {
    public var readout: SpeedReadout? {
        didSet { if readout != oldValue { needsDisplay = true } }
    }

    /// The app icon's grid, on a 1,024 canvas: an 824 squircle with a 100
    /// margin all round (Scripts/make-icon.swift draws the icon on it).
    static let iconInset: CGFloat = 100 / 1024
    /// Space between the figures and the squircle's sides and top and
    /// bottom, as fractions of the tile.
    static let padding = NSSize(width: 0.065, height: 0.075)
    /// A unit's size, as a fraction of its figure's.
    static let unitScale: CGFloat = 0.5
    /// The widest figure there is, so the size and the right edge stay put
    /// whatever the figures: three significant figures and a point.
    static let template = "88.8"
    /// An arrow's width, and the gaps, as fractions of the figures' cap height.
    static let arrowWidth: CGFloat = 0.62
    static let arrowGap: CGFloat = 0.32
    static let unitGap: CGFloat = 0.28
    static let rowGap: CGFloat = 0.36

    public override init(frame: NSRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Whether to draw for dark: the view's own appearance, which follows the
    /// app's, which follows the Mac's.
    var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dark = isDark
        let body = Self.squareRect(in: bounds)
        let shape = Self.squircle(in: body)

        // The icon's lighting: a slight lift from bottom to top.
        context.saveGState()
        context.addPath(shape)
        context.clip()
        let (top, bottom) = Self.background(dark: dark)
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                     colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY),
                                       end: CGPoint(x: 0, y: body.minY), options: [])
        }
        context.restoreGState()
        // On light, a hairline keeps its edge against a light Dock.
        if !dark {
            context.saveGState()
            context.addPath(shape)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.14).cgColor)
            context.setLineWidth(bounds.width / 256)
            context.strokePath()
            context.restoreGState()
        }

        guard let readout else { return }
        // Pixels per point in the picture being drawn, for whole-pixel edges.
        let scale = context.userSpaceToDeviceSpaceTransform.a
        let layout = Self.layout(for: readout, in: bounds, pixelsPerPoint: scale)
        let tints = [readout.tints.down, readout.tints.up].map { MenuBarColors.readable($0, onDark: dark) }
        for (index, (line, tint)) in zip(layout.lines, tints).enumerated() {
            context.setFillColor(tint.cgColor)
            context.addPath(Self.arrow(in: line.arrowFrame, pointingDown: index == 0))
            context.fillPath()
            NSAttributedString(string: line.figure, attributes: [.font: layout.figureFont, .foregroundColor: tint])
                .draw(at: NSPoint(x: line.figureFrame.minX, y: line.figureFrame.minY + layout.figureFont.descender))
            NSAttributedString(string: line.unit, attributes: [.font: layout.unitFont, .foregroundColor: tint])
                .draw(at: NSPoint(x: line.unitFrame.minX, y: line.unitFrame.minY + layout.unitFont.descender))
        }
    }

    /// The squircle's colours, top and bottom: the app icon's near black in
    /// dark, and near white in light.
    public static func background(dark: Bool) -> (top: NSColor, bottom: NSColor) {
        dark ? (NSColor(srgbRed: 0.19, green: 0.19, blue: 0.20, alpha: 1),
                NSColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 1))
             : (NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                NSColor(srgbRed: 0.90, green: 0.90, blue: 0.91, alpha: 1))
    }

    /// Where the icon's squircle goes on a tile of `bounds`.
    public static func squareRect(in bounds: NSRect) -> NSRect {
        bounds.insetBy(dx: bounds.width * iconInset, dy: bounds.height * iconInset)
    }

    /// Apple's icon shape, as the app icon draws it: a superellipse that
    /// matches the 185 radius on an 824 body.
    static func squircle(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let exponent: CGFloat = 2 / 6.2
        for step in 0...360 {
            let t = CGFloat(step) / 360 * 2 * .pi
            let c = cos(t), s = sin(t)
            let point = CGPoint(x: rect.midX + rect.width / 2 * (c < 0 ? -1 : 1) * pow(abs(c), exponent),
                                y: rect.midY + rect.height / 2 * (s < 0 ? -1 : 1) * pow(abs(s), exponent))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// The app icon's blunt arrow: a stem on a full-width head.
    static func arrow(in rect: CGRect, pointingDown: Bool) -> CGPath {
        let head = rect.height * 0.5
        let stem = rect.width * 0.42
        let path = CGMutablePath()
        if pointingDown {
            path.addRect(CGRect(x: rect.midX - stem / 2, y: rect.minY + head * 0.98,
                                width: stem, height: rect.height - head * 0.98))
            path.addLines(between: [CGPoint(x: rect.minX, y: rect.minY + head),
                                    CGPoint(x: rect.maxX, y: rect.minY + head),
                                    CGPoint(x: rect.midX, y: rect.minY)])
        } else {
            path.addRect(CGRect(x: rect.midX - stem / 2, y: rect.minY,
                                width: stem, height: rect.height - head * 0.98))
            path.addLines(between: [CGPoint(x: rect.minX, y: rect.maxY - head),
                                    CGPoint(x: rect.maxX, y: rect.maxY - head),
                                    CGPoint(x: rect.midX, y: rect.maxY)])
        }
        path.closeSubpath()
        return path
    }

    /// One speed: its arrow, figure and unit, each in its own box.
    public struct Line {
        public let figure: String
        public let unit: String
        public let arrowFrame: NSRect
        /// From the baseline to the top of the figures' caps.
        public let figureFrame: NSRect
        /// From the baseline to the top of the unit's caps.
        public let unitFrame: NSRect
    }

    public struct Layout {
        public let figureFont: NSFont
        public let unitFont: NSFont
        public let lines: [Line]
    }

    /// A readout line, "↓ 12.34 MB/s", as its figure to three significant
    /// figures, "12.3", and its unit, "MB/s". Five figures are what the menu
    /// bar has room for; the Dock has room for three at twice the size.
    static func split(_ line: String) -> (figure: String, unit: String) {
        let words = line.split(separator: " ")
        guard words.count >= 3, let value = Double(words[1]) else {
            return (words.dropFirst().first.map(String.init) ?? "", words.last.map(String.init) ?? "")
        }
        return (figure(value), String(words[2]))
    }

    /// Three significant figures, or fewer: 0, 1.23, 12.3, 123. Never four, so
    /// a 999.7 the readout hasn't moved on to the next unit for is 999.
    static func figure(_ value: Double) -> String {
        switch value {
        case ..<0.005: return "0"
        case ..<9.995: return String(format: "%.2f", value)
        case ..<99.95: return String(format: "%.1f", value)
        default:       return String(format: "%.0f", min(value.rounded(), 999))
        }
    }

    /// SF Pro Rounded with figures of one width.
    static func font(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let descriptor = (base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor)
            .addingAttributes([.featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]]])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// The figures as large as fit the squircle, across and down: download's
    /// arrow and figure, its unit under the figure's right edge, then upload's,
    /// the two centred as a block, every edge on a whole pixel.
    public static func layout(for readout: SpeedReadout, in bounds: NSRect,
                              pixelsPerPoint: CGFloat = 2) -> Layout {
        let box = squareRect(in: bounds).insetBy(dx: bounds.width * padding.width,
                                                 dy: bounds.height * padding.height)
        let parts = [split(readout.down), split(readout.up)]
        func width(_ text: String, _ font: NSFont) -> CGFloat {
            NSAttributedString(string: text, attributes: [.font: font]).size().width
        }
        func snap(_ value: CGFloat) -> CGFloat { (value * pixelsPerPoint).rounded() / pixelsPerPoint }
        func rowWidth(_ font: NSFont) -> CGFloat {
            let figures = ([template] + parts.map(\.figure)).map { width($0, font) }.max() ?? 0
            return font.capHeight * (arrowWidth + arrowGap) + figures
        }
        func blockHeight(_ font: NSFont, _ unitFont: NSFont) -> CGFloat {
            2 * (font.capHeight * (1 + unitGap) + unitFont.capHeight) + font.capHeight * rowGap
        }

        let reference: CGFloat = 20
        let measuring = font(ofSize: reference, weight: .bold)
        let measuringUnit = font(ofSize: reference * unitScale, weight: .semibold)
        let across = box.width / rowWidth(measuring)
        let down = box.height / blockHeight(measuring, measuringUnit)
        let size = floor(reference * min(across, down) * 4) / 4
        let figureFont = font(ofSize: size, weight: .bold)
        let unitFont = font(ofSize: size * unitScale, weight: .semibold)

        let cap = figureFont.capHeight
        let unitCap = unitFont.capHeight
        let rowFull = rowWidth(figureFont)
        let left = snap(box.midX - rowFull / 2)
        let right = snap(left + rowFull)
        var top = box.midY + blockHeight(figureFont, unitFont) / 2
        let lines = parts.map { part -> Line in
            let capTop = snap(top)
            let baseline = snap(top - cap)
            let arrowFrame = NSRect(x: left, y: baseline, width: snap(cap * arrowWidth), height: capTop - baseline)
            let figureWidth = width(part.figure, figureFont)
            let figureFrame = NSRect(x: snap(right - figureWidth), y: baseline,
                                     width: figureWidth, height: capTop - baseline)
            let unitBaseline = snap(top - cap * (1 + unitGap) - unitCap)
            let unitWidth = width(part.unit, unitFont)
            let unitFrame = NSRect(x: snap(right - unitWidth), y: unitBaseline, width: unitWidth, height: unitCap)
            top -= cap * (1 + unitGap) + unitCap + cap * rowGap
            return Line(figure: part.figure, unit: part.unit, arrowFrame: arrowFrame,
                        figureFrame: figureFrame, unitFrame: unitFrame)
        }
        return Layout(figureFont: figureFont, unitFont: unitFont, lines: lines)
    }

    /// The icon as a picture, at `side` points and `scale` times that in
    /// pixels, for the tests and for checking it by eye
    /// (`DesignShots --dock-icons`).
    public static func image(_ readout: SpeedReadout?, side: CGFloat, dark: Bool, scale: CGFloat = 2) -> NSImage {
        let view = DockSpeedView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.readout = readout
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side * scale), pixelsHigh: Int(side * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
