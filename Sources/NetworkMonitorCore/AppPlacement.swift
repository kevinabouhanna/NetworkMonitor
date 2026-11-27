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
    /// The readout in the menu bar, and a Dock icon all the time, showing the
    /// app's icon or the live speeds (#523).
    case both

    public var id: String { rawValue }

    /// The status item, with its readout, popover and right-click menu.
    public var showsMenuBar: Bool { self != .dock }
    /// A Dock icon all the time, not only while a window is open.
    public var showsDock: Bool { self != .menuBar }
    /// The live speeds on the Dock icon: when there's a Dock icon all the
    /// time and it's to show them (#523).
    public func drawsSpeedsOnDock(_ icon: DockIcon) -> Bool { showsDock && icon == .speeds }

    /// What the Dock icon shows until it's chosen: the speeds in Dock mode,
    /// where they're nowhere else, and the app's icon in Both, as it was
    /// before there was a choice (#523).
    public var defaultDockIcon: DockIcon { self == .dock ? .speeds : .appIcon }

    public var label: String {
        switch self {
        case .menuBar: return L("Menu bar")
        case .dock:    return L("Dock")
        case .both:    return L("Both")
        }
    }
}

/// What the Dock icon shows in Dock and Both modes (#523): **Settings ›
/// General › Dock icon**, a choice that's there only while one of them is
/// chosen. Each mode keeps its own.
public enum DockIcon: String, CaseIterable, Identifiable {
    /// The whole icon is the readout. Dock mode's default.
    case speeds
    /// The app's own icon, with no speeds. Both mode's default.
    case appIcon

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .speeds:  return L("Speeds")
        case .appIcon: return L("App icon")
        }
    }
}

/// How the Dock icon looks while it shows the speeds (#807): **Settings ›
/// General › Appearance**, there only while **Dock icon** is **Speeds**. One
/// choice for Dock and Both: it's how the icon looks, not what it shows.
public enum DockAppearance: String, CaseIterable, Identifiable {
    /// Follows the Mac's appearance, and changes when it does. The default,
    /// and how the icon always was.
    case system
    /// Light whatever the Mac is set to.
    case light
    /// Dark whatever the Mac is set to.
    case dark

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: return L("System")
        case .light:  return L("Light")
        case .dark:   return L("Dark")
        }
    }

    /// The appearance the icon is drawn in: none of its own with System, so
    /// it takes the app's, which follows the Mac's.
    public var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }

    /// Whether the icon is drawn dark, on a Mac in dark or in light.
    public func drawsDark(macIsDark: Bool) -> Bool {
        switch self {
        case .system: return macIsDark
        case .light:  return false
        case .dark:   return true
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

    /// Where each mode's Dock icon choice is kept.
    public static func dockIconKey(_ placement: AppPlacement) -> String {
        placement == .both ? "dockIconInBoth" : "dockIcon"
    }

    /// What the Dock icon shows in Dock mode, and in Both (#523). Each mode
    /// keeps its own, so choosing in one never changes the other. Saved only
    /// while it differs from that mode's default.
    @Published public var dockIconInDock: DockIcon {
        didSet { save(dockIconInDock, for: .dock) }
    }
    @Published public var dockIconInBoth: DockIcon {
        didSet { save(dockIconInBoth, for: .both) }
    }

    /// What the Dock icon shows in the chosen mode: the choice Settings
    /// shows and changes. In Menu bar mode, the app's icon.
    public var dockIcon: DockIcon {
        get { Self.dockIcon(for: placement, inDock: dockIconInDock, inBoth: dockIconInBoth) }
        set {
            switch placement {
            case .dock:    dockIconInDock = newValue
            case .both:    dockIconInBoth = newValue
            case .menuBar: break
            }
        }
    }

    public static func dockIcon(for placement: AppPlacement, inDock: DockIcon, inBoth: DockIcon) -> DockIcon {
        switch placement {
        case .dock:    return inDock
        case .both:    return inBoth
        case .menuBar: return .appIcon
        }
    }

    public static let dockAppearanceKey = "dockAppearance"

    /// How the Dock icon looks while it shows the speeds (#807), in Dock and
    /// Both alike. Saved only while it differs from System, the default.
    @Published public var dockAppearance: DockAppearance {
        didSet {
            guard dockAppearance != oldValue else { return }
            if dockAppearance == .system {
                defaults.removeObject(forKey: Self.dockAppearanceKey)
            } else {
                defaults.set(dockAppearance.rawValue, forKey: Self.dockAppearanceKey)
            }
        }
    }

    /// The speeds on the Dock icon, as the two choices make it.
    public var drawsSpeedsOnDock: Bool { placement.drawsSpeedsOnDock(dockIcon) }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        placement = defaults.string(forKey: Self.key).flatMap(AppPlacement.init) ?? .menuBar
        func stored(_ mode: AppPlacement) -> DockIcon {
            defaults.string(forKey: Self.dockIconKey(mode)).flatMap(DockIcon.init) ?? mode.defaultDockIcon
        }
        dockIconInDock = stored(.dock)
        dockIconInBoth = stored(.both)
        dockAppearance = defaults.string(forKey: Self.dockAppearanceKey).flatMap(DockAppearance.init) ?? .system
    }

    private func save(_ icon: DockIcon, for mode: AppPlacement) {
        if icon == mode.defaultDockIcon {
            defaults.removeObject(forKey: Self.dockIconKey(mode))
        } else {
            defaults.set(icon.rawValue, forKey: Self.dockIconKey(mode))
        }
    }
}

