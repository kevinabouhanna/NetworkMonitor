import Foundation
import NetworkMonitorCore

/// The popover derives its height from the row count rather than measuring the
/// laid-out content, so these constants are the only thing keeping the window
/// the right size. They were calibrated against what SwiftUI actually lays out;
/// if a row's padding changes, one of these fails and points at the reason.
func runPopoverMetricsTests() {
    Check.suite("PopoverMetrics — height derived from the row count") {

        let padding = PopoverMetrics.listVerticalPadding

        Check.test("an empty list is just its padding") {
            Check.expectEqual(
                PopoverMetrics.contentHeight(appRows: 0, expandedChildRows: 0,
                                          systemRowCount: 0, systemExpanded: false),
                padding)
        }

        Check.test("each app row adds one row height") {
            for n in 1...5 {
                Check.expectEqual(
                    PopoverMetrics.contentHeight(appRows: n, expandedChildRows: 0,
                                              systemRowCount: 0, systemExpanded: false),
                    padding + PopoverMetrics.rowHeight * CGFloat(n),
                    "\(n) rows")
            }
        }

        // Children only occupy space once their parent is open, which is what
        // lets the breakdown exist without costing height by default.
        Check.test("collapsed children cost no height") {
            Check.expectEqual(
                PopoverMetrics.contentHeight(appRows: 3, expandedChildRows: 0,
                                          systemRowCount: 0, systemExpanded: false),
                padding + PopoverMetrics.rowHeight * 3)
        }

        Check.test("expanded children add their own rows") {
            Check.expectEqual(
                PopoverMetrics.contentHeight(appRows: 3, expandedChildRows: 4,
                                          systemRowCount: 0, systemExpanded: false),
                padding + PopoverMetrics.rowHeight * 7)
        }

        // The summary row is a pixel taller than an app row — it uses 5 pt
        // insets rather than 4 — and getting this wrong is a slow drift that
        // only shows up as a clipped last row.
        Check.test("a collapsed System group costs one summary row") {
            Check.expectEqual(
                PopoverMetrics.contentHeight(appRows: 1, expandedChildRows: 0,
                                          systemRowCount: 3, systemExpanded: false),
                padding + PopoverMetrics.rowHeight + PopoverMetrics.systemSummaryHeight)
        }

        Check.test("an expanded System group adds its daemons") {
            Check.expectEqual(
                PopoverMetrics.contentHeight(appRows: 1, expandedChildRows: 0,
                                          systemRowCount: 3, systemExpanded: true),
                padding + PopoverMetrics.rowHeight
                    + PopoverMetrics.systemSummaryHeight + PopoverMetrics.rowHeight * 3)
        }

        Check.test("no System group means no summary row") {
            Check.expectEqual(
                PopoverMetrics.contentHeight(appRows: 2, expandedChildRows: 0,
                                          systemRowCount: 0, systemExpanded: true),
                padding + PopoverMetrics.rowHeight * 2,
                "expanded is meaningless with nothing in the group")
        }

        /// The cap is what keeps the popover from resizing in the state it
        /// spends most of its time in — see `PopoverMetrics.maxListHeight`.
        Check.test("a long list is capped rather than grown") {
            for n in [14, 30, 500] {
                Check.expectEqual(
                    PopoverMetrics.listHeight(appRows: n, expandedChildRows: 0,
                                              systemRowCount: 0, systemExpanded: false),
                    PopoverMetrics.maxListHeight,
                    "\(n) rows must clamp")
            }
        }

        // 13 rows is the last count that still fits exactly, so it is the
        // boundary an off-by-one would cross.
        Check.test("the cap is reached exactly where the arithmetic says") {
            let justUnder = PopoverMetrics.contentHeight(appRows: 12, expandedChildRows: 0,
                                                      systemRowCount: 0, systemExpanded: false)
            Check.expectTrue(justUnder < PopoverMetrics.maxListHeight,
                             "12 rows still fits")
            Check.expectEqual(justUnder, padding + PopoverMetrics.rowHeight * 12)
        }

        // Calibrated against SwiftUI's actual layout: 1 app row measured 88.5
        // total, of which 56.5 is the header and divider above the list.
        Check.test("the constants match the measured layout") {
            Check.expectEqual(PopoverMetrics.rowHeight, 24)
            Check.expectEqual(PopoverMetrics.systemSummaryHeight, 25)
            Check.expectEqual(PopoverMetrics.listVerticalPadding, 8)
            Check.expectEqual(
                PopoverMetrics.contentHeight(appRows: 1, expandedChildRows: 0,
                                          systemRowCount: 0, systemExpanded: false),
                32, "88.5 measured − 56.5 of header and divider")
            Check.expectEqual(
                PopoverMetrics.listHeight(appRows: 1, expandedChildRows: 0,
                                          systemRowCount: 0, systemExpanded: false),
                33, "the frame carries one point of slack over the content")
        }
    }

    Check.suite("PopoverMetrics — the scrollbar never strobes") {

        /// The glitch this exists to prevent: the frame sized to exactly its own
        /// content, where "does this scroll" is decided by rounding, re-decided
        /// twice a second as the model republishes, and shown as a scrollbar
        /// flashing in and out. Measured at content 201.0 in a frame of 201.0.
        Check.test("a list that fits is never exactly its content's height") {
            for rows in 0...12 {
                for kids in 0...4 {
                    let content = PopoverMetrics.contentHeight(
                        appRows: rows, expandedChildRows: kids,
                        systemRowCount: 0, systemExpanded: false)
                    let frame = PopoverMetrics.listHeight(
                        appRows: rows, expandedChildRows: kids,
                        systemRowCount: 0, systemExpanded: false)
                    guard frame < PopoverMetrics.maxListHeight else { continue }
                    Check.expectTrue(frame > content,
                                     "\(rows) rows + \(kids) children: \(frame) vs \(content)")
                }
            }
        }

        Check.test("a list that fits reports no scrolling") {
            Check.expectFalse(PopoverMetrics.scrolls(appRows: 6, expandedChildRows: 1,
                                                    systemRowCount: 10, systemExpanded: false),
                              "the case that strobed: 6 apps, one child open")
            Check.expectFalse(PopoverMetrics.scrolls(appRows: 0, expandedChildRows: 0,
                                                    systemRowCount: 0, systemExpanded: false))
        }

        // The System group genuinely overflows — 417 pt of content in 320 — which
        // is why it always animated smoothly and was the useful comparison.
        Check.test("a list that overflows reports scrolling") {
            Check.expectTrue(PopoverMetrics.scrolls(appRows: 6, expandedChildRows: 0,
                                                    systemRowCount: 10, systemExpanded: true))
            Check.expectTrue(PopoverMetrics.scrolls(appRows: 40, expandedChildRows: 0,
                                                    systemRowCount: 0, systemExpanded: false))
        }

        /// Right at the cap the content and the frame have to agree, or the same
        /// coin-flip comes back at exactly 13 rows.
        Check.test("the boundary at the cap does not reintroduce the flicker") {
            let content = PopoverMetrics.contentHeight(appRows: 13, expandedChildRows: 0,
                                                      systemRowCount: 0, systemExpanded: false)
            Check.expectEqual(content, PopoverMetrics.maxListHeight, "13 rows is exactly 320")
            Check.expectFalse(PopoverMetrics.scrolls(appRows: 13, expandedChildRows: 0,
                                                     systemRowCount: 0, systemExpanded: false),
                              "content equal to the frame must not claim to scroll")
        }
    }
}
