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

        // The summary is an ordinary row now, so it costs exactly one.
        Check.test("a collapsed System group costs one summary row") {
            Check.expectEqual(
                PopoverMetrics.contentHeight(appRows: 1, expandedChildRows: 0,
                                          systemRowCount: 3, systemExpanded: false),
                padding + PopoverMetrics.rowHeight * 2)
        }

        Check.test("an expanded System group adds its daemons") {
            Check.expectEqual(
                PopoverMetrics.contentHeight(appRows: 1, expandedChildRows: 0,
                                          systemRowCount: 3, systemExpanded: true),
                padding + PopoverMetrics.rowHeight * 5)
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
            for n in [10, 30, 500] {
                Check.expectEqual(
                    PopoverMetrics.listHeight(appRows: n, expandedChildRows: 0,
                                              systemRowCount: 0, systemExpanded: false),
                    PopoverMetrics.maxListHeight,
                    "\(n) rows must clamp")
            }
        }

        /// The boundary an off-by-one would cross, derived from the cap rather
        /// than written out, so moving the cap does not silently make this pass
        /// for the wrong reason.
        Check.test("the cap is reached exactly where the arithmetic says") {
            let fits = Int((PopoverMetrics.maxListHeight - padding) / PopoverMetrics.rowHeight)
            Check.expectTrue(fits >= 1, "the cap has to hold at least one row")

            let under = PopoverMetrics.contentHeight(appRows: fits, expandedChildRows: 0,
                                                     systemRowCount: 0, systemExpanded: false)
            Check.expectTrue(under <= PopoverMetrics.maxListHeight,
                             "\(fits) rows fits in \(PopoverMetrics.maxListHeight)")
            Check.expectEqual(under, padding + PopoverMetrics.rowHeight * CGFloat(fits))

            let over = PopoverMetrics.contentHeight(appRows: fits + 1, expandedChildRows: 0,
                                                    systemRowCount: 0, systemExpanded: false)
            Check.expectTrue(over > PopoverMetrics.maxListHeight, "\(fits + 1) does not")
            Check.expectTrue(PopoverMetrics.scrolls(appRows: fits + 1, expandedChildRows: 0,
                                                    systemRowCount: 0, systemExpanded: false))
        }

        // Calibrated against SwiftUI's actual layout: a popover with one app row
        // measures 107.5 tall, of which 56.5 is the header and divider above the
        // list and 1 is `fitSlack`.
        Check.test("the constants match the measured layout") {
            Check.expectEqual(PopoverMetrics.rowHeight, 42)
            Check.expectEqual(PopoverMetrics.listVerticalPadding, 8)
            Check.expectEqual(
                PopoverMetrics.contentHeight(appRows: 1, expandedChildRows: 0,
                                          systemRowCount: 0, systemExpanded: false),
                50, "107.5 measured − 56.5 of header and divider − 1 of slack")
            Check.expectEqual(
                PopoverMetrics.listHeight(appRows: 1, expandedChildRows: 0,
                                          systemRowCount: 0, systemExpanded: false),
                51, "the frame carries one point of slack over the content")
        }

        /// A row is two lines tall now, so the icon has to be big enough not to
        /// float in the middle of it.
        Check.test("neither icon is taller than the row it sits in") {
            for size in [PopoverMetrics.iconSize, PopoverMetrics.childIconSize] {
                Check.expectTrue(size + PopoverMetrics.rowVerticalPadding * 2
                                    <= PopoverMetrics.rowHeight,
                                 "an icon of \(size) must fit inside \(PopoverMetrics.rowHeight)")
            }
        }

        /// The name and the bar are one unit describing one app, and reading as
        /// that unit depends on them staying within the icon they sit beside.
        /// Computed from the real font line heights, so shrinking the type or
        /// tightening `detailSpacing` cannot quietly break it.
        Check.test("the name and bar never run taller than their own icon") {
            for indented in [false, true] {
                let stack = PopoverMetrics.detailStackHeight(indented: indented)
                let icon = PopoverMetrics.iconSize(indented: indented)
                Check.expectTrue(stack <= icon,
                                 "\(indented ? "child" : "app") stack \(stack) vs icon \(icon)")
            }
        }

        // Both levels have to fit the stated content height, or a row is clipped
        // rather than merely mismeasured.
        Check.test("both levels fit the row's content height") {
            for indented in [false, true] {
                Check.expectTrue(
                    PopoverMetrics.iconSize(indented: indented) <= PopoverMetrics.rowContentHeight,
                    "icon at \(indented ? "child" : "app") level")
                Check.expectTrue(
                    PopoverMetrics.detailStackHeight(indented: indented)
                        <= PopoverMetrics.rowContentHeight,
                    "stack at \(indented ? "child" : "app") level")
            }
            Check.expectEqual(PopoverMetrics.rowContentHeight
                                + PopoverMetrics.rowVerticalPadding * 2,
                              PopoverMetrics.rowHeight,
                              "the row is its content plus its insets")
        }

        // A child is subordinate to the app above it, and the type carries that
        // as much as the indent does.
        Check.test("child type and icon stay smaller than an app's") {
            Check.expectTrue(PopoverMetrics.childIconSize < PopoverMetrics.iconSize)
            Check.expectTrue(PopoverMetrics.childNameFontSize < PopoverMetrics.nameFontSize)
            Check.expectTrue(PopoverMetrics.childTotalFontSize < PopoverMetrics.totalFontSize)
        }

        /// The bar plus the figure after it plus every inset has to fit the
        /// popover's 320 pt, at the deepest indent, or a long total is clipped.
        Check.test("a full-width bar still fits the most indented row") {
            let used = PopoverMetrics.rowHorizontalPadding * 2
                + PopoverMetrics.childIndent
                + PopoverMetrics.childIconSize
                + PopoverMetrics.iconSpacing * 2
                + PopoverMetrics.detailWidth
            Check.expectTrue(used <= 320, "row uses \(used) of 320")
        }
    }

    Check.suite("PopoverMetrics — the scrollbar never strobes") {

        /// The glitch this exists to prevent: the frame sized to exactly its own
        /// content, where "does this scroll" is decided by rounding, re-decided
        /// twice a second as the model republishes, and shown as a scrollbar
        /// flashing in and out. Measured at content 201.0 in a frame of 201.0.
        Check.test("a list that fits is never exactly its content's height") {
            for rows in 0...7 {
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
            // Contrived so content lands exactly on the cap, which is where the
            // same coin-flip would otherwise come back.
            let rows = Int((PopoverMetrics.maxListHeight - PopoverMetrics.listVerticalPadding)
                           / PopoverMetrics.rowHeight)
            let exact = PopoverMetrics.listVerticalPadding
                + PopoverMetrics.rowHeight * CGFloat(rows)
            if exact == PopoverMetrics.maxListHeight {
                Check.expectFalse(PopoverMetrics.scrolls(appRows: rows, expandedChildRows: 0,
                                                         systemRowCount: 0, systemExpanded: false),
                                  "content equal to the frame must not claim to scroll")
            } else {
                // No row count lands on the cap, so the boundary cannot be hit.
                Check.expectTrue(exact < PopoverMetrics.maxListHeight)
            }
        }
    }
}
