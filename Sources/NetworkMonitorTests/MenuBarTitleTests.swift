import AppKit
import Foundation
import NetworkMonitorCore

func runPowerProfileTests() {
    Check.suite("PowerProfile") {

        Check.test("the power source alone picks the profile") {
            Check.expectEqual(PowerProfile.forPowerSource(onACPower: true), .performance)
            Check.expectEqual(PowerProfile.forPowerSource(onACPower: false), .balanced)
        }

        // The whole point of the profile: on battery it samples less often, never
        // less completely. Both figures stay exact because interface counters are
        // read by difference and nettop reports a delta per sample.
        Check.test("balanced samples less often than performance") {
            let ac = PowerProfile.performance, battery = PowerProfile.balanced
            Check.expectTrue(battery.interfaceInterval(displayAsleep: false)
                             > ac.interfaceInterval(displayAsleep: false),
                             "battery must read the counters less often")
            Check.expectTrue(battery.nettopSampleInterval > ac.nettopSampleInterval,
                             "battery must sample nettop less often")
        }

        // Relaxed again with the screen off, in both profiles: totals keep
        // accumulating, but nobody is reading a menu bar they cannot see.
        Check.test("a sleeping display relaxes the sampler further") {
            for profile in PowerProfile.allCases {
                Check.expectTrue(profile.interfaceInterval(displayAsleep: true)
                                 > profile.interfaceInterval(displayAsleep: false),
                                 "\(profile.rawValue) should relax when the screen sleeps")
            }
        }

        // nettop's interval is a whole number of seconds, its own minimum, and a
        // restart-costing change — so it must never be varied by screen state.
        Check.test("nettop intervals are whole seconds of at least one") {
            for profile in PowerProfile.allCases {
                Check.expectTrue(profile.nettopSampleInterval >= 1,
                                 "\(profile.rawValue) asked for a sub-second nettop")
            }
        }

        // Otherwise the "active now" dot blinks off between samples on an app that
        // never stopped transferring.
        Check.test("the activity window covers the gap between samples") {
            for profile in PowerProfile.allCases {
                Check.expectTrue(profile.activityWindow
                                 >= TimeInterval(profile.nettopSampleInterval) * 2,
                                 "\(profile.rawValue) would blink the active dot")
            }
        }

        // No stored preference, no migration, nothing to get out of step: the
        // profile is derived, and this is what keeps it that way.
        Check.test("the profile is derived, never persisted") {
            let key = "powerProfile"
            UserDefaults.standard.removeObject(forKey: key)
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("profile-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }
            let model = MonitorViewModel(store: UsageStore(storeURL: url))
            Check.expectEqual(model.profile,
                              PowerProfile.forPowerSource(onACPower: PowerSource.isOnACPower),
                              "the model must adopt the live power source")
            Check.expectNil(UserDefaults.standard.object(forKey: key),
                            "the profile must not be written to defaults")
        }
    }
}

func runMenuBarTitleTests() {
    // Every case the status item will realistically display, spanning all units.
    let cases: [(down: Double, up: Double, label: String)] = [
        (0, 0, "idle"),
        (1, 1, "1 B/s"),
        (512, 64, "bytes"),
        (131_072, 12_288, "spec example 128 KB/s ↑ 12 KB/s"),
        (1_048_576, 524_288, "1 MB/s"),
        (10_485_760, 1_048_576, "10 MB/s"),
        (117_440_512, 8_388_608, "gigabit"),
        (1_073_741_824, 104_857_600, "1 GB/s"),
        (0, 1_073_741_824, "upload only"),
    ]

    // `MonitorViewModel` publishes a new rate only when these strings change, so
    // what counts as "the same title" is a correctness contract, not cosmetics:
    // too loose and the menu bar freezes, too tight and an idle machine re-lays out
    // the popover twice a second for nothing.
    Check.suite("MenuBarTitle — the redraw key") {

        // The idle case, and the reason the optimisation is worth anything: a Mac
        // doing nothing renders the identical title on every single tick.
        Check.test("an idle machine renders one unchanging title") {
            let a = MenuBarTitle.string(down: 0, up: 0)
            let b = MenuBarTitle.string(down: 0, up: 0)
            Check.expectEqual(a, b)
            // Sub-1 B/s is sampler noise and formats to "0 B/s", so a trickle of
            // stray bytes must not start repainting the menu bar either.
            Check.expectEqual(MenuBarTitle.string(down: 0.4, up: 0.9), a,
                              "sub-1 B/s noise must not count as a change")
        }

        // Rates that round to the same displayed figure are the same title: the
        // image is a pure function of these two lines.
        Check.test("rates that display identically share a title") {
            Check.expectEqual(MenuBarTitle.string(down: 1_048_576, up: 0),
                              MenuBarTitle.string(down: 1_048_580, up: 0),
                              "1.0 MB/s either way")
        }

        // And the converse, or the menu bar would stop updating.
        Check.test("a visible change is a different title") {
            let quiet = MenuBarTitle.string(down: 0, up: 0)
            for rate in [1.0, 1500.0, 2_500_000.0] {
                Check.expectFalse(MenuBarTitle.string(down: rate, up: 0) == quiet,
                                  "\(rate) B/s should differ from idle")
            }
            Check.expectFalse(MenuBarTitle.string(down: 1500, up: 0)
                              == MenuBarTitle.string(down: 1500, up: 2500),
                              "the upload line must count too")
        }
    }

    Check.suite("MenuBarTitle — width stability") {

        // The invariant that actually matters. An earlier version padded only
        // the digits and used `monospacedDigitSystemFont`; that rendered these
        // same cases at 7 different widths spanning 97.19–125.67 pt, so the menu
        // bar shifted every time traffic crossed a unit boundary. Character
        // counts alone do not catch it — this must measure real glyph metrics.
        Check.test("every rate renders at an identical pixel width") {
            let widths = cases.map { MenuBarTitle.renderedWidth(down: $0.down, up: $0.up) }
            let rounded = Set(widths.map { ($0 * 100).rounded() })
            Check.expectEqual(rounded.count, 1,
                              "expected one width, got "
                              + "\(rounded.sorted().map { $0 / 100 })")
        }

        // Guards the font choice specifically: monospacedDigitSystemFont would
        // pass a character-count test and fail this one.
        Check.test("the title font is fully monospaced, not monospaced-digit") {
            let font = MenuBarTitle.font
            let digit = NSAttributedString(string: "0", attributes: [.font: font]).size().width
            let space = NSAttributedString(string: " ", attributes: [.font: font]).size().width
            let letter = NSAttributedString(string: "B", attributes: [.font: font]).size().width
            Check.expectEqual(Double((digit * 100).rounded()), Double((space * 100).rounded()),
                              "space must match digit advance")
            Check.expectEqual(Double((digit * 100).rounded()), Double((letter * 100).rounded()),
                              "letter must match digit advance")
        }

        // Right alignment discards trailing whitespace during layout, which
        // silently undoes the unit-field padding and shifts the glyphs by a
        // character even though the measured width stays constant.
        Check.test("alignment is left so trailing pad is not discarded") {
            let attributed = MenuBarTitle.attributed(down: 0, up: 0)
            let style = attributed.attribute(.paragraphStyle, at: 0,
                                             effectiveRange: nil) as? NSParagraphStyle
            Check.expectNotNil(style)
            Check.expectTrue(style?.alignment == .left,
                             "got \(String(describing: style?.alignment))")
        }

        // The padding only survives if it is actually present in the string.
        Check.test("short units are trailing-padded") {
            Check.expectTrue(ByteFormat.menuBarRate(0).hasSuffix("B/s "),
                             "‘\(ByteFormat.menuBarRate(0))’ should end in a pad space")
            Check.expectTrue(ByteFormat.menuBarRate(131_072).hasSuffix("KB/s"),
                             "4-char units need no pad")
        }

        Check.test("renders as two stacked lines, download first") {
            let title = MenuBarTitle.string(down: 14.14 * 1024, up: 28.69 * 1024)
            let lines = title.components(separatedBy: "\n")
            Check.expectEqual(lines.count, 2, "got ‘\(title)’")
            Check.expectTrue(lines[0].hasPrefix("↓"), "first line must be download")
            Check.expectTrue(lines[1].hasPrefix("↑"), "second line must be upload")
            Check.expectTrue(lines[0].contains("14.14 KB/s"), "got ‘\(lines[0])’")
            Check.expectTrue(lines[1].contains("28.69 KB/s"), "got ‘\(lines[1])’")
        }

        /// The stacked pair has to fit the 22 pt menu bar. At 9 pt it measured
        /// exactly 22.0 and the top line's ascenders were clipped once the
        /// button's insets applied, so there must be real margin.
        Check.test("two lines fit inside the menu bar height") {
            for (down, up, _) in cases {
                let height = MenuBarTitle.renderedHeight(down: down, up: up)
                Check.expectTrue(height < Double(MenuBarTitle.menuBarHeight),
                                 "two-line height \(height) must be under "
                                 + "\(MenuBarTitle.menuBarHeight) pt")
            }
        }

        /// The status item shows an image, not a title, because NSButton drew a
        /// multi-line title outside its own bounds. The image must be exactly the
        /// menu bar height and keep its colour.
        Check.test("status item image is menu-bar sized and not a template") {
            let image = MenuBarTitle.image(down: 14.14 * 1024, up: 28.69 * 1024)
            Check.expectEqual(Double(image.size.height),
                              Double(MenuBarTitle.menuBarHeight),
                              "image must fill the bar height exactly")
            Check.expectTrue(image.size.width > 0, "image has no width")
            // A template image would be recoloured to the monochrome bar tint,
            // discarding the green.
            Check.expectFalse(image.isTemplate, "template would lose the tint")
        }

        Check.test("image width is identical for every rate") {
            let widths = Set(cases.map {
                (MenuBarTitle.image(down: $0.down, up: $0.up).size.width * 100).rounded()
            })
            Check.expectEqual(widths.count, 1,
                              "expected one width, got \(widths.sorted().map { $0 / 100 })")
        }

        /// The two lines carry different colours, so the attributed string must
        /// have two distinct foreground runs rather than one uniform tint.
        Check.test("download and upload lines are tinted separately") {
            let attributed = MenuBarTitle.attributed(down: 1024, up: 1024)
            let text = attributed.string
            let newline = text.distance(from: text.startIndex,
                                        to: text.firstIndex(of: "\n")!)

            let downColour = attributed.attribute(.foregroundColor, at: 0,
                                                  effectiveRange: nil) as? NSColor
            let upColour = attributed.attribute(.foregroundColor, at: newline + 1,
                                                effectiveRange: nil) as? NSColor
            Check.expectTrue(downColour == MenuBarTitle.downTint, "download tint")
            Check.expectTrue(upColour == MenuBarTitle.upTint, "upload tint")
            Check.expectFalse(downColour == upColour, "the two lines must differ")
        }

        /// The exact values requested: #51FF70 download, #E5E5E5 upload.
        Check.test("tints are the specified sRGB values") {
            func hex(_ colour: NSColor) -> String {
                let c = colour.usingColorSpace(.sRGB) ?? colour
                return String(format: "#%02X%02X%02X",
                              Int((c.redComponent * 255).rounded()),
                              Int((c.greenComponent * 255).rounded()),
                              Int((c.blueComponent * 255).rounded()))
            }
            Check.expectEqual(hex(MenuBarTitle.downTint), "#51FF70")
            Check.expectEqual(hex(MenuBarTitle.upTint), "#E5E5E5")
        }
    }
}

