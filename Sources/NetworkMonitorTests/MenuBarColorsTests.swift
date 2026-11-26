import AppKit
import Foundation
import NetworkMonitorCore

func runMenuBarColorsTests() {
    Check.suite("MenuBarColors") {

        func hex(_ value: String) -> NSColor { MenuBarColors.color(hex: value)! }
        func freshDefaults() -> UserDefaults {
            Check.defaults("menu-bar-colors")
        }

        // Nobody who keeps the defaults should see anything new, the test's
        // cyan included.
        Check.test("with the default colours, the readout and the test look as before") {
            let colors = MenuBarColors(defaults: freshDefaults())
            Check.expectEqual(MenuBarColors.hex(colors.download), "#51FF70")
            Check.expectEqual(MenuBarColors.hex(colors.upload), "#E5E5E5")
            Check.expectEqual(MenuBarColors.hex(colors.test.down), "#64D2FF")
            Check.expectEqual(MenuBarColors.hex(colors.test.up), "#B4E9FF")
            Check.expectTrue(colors.isDefault)
        }

        // The issue's one condition (#45): picking the test's own cyan for the
        // live rates must not make a test look like live rates.
        Check.test("a live colour too close to the test's moves the test to other colours") {
            let colors = MenuBarColors(defaults: freshDefaults())
            colors.download = hex("#64D2FF")
            Check.expectFalse(colors.test == MenuBarTints.testChoices[0], "still cyan")
            for live in [colors.download, colors.upload] {
                Check.expectTrue(MenuBarColors.distance(colors.test.down, live) >= MenuBarTints.clearDown)
                Check.expectTrue(MenuBarColors.distance(colors.test.up, live) >= MenuBarTints.clearUp)
            }
        }

        Check.test("the upload colour counts too") {
            let test = MenuBarTints.test(clearOf: MenuBarTints(down: hex("#51FF70"), up: hex("#64D2FF")))
            Check.expectFalse(test == MenuBarTints.testChoices[0],
                              "a cyan test download would match the live upload line")
        }

        // Whatever two colours someone picks, the download line changes plainly
        // when a test takes over. The odd pair that blocks every choice gets
        // the nearest, which falls short of the line by less than 0.005.
        Check.test("whatever the colours, a test's download line looks different") {
            var palette = [hex("#000000"), hex("#808080"), hex("#E5E5E5"), hex("#FFFFFF")]
            for hue in stride(from: 0.0, to: 1.0, by: 1.0 / 18) {
                for (saturation, brightness) in [(1.0, 1.0), (0.5, 1.0), (1.0, 0.6), (0.3, 0.9)] {
                    palette.append(MenuBarColors.normalized(
                        NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)))
                }
            }
            var worst = Double.infinity
            for down in palette {
                for up in palette {
                    let test = MenuBarTints.test(clearOf: MenuBarTints(down: down, up: up))
                    worst = min(worst, MenuBarColors.distance(test.down, down),
                                MenuBarColors.distance(test.down, up))
                }
            }
            Check.expectTrue(worst >= MenuBarTints.clearDown - 0.005, "closest was \(worst)")
        }

        // Saved only while it differs from the default, so a future default
        // reaches everyone who never picked one.
        Check.test("a picked colour is kept, and putting the defaults back forgets it") {
            let defaults = freshDefaults()
            let colors = MenuBarColors(defaults: defaults)
            colors.upload = hex("#FF9500")
            Check.expectEqual(defaults.string(forKey: "menuBarUploadColor"), "#FF9500")
            Check.expectNil(defaults.string(forKey: "menuBarDownloadColor"))
            Check.expectEqual(MenuBarColors.hex(MenuBarColors(defaults: defaults).upload), "#FF9500",
                              "a relaunch keeps it")
            Check.expectFalse(colors.isDefault)

            colors.reset()
            Check.expectNil(defaults.string(forKey: "menuBarUploadColor"))
            Check.expectTrue(colors.isDefault)
        }

        Check.test("a change redraws the menu bar") {
            let colors = MenuBarColors(defaults: freshDefaults())
            var redraws = 0
            colors.didChange = { redraws += 1 }
            colors.download = hex("#FF3B30")
            Check.expectEqual(redraws, 1)
        }

        Check.test("the menu bar row order is saved separately from the colours and redraws immediately") {
            let defaults = freshDefaults()
            let colors = MenuBarColors(defaults: defaults)
            colors.upload = hex("#FF9500")
            let live = colors.live
            let test = colors.test
            var drawnOrders: [Bool] = []
            colors.didChange = { [weak colors] in
                if let colors { drawnOrders.append(colors.uploadFirst) }
            }

            Check.expectFalse(colors.uploadFirst)
            colors.uploadFirst = true
            Check.expectEqual(drawnOrders, [true])
            Check.expectEqual(colors.live, live)
            Check.expectEqual(colors.test, test)
            let reopened = MenuBarColors(defaults: defaults)
            Check.expectTrue(reopened.uploadFirst)
            Check.expectEqual(reopened.live, live)

            colors.uploadFirst = false
            Check.expectEqual(drawnOrders, [true, false])
            Check.expectFalse(MenuBarColors(defaults: defaults).uploadFirst)
        }

        Check.test("upload first moves each value, arrow and colour together at the same size") {
            for unit in SpeedUnit.allCases {
                let live = SpeedReadout(down: MenuBarTitle.downLine(128 * 1024, unit: unit),
                                        up: MenuBarTitle.upLine(16 * 1024, unit: unit), tints: .live)
                let test = SpeedReadout(down: "↓ \(ByteFormat.menuBarSpeed(75_000_000, unit: unit))",
                                        up: "↑ \(ByteFormat.menuBarSpeed(6_000_000, unit: unit))",
                                        tints: MenuBarTints.testChoices[0])
                for readout in [live, test] {
                    let reversed = MenuBarTitle.attributed(readout, uploadFirst: true)
                    Check.expectEqual(reversed.string, readout.up + "\n" + readout.down)
                    Check.expectTrue(reversed.attribute(.foregroundColor, at: 0, effectiveRange: nil)
                                     as? NSColor == readout.tints.up)
                    Check.expectTrue(reversed.attribute(.foregroundColor, at: readout.up.utf16.count + 1,
                                                         effectiveRange: nil) as? NSColor == readout.tints.down)
                    let normalSize = MenuBarTitle.image(readout).size
                    Check.expectEqual(MenuBarTitle.image(readout, uploadFirst: true).size, normalSize)
                }
            }
        }

        Check.test("VoiceOver reads the rates in the order Speed on top sets") {
            let defaults = freshDefaults()
            let colors = MenuBarColors(defaults: defaults)
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("row-order-\(UUID()).json")
            let model = MonitorViewModel(store: UsageStore(storeURL: url), menuBarColors: colors)
            let normal = model.menuBarSpoken
            colors.uploadFirst = true
            let rate = ByteFormat.spokenSpeed(0, unit: model.speedTest.unit)
            Check.expectEqual(model.menuBarSpoken, L("Upload %@, download %@", rate, rate))
            Check.expectTrue(model.menuBarSpoken != normal)
        }

        // The colour panel hands back colours in whatever space it likes.
        Check.test("a colour from any colour space is saved as sRGB") {
            let p3 = NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1)
            let saved = MenuBarColors.hex(p3)
            Check.expectEqual(saved, "#FF0000", "out of gamut is clamped")
            Check.expectEqual(MenuBarColors.hex(MenuBarColors.normalized(hex("#12AB34"))), "#12AB34")
            Check.expectNil(MenuBarColors.color(hex: "red"))
            Check.expectNil(MenuBarColors.color(hex: "#12345"))
        }

        Check.test("the readout is drawn in the colours it's given") {
            let tints = MenuBarTints(down: hex("#FF3B30"), up: hex("#0A84FF"))
            let attributed = MenuBarTitle.attributed(down: 1024, up: 1024, tints: tints)
            let newline = attributed.string.distance(from: attributed.string.startIndex,
                                                     to: attributed.string.firstIndex(of: "\n")!)
            Check.expectTrue(attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil)
                             as? NSColor == tints.down)
            Check.expectTrue(attributed.attribute(.foregroundColor, at: newline + 1, effectiveRange: nil)
                             as? NSColor == tints.up)
        }

        Check.test("distance runs from 0 for the same colour to 1 for black to white") {
            Check.expectEqual(MenuBarColors.distance(hex("#51FF70"), hex("#51FF70")), 0)
            let blackToWhite = MenuBarColors.distance(hex("#000000"), hex("#FFFFFF"))
            Check.expectTrue(abs(blackToWhite - 1) < 0.001, "got \(blackToWhite)")
        }
    }

    Check.suite("MenuBarColors — on a light menu bar (#672)") {
        func hex(_ value: String) -> NSColor { MenuBarColors.color(hex: value)! }
        /// WCAG's contrast ratio, from 1 to 21.
        func contrast(_ a: NSColor, _ b: NSColor) -> Double {
            func luminance(_ color: NSColor) -> Double {
                let c = color.usingColorSpace(.sRGB)!
                func linear(_ x: CGFloat) -> Double {
                    let x = Double(x)
                    return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
                }
                return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent)
                    + 0.0722 * linear(c.blueComponent)
            }
            let (x, y) = (luminance(a), luminance(b))
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        func hue(_ color: NSColor) -> Double {
            let (_, a, b) = MenuBarColors.oklab(color)
            return atan2(b, a)
        }
        func chroma(_ color: NSColor) -> Double {
            let (_, a, b) = MenuBarColors.oklab(color)
            return (a * a + b * b).squareRoot()
        }
        let white = hex("#FFFFFF"), lightGrey = hex("#C8C8C8")
        /// Every colour the readout takes: its own, Block Everything's, each
        /// speed test pair's, and a sample of the wheel for colours picked.
        let everyTint: [(String, NSColor)] = {
            let pairs = [MenuBarTints.live, .blockingEverything] + MenuBarTints.testChoices
            var named = pairs.enumerated().flatMap { [("pair \($0.offset) ↓", $0.element.down),
                                                      ("pair \($0.offset) ↑", $0.element.up)] }
            for hue in stride(from: 0.0, to: 1.0, by: 1.0 / 36) {
                for (saturation, brightness) in [(1.0, 1.0), (0.4, 1.0), (1.0, 0.6), (0.15, 0.9)] {
                    let color = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
                        .usingColorSpace(.sRGB)!
                    named.append(("picked \(MenuBarColors.hex(color))", color))
                }
            }
            return named
        }()

        Check.test("each line reads on a light bar: 4.5 : 1 on white, 3 : 1 on light grey") {
            let light = MenuBarTints.live.onBar(dark: false)
            for (line, color) in [("↓", light.down), ("↑", light.up)] {
                Check.expectTrue(contrast(color, white) >= 4.5, "\(line) \(MenuBarColors.hex(color)) on white")
                Check.expectTrue(contrast(color, lightGrey) >= 3, "\(line) \(MenuBarColors.hex(color)) on #C8C8C8")
            }
            // Where it was: about 1.3 : 1.
            Check.expectTrue(contrast(MenuBarTints.live.down, white) < 1.5)
        }

        Check.test("on a dark bar the default colours are exactly as today") {
            let dark = MenuBarTints.live.onBar(dark: true)
            Check.expectEqual(MenuBarColors.hex(dark.down), "#51FF70")
            Check.expectEqual(MenuBarColors.hex(dark.up), "#E5E5E5")
        }

        Check.test("every colour the readout takes keeps its hue and reads on a light bar") {
            for (name, color) in everyTint {
                let light = MenuBarTints(down: color, up: color).onBar(dark: false).down
                Check.expectTrue(contrast(light, white) >= 4.5, "\(name) → \(MenuBarColors.hex(light)) on white")
                Check.expectTrue(contrast(light, lightGrey) >= 3, "\(name) → \(MenuBarColors.hex(light)) on #C8C8C8")
                // A grey has no hue to keep.
                guard chroma(color) > 0.03, chroma(light) > 0.01 else { continue }
                var turn = abs(hue(light) - hue(color))
                if turn > .pi { turn = 2 * .pi - turn }
                Check.expectTrue(turn < 0.05, "\(name) → \(MenuBarColors.hex(light)) turned \(turn) rad")
            }
        }

        // Darkened to one lightness, colours come closer: a test's must still
        // look unlike the live rates there (#45).
        Check.test("on a light bar, a speed test's colours stay clear of the live ones") {
            // The defaults and the test's own cyan clear it in full; a live
            // pink leaves no choice that does, and gets the nearest, as on dark.
            for (live, least) in [(MenuBarTints.live, MenuBarTints.clearDown),
                                  (MenuBarTints(down: hex("#64D2FF"), up: hex("#B4E9FF")), MenuBarTints.clearDown),
                                  (MenuBarTints(down: hex("#FF6FD8"), up: hex("#FFC2EF")), 0.12)] {
                let test = MenuBarTints.test(clearOf: live).onBar(dark: false)
                let lightLive = live.onBar(dark: false)
                let down = [lightLive.down, lightLive.up].map { MenuBarColors.distance(test.down, $0) }.min()!
                let up = [lightLive.down, lightLive.up].map { MenuBarColors.distance(test.up, $0) }.min()!
                Check.expectTrue(down >= least, "\(MenuBarColors.hex(live.down)): ↓ \(down)")
                Check.expectTrue(up >= MenuBarTints.clearUp, "\(MenuBarColors.hex(live.down)): ↑ \(up)")
                // Before #672's fix, the default test was 0.076 from the live green here.
            }
            // On a dark bar the default test is still cyan.
            Check.expectEqual(MenuBarColors.hex(MenuBarTints.test(clearOf: .live).down), "#64D2FF")
        }

        // Drawn as shown, so it follows the bar when the wallpaper changes.
        Check.test("the same readout draws in other colours under the light and the dark appearance") {
            let image = MenuBarTitle.image(down: 1_234_567, up: 4_321)
            func greenest(_ name: NSAppearance.Name) -> (r: Int, g: Int, b: Int)? {
                guard let appearance = NSAppearance(named: name),
                      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width) * 2,
                                                    pixelsHigh: Int(image.size.height) * 2, bitsPerSample: 8,
                                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                else { return nil }
                bitmap.size = image.size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                appearance.performAsCurrentDrawingAppearance {
                    image.draw(in: NSRect(origin: .zero, size: image.size))
                }
                NSGraphicsContext.restoreGraphicsState()
                // The most opaque pixel that's greener than it is red: the
                // download line's ink.
                var best: (r: Int, g: Int, b: Int, a: Int)?
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9,
                              c.greenComponent > c.redComponent + 0.15 else { continue }
                        let a = Int(c.alphaComponent * 255)
                        if a > (best?.a ?? 0) {
                            best = (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255), a)
                        }
                    }
                }
                return best.map { ($0.r, $0.g, $0.b) }
            }
            guard let onLight = greenest(.aqua), let onDark = greenest(.darkAqua) else {
                return Check.expectTrue(false, "no green drawn")
            }
            Check.expectTrue(onDark.g > 200, "on dark, the bright green: \(onDark)")
            Check.expectTrue(onLight.g < 140, "on light, a deep green: \(onLight)")
        }

        // Ready-made pairs (#688): each reads on either bar.
        Check.test("every ready-made pair reads on a dark bar and, darkened, on a light one") {
            let darkBar = hex("#1E1E1E")
            Check.expectEqual(MenuBarColors.presets.count, 6)
            for preset in MenuBarColors.presets {
                let light = preset.tints.onBar(dark: false)
                for (line, color, onLight) in [("↓", preset.tints.down, light.down), ("↑", preset.tints.up, light.up)] {
                    Check.expectTrue(contrast(color, darkBar) >= 4.5, "\(preset.id) \(line) on a dark bar")
                    Check.expectTrue(contrast(onLight, white) >= 4.5, "\(preset.id) \(line) on white")
                    Check.expectTrue(contrast(onLight, lightGrey) >= 3, "\(preset.id) \(line) on #C8C8C8")
                }
                // Its two lines still tell apart.
                Check.expectTrue(MenuBarColors.distance(preset.tints.down, preset.tints.up) > 0.1, preset.id)
                // And Block Everything's red still stands out against it (#198).
                let red = MenuBarTints.blockingEverything
                Check.expectTrue(MenuBarColors.distance(preset.tints.down, red.down) >= MenuBarTints.clearDown,
                                 "\(preset.id) ↓ beside Block Everything's red")
                Check.expectTrue(MenuBarColors.distance(preset.tints.up, red.up) >= MenuBarTints.clearUp,
                                 "\(preset.id) ↑ beside Block Everything's red")
            }
        }
    }

    Check.suite("MenuBarColors — ready-made pairs (#688)") {
        func hex(_ value: String) -> NSColor { MenuBarColors.color(hex: value)! }

        Check.test("the default colors are the first pair, Green") {
            let colors = MenuBarColors(defaults: Check.defaults("presets-688-default"))
            Check.expectEqual(colors.preset?.id, "green")
            Check.expectEqual(MenuBarColors.presets.first?.tints, MenuBarTints.live)
        }

        Check.test("choosing a pair changes the colors at once, and keeps them") {
            let defaults = Check.defaults("presets-688-choose")
            let colors = MenuBarColors(defaults: defaults)
            var redraws = 0
            colors.didChange = { redraws += 1 }
            let teal = MenuBarColors.presets.first { $0.id == "teal" }!
            colors.choose(teal)
            Check.expectEqual(colors.preset?.id, "teal")
            Check.expectEqual(redraws, 1, "the menu bar redrawn once, never with half a pair")
            Check.expectEqual(MenuBarColors(defaults: defaults).preset?.id, "teal", "kept")
            colors.choose(MenuBarColors.presets[0])
            Check.expectTrue(colors.isDefault, "Green is the default, saved as nothing")
        }

        Check.test("colors chosen before stay as they were, as one's own") {
            let defaults = Check.defaults("presets-688-own")
            let colors = MenuBarColors(defaults: defaults)
            colors.download = hex("#FF3B30")
            colors.upload = hex("#0A84FF")
            let reopened = MenuBarColors(defaults: defaults)
            Check.expectNil(reopened.preset)
            Check.expectEqual(MenuBarColors.hex(reopened.download), "#FF3B30")
            Check.expectEqual(MenuBarColors.hex(reopened.upload), "#0A84FF")
        }
    }
}
