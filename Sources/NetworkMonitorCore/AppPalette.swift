import AppKit
import SwiftUI

/// The app's colours, the same wherever a thing appears (#436): in the
/// popover's figures, the sidebar's icons, the charts, the bars and the map.
///
/// - Data used: blue. Usage History, the popover's Data.
/// - Connections: teal. Connections, the popover's Connections.
/// - Blocked: red. Ads and Trackers, the popover's Ads blocked.
/// - A hotspot: orange, wherever one is marked.
/// - The network itself, and Settings: no colour of their own.
///
/// Fixed colours rather than the accent colour, so the meaning doesn't move
/// with a setting; lighter in Dark Mode, so a figure stands out from the
/// dark glass behind it (at least 4.5:1 there, as text should be).
enum AppPalette {
    static let data = dynamic(light: 0x1A6BD8, dark: 0x5AA9FF)
    static let connections = dynamic(light: 0x0A8597, dark: 0x45D3E8)
    static let blocked = dynamic(light: 0xD3302C, dark: 0xFF6B66)
    static let hotspot = dynamic(light: 0xD9570F, dark: 0xFF9A3D)

    /// Blocked, mixed into the window's background: Ads and Trackers' bars
    /// that step back while another is read, and a bar's part that isn't the
    /// row chosen (#536). Mixed rather than translucent, as Usage History's,
    /// since a bar's top is drawn as two overlapping marks.
    static func blockedFaded(_ fade: CGFloat) -> Color { dynamic(light: 0xD3302C, dark: 0xFF6B66, fade: fade) }

    /// The same colours for AppKit.
    static func ns(_ color: Color) -> NSColor { NSColor(color) }

    static func dynamic(light: UInt32, dark: UInt32, fade: CGFloat = 0) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            let color = NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                                green: CGFloat((hex >> 8) & 0xFF) / 255,
                                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
            guard fade > 0 else { return color }
            return color.blended(withFraction: fade, of: .windowBackgroundColor) ?? color
        })
    }
}