/// The readout's two lines and their colours: what the menu bar draws, and the
/// Dock icon when it shows the speeds (#69, #523).
public struct SpeedReadout: Equatable {
    public let down: String
    public let up: String
    public let tints: MenuBarTints
    /// Upload on the upper line: **Speed on top** (#772), in the menu bar
    /// and on the Dock icon.
    public let uploadFirst: Bool

    public init(down: String, up: String, tints: MenuBarTints, uploadFirst: Bool = false) {
        self.down = down
        self.up = up
        self.tints = tints
        self.uploadFirst = uploadFirst
    }
}


/// The Dock icon with **Dock icon: Speeds**, in Dock or Both mode (#523): the whole
/// icon is the readout, drawn like the app's own icon: its squircle and
/// lighting, near black in dark mode and near white in light, following the
/// Mac's appearance or kept light or dark by **Appearance** (#807). Each speed is an arrow like the icon's and its figure,
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

    /// Whether to draw for dark: the view's own appearance, set by
    /// **Appearance** to Light or Dark (#807), or with System none of its
    /// own, so the app's, which follows the Mac's.
    public var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    /// **Appearance** (#807): the icon kept light or dark, or following the
    /// Mac. Marked to be drawn again with the figures it has, even when
    /// they're unchanged (both speeds zero), so the Dock shows it at once.
    public var dockAppearance: DockAppearance = .system {
        didSet {
            appearance = dockAppearance.appearance
            needsDisplay = true
        }
    }

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
        // A speed test's colours chosen for light, when on light (#672).
        let given = dark ? readout.tints : MenuBarTints(down: readout.tints.onLight?.first ?? readout.tints.down,
                                                        up: readout.tints.onLight?.last ?? readout.tints.up)
        for line in layout.lines {
            let tint = MenuBarColors.readable(line.isDownload ? given.down : given.up, onDark: dark)
            context.setFillColor(tint.cgColor)
            context.addPath(Self.arrow(in: line.arrowFrame, pointingDown: line.isDownload))
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
        public let isDownload: Bool
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

    /// The figures as large as fit the squircle, across and down. The two
    /// rows are centred as a block, with every edge on a whole pixel.
    public static func layout(for readout: SpeedReadout, in bounds: NSRect,
                              pixelsPerPoint: CGFloat = 2) -> Layout {
        let box = squareRect(in: bounds).insetBy(dx: bounds.width * padding.width,
                                                 dy: bounds.height * padding.height)
        let download = (parts: split(readout.down), isDownload: true)
        let upload = (parts: split(readout.up), isDownload: false)
        let rows = readout.uploadFirst ? [upload, download] : [download, upload]
        func width(_ text: String, _ font: NSFont) -> CGFloat {
            NSAttributedString(string: text, attributes: [.font: font]).size().width
        }
        func snap(_ value: CGFloat) -> CGFloat { (value * pixelsPerPoint).rounded() / pixelsPerPoint }
        func rowWidth(_ font: NSFont) -> CGFloat {
            let figures = ([template] + rows.map { $0.parts.figure }).map { width($0, font) }.max() ?? 0
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
        let lines = rows.map { row -> Line in
            let part = row.parts
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
            return Line(isDownload: row.isDownload, figure: part.figure, unit: part.unit, arrowFrame: arrowFrame,
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
