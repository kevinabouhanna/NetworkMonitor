// Draws the disk image's window background: Resources/DMG/background.tiff.
//
// Run with `make dmg-background` after changing anything here. The .tiff is
// committed, so an ordinary `make dmg` never runs this.
//
// The window is 600 × 440 pt. The app icon sits centred at (150, 215) and the
// Applications alias at (450, 215), measured from the top left — the same
// numbers as `icon_locations` in Scripts/dmg-settings.py, which must move with
// them. Between the two is an arrow drawn like the icon's own down arrow: a
// straight shaft and a solid head, in the same green (#51FF70), outlined so it
// holds up on a light background.
//
// Light, not the icon's charcoal, because Finder draws the icon labels itself
// and draws them black over a background picture even in dark mode (seen on
// macOS 26), with no setting to change it. On charcoal they all but vanish.
//
// The caption sits at the top because the bottom is not reliably visible: a
// Finder set to always show the tab bar and status bar takes about 60 pt off
// the window, and that comes out of the bottom of the picture.
//
// Both a 1x and a 2x image are drawn and joined into one .tiff, which is how
// Finder picks the sharp one on a Retina display.

import AppKit

let width: CGFloat = 600
let height: CGFloat = 440
let green = NSColor(srgbRed: 0x51 / 255, green: 0xFF / 255, blue: 0x70 / 255, alpha: 1)
let greenEdge = NSColor(srgbRed: 0x24 / 255, green: 0xB2 / 255, blue: 0x44 / 255, alpha: 1)
let title = NSColor(srgbRed: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255, alpha: 1)
let subtitle = NSColor(srgbRed: 0x6E / 255, green: 0x6E / 255, blue: 0x73 / 255, alpha: 1)
let top = NSColor(srgbRed: 0xFB / 255, green: 0xFB / 255, blue: 0xFD / 255, alpha: 1)
let bottom = NSColor(srgbRed: 0xE8 / 255, green: 0xE8 / 255, blue: 0xED / 255, alpha: 1)

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    NSGradient(starting: top, ending: bottom)!
        .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

    // AppKit's origin is the bottom left; the layout above is from the top.
    // One outline for shaft and head together, so the stroke has no seam.
    let arrowY = height - 215
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 238, y: arrowY + 5))
    arrow.line(to: NSPoint(x: 336, y: arrowY + 5))
    arrow.line(to: NSPoint(x: 336, y: arrowY + 19))
    arrow.line(to: NSPoint(x: 364, y: arrowY))
    arrow.line(to: NSPoint(x: 336, y: arrowY - 19))
    arrow.line(to: NSPoint(x: 336, y: arrowY - 5))
    arrow.line(to: NSPoint(x: 238, y: arrowY - 5))
    arrow.close()
    arrow.lineJoinStyle = .round
    arrow.lineWidth = 1.5
    green.setFill()
    arrow.fill()
    greenEdge.setStroke()
    arrow.stroke()

    func centred(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, top y: CGFloat) {
        let line = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        let measured = line.size()
        line.draw(at: NSPoint(x: (width - measured.width) / 2, y: height - y - measured.height))
    }
    centred("Install NetworkMonitor", size: 20, weight: .semibold, color: title, top: 38)
    centred("Drag it into your Applications folder.", size: 13, weight: .regular,
            color: subtitle, top: 68)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let outDir = root.appendingPathComponent("Resources/DMG")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let tmp = FileManager.default.temporaryDirectory
let one = tmp.appendingPathComponent("dmg-background.png")
let two = tmp.appendingPathComponent("dmg-background@2x.png")
try render(scale: 1).write(to: one)
try render(scale: 2).write(to: two)

let tiffutil = Process()
tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiffutil.arguments = ["-cathidpicheck", one.path, two.path,
                      "-out", outDir.appendingPathComponent("background.tiff").path]
try tiffutil.run()
tiffutil.waitUntilExit()
guard tiffutil.terminationStatus == 0 else { fatalError("tiffutil failed") }
print("Wrote Resources/DMG/background.tiff")
