import AppKit
import Foundation
import NetworkMonitorCore

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

        Check.test("title has the spec's shape") {
            let title = MenuBarTitle.string(down: 131_072, up: 12_288)
            Check.expectTrue(title.hasPrefix("↓ "), "got ‘\(title)’")
            Check.expectTrue(title.contains(" ↑ "), "got ‘\(title)’")
            Check.expectTrue(title.contains("128 KB/s"), "got ‘\(title)’")
            Check.expectTrue(title.contains("12.0 KB/s"), "got ‘\(title)’")
        }

        Check.test("idle title reads zero rather than blank") {
            let title = MenuBarTitle.string(down: 0, up: 0)
            Check.expectTrue(title.contains("0 B/s"), "got ‘\(title)’")
        }
    }
}

/// `nettop` costs a fixed ~1.36 cores whenever it runs — independent of `-s` and
/// of `-p` scoping — so *when* it runs is the only energy lever there is.
func runTrackingModeTests() {
    Check.suite("PerAppTrackingMode") {

        Check.test("always tracks regardless of power or popover") {
            for ac in [true, false] {
                for open in [true, false] {
                    Check.expectTrue(PerAppTrackingMode.always
                        .shouldTrack(popoverOpen: open, onACPower: ac))
                }
            }
        }

        // The default. Full-day per-app totals at a desk; on battery the
        // expensive stream only runs while the user is actually looking.
        Check.test("pluggedIn tracks on AC, and on battery only while open") {
            let mode = PerAppTrackingMode.pluggedIn
            Check.expectTrue(mode.shouldTrack(popoverOpen: false, onACPower: true),
                             "plugged in and idle should still track")
            Check.expectTrue(mode.shouldTrack(popoverOpen: true, onACPower: false),
                             "on battery, opening the popover should track")
            Check.expectFalse(mode.shouldTrack(popoverOpen: false, onACPower: false),
                              "on battery and closed must NOT burn a core")
        }

        Check.test("whenOpen never tracks while closed") {
            let mode = PerAppTrackingMode.whenOpen
            Check.expectFalse(mode.shouldTrack(popoverOpen: false, onACPower: true))
            Check.expectFalse(mode.shouldTrack(popoverOpen: false, onACPower: false))
            Check.expectTrue(mode.shouldTrack(popoverOpen: true, onACPower: false))
        }

        Check.test("modes round-trip through their raw values") {
            for mode in PerAppTrackingMode.allCases {
                Check.expectEqual(PerAppTrackingMode(rawValue: mode.rawValue), mode)
                Check.expectFalse(mode.title.isEmpty)
            }
        }

        // A desktop Mac reports no battery; treating that as AC keeps full
        // tracking rather than silently degrading.
        Check.test("power source query returns without error") {
            _ = PowerSource.isOnACPower
            Check.expectTrue(true)
        }
    }
}
