import AppKit
import Combine

/// Where NetworkMonitor shows (#69): **Settings › General › Show NetworkMonitor
/// in**. Never neither, as Kevin asked: with no status item and no Dock icon
/// there'd be no way back to the app.
public enum AppPlacement: String, CaseIterable, Identifiable {
    /// The readout in the menu bar, and a Dock icon only while a window is
    /// open. The default, and how the app always was.
    case menuBar
    /// Nothing in the menu bar: a Dock icon all the time, with the live speeds
    /// drawn on it.
    case dock
    /// The readout in the menu bar, and a Dock icon all the time.
    case both

    public var id: String { rawValue }

    /// The status item, with its readout, popover and right-click menu.
    public var showsMenuBar: Bool { self != .dock }
    /// A Dock icon all the time, not only while a window is open.
    public var showsDock: Bool { self != .menuBar }
    /// The live speeds on the Dock icon: only when they aren't in the menu bar.
    public var drawsSpeedsOnDock: Bool { self == .dock }

    public var label: String {
        switch self {
        case .menuBar: return L("Menu bar")
        case .dock:    return L("Dock")
        case .both:    return L("Both")
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

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        placement = defaults.string(forKey: Self.key).flatMap(AppPlacement.init) ?? .menuBar
    }
}

/// The readout's two lines and their colours: what the menu bar draws, and the
/// Dock icon in Dock mode (#69).
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

/// The Dock icon in Dock mode (#69): the app's icon with the live speeds on a
/// dark band across its lower half, download over upload, in the menu bar's
/// colours, which are made to read on dark.
///
/// The Dock draws a tile's content view only when told to
/// (`NSDockTile.display()`), so this costs nothing between readings; see
/// `AppDelegate.drawDockReadout()` for how often that is.
public final class DockSpeedView: NSView {
    public var readout: SpeedReadout? {
        didSet { if readout != oldValue { needsDisplay = true } }
    }

    /// The icon's rounded square, as a fraction of the tile on each side
    /// (100 of 1,024 px, as macOS draws every app icon).
    static let iconInset: CGFloat = 100 / 1024
    /// The band's height, as a fraction of the tile.
    static let bandHeight: CGFloat = 0.42
    /// Space between the text and the band's sides, as a fraction of the tile.
    static let textPadding: CGFloat = 0.04

    public override init(frame: NSRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        guard let readout, let context = NSGraphicsContext.current else { return }
        // Painted only where the icon is, so the band takes the rounded
        // square's own corners.
        context.saveGraphicsState()
        context.compositingOperation = .sourceAtop
        NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1).setFill()
        Self.bandRect(in: bounds).fill()
        context.restoreGraphicsState()

        let band = Self.bandRect(in: bounds)
        let font = Self.font(for: readout, in: bounds)
        let down = NSAttributedString(string: Self.spaced(readout.down),
                                      attributes: [.font: font, .foregroundColor: readout.tints.down])
        let up = NSAttributedString(string: Self.spaced(readout.up),
                                    attributes: [.font: font, .foregroundColor: readout.tints.up])
        // Each line's box from its lower-left corner (the view isn't
        // flipped): download just above the band's middle, upload just below.
        // From a fixed left edge, so the figures never shift as they change.
        let lineHeight = down.size().height
        let x = band.midX - Self.templateWidth(font) / 2
        down.draw(at: NSPoint(x: x, y: band.midY))
        up.draw(at: NSPoint(x: x, y: band.midY - lineHeight))
    }

    /// Where the band goes on a tile of `bounds`: the lower part of the
    /// icon's rounded square.
    static func bandRect(in bounds: NSRect) -> NSRect {
        let inset = bounds.width * iconInset
        return NSRect(x: bounds.minX + inset, y: bounds.minY + bounds.height * iconInset,
                      width: bounds.width - 2 * inset, height: bounds.height * bandHeight)
    }

    /// The readout pads its figures with spaces to one width in a
    /// monospaced font. Here, in a narrower one with figures of one width,
    /// figure spaces keep that padding the width of a digit.
    static func spaced(_ line: String) -> String {
        line.replacingOccurrences(of: " ", with: "\u{2007}")
    }

    /// Condensed, bold and with figures of one width: the most legible way to
    /// get eleven characters across a Dock icon.
    static func font(ofSize size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .bold, width: .condensed)
        let tabular = base.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
        ]]])
        return NSFont(descriptor: tabular, size: size) ?? base
    }

    /// The widest line there can be, so the size and the left edge stay put
    /// whatever the figures.
    static let templates = ["↓ 88888 MB/s", "↑ 88888 MB/s"]

    static func templateWidth(_ font: NSFont) -> CGFloat {
        templates.map { NSAttributedString(string: spaced($0), attributes: [.font: font]).size().width }.max() ?? 0
    }

    /// The largest size both lines fit the band at, across and down.
    public static func font(for readout: SpeedReadout, in bounds: NSRect) -> NSFont {
        let band = bandRect(in: bounds)
        let pad = bounds.width * textPadding
        let reference: CGFloat = 20
        let measuring = font(ofSize: reference)
        let widest = ([readout.down, readout.up] + templates)
            .map { NSAttributedString(string: spaced($0), attributes: [.font: measuring]).size().width }
            .max() ?? 1
        let lineHeight = NSAttributedString(string: readout.down, attributes: [.font: measuring]).size().height
        let across = (band.width - 2 * pad) / max(widest, 1)
        let down = (band.height - pad) / (2 * lineHeight)
        return font(ofSize: floor(reference * min(across, down) * 10) / 10)
    }
}
