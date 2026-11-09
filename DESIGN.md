---
name: NetworkMonitor
description: A Mac's network traffic, read at a glance in the Mac's own look.
---

<!-- Recorded from the code and the before pictures for #437, 2026-11-09, by Impeccable's
`document` (scan mode) adapted for a SwiftUI app. Waiting on Kevin's review.

The frontmatter carries no colour, type, radius or spacing tokens: the app has none.
It uses macOS's semantic colours and text through SwiftUI, which change with light and
dark, Increase Contrast and the accent colour, so a hex or px value here would be a
fabrication. The values the code does fix are recorded below in points. No
`.impeccable/design.json` sidecar either: it holds HTML/CSS snippets for Impeccable's
browser panel, which a native app can't use. -->

# Design System: NetworkMonitor

## Overview

**Proposed north star: "The quiet instrument."** A precise gauge that sits in the menu
bar and the corner of the screen: it reads clearly when looked at, and otherwise stays
out of the way. (Kevin to confirm or rename.)

- **The Mac's own look, not a brand's.** System controls, SF Symbols, the system font,
  semantic colours, window toolbars and grouped Settings forms. Identity comes from what
  is shown and how it's worded, not from decoration.
- **Light and dark are both first-class.** The app follows the system appearance; it is
  not a dark app. The pictures in `docs/design-overhaul/before/` show both.
- **Compact.** Small type, dense rows, numbers right-aligned and in tabular digits.
- **Calm.** Colour appears only where it means something.

## Colors

Semantic system colours throughout; none is defined by the app.

- **Text:** `primary` for names and values; `secondary` (111 uses) for labels, details,
  units and footnotes; `tertiary` (12) for the faintest hints.
- **Accent:** the system accent colour (blue by default) for the bars in Connections and
  Usage History, selection, and links. It follows the user's accent choice.
- **Meaning colours**, always with words beside them:
  - **red:** blocked, and the Ads and Trackers bars and the ADS tag;
  - **orange:** blocked on hotspots, and warnings (20 uses);
  - **green:** always allowed;
  - **purple:** the MALWARE tag;
  - **menu bar readout:** download and upload colours the user picks in Settings ›
    General (green and white by default), and a speed test's own pair.
- **Backgrounds:** window and grouped-form backgrounds from the system;
  `windowBackgroundColor` where a view must paint its own.

### Named rules

- **Colour carries meaning, never decoration.** A coloured element is a state or a
  category, and it is named in words too (BLOCKED, ALWAYS ALLOWED, ADS).
- **The accent is the user's.** Bars and selection use the accent colour, so they follow
  System Settings rather than a brand blue.

## Typography

SF Pro (the system font) only, in fixed point sizes; no text styles (`.body`,
`.headline`) are used.

- **Period titles:** 20–28 pt semibold ("Today", "459 blocked").
- **Header figures:** 13–15 pt semibold or medium (totals beside the period).
- **Rows:** 12–13 pt regular for names, 11–12 pt for values.
- **Details and footnotes:** 10–11 pt, secondary.
- **Tags:** 8–9 pt bold capitals in a tinted capsule (ADS, MALWARE, BLOCKED).
- **Numbers:** tabular digits (`monospacedDigit`, 32 places) so columns line up.
- **Settings forms:** the system's grouped-form text, not set by the app.

Found: thirteen sizes between 8 and 32 pt, most often 10, 11 and 12. A tighter scale is
a question for the overhaul, not a rule recorded here.

## Layout

- **Settings:** one fixed width for every pane (`SettingsMetrics.paneWidth`, 720 pt) in
  the system's grouped form style; the window's height follows the pane. Panes sit
  behind a toolbar of labelled icons: General, Speed Test, History, Connections, Ads,
  Hotspot, About.
- **Windows:** one column read top to bottom: scope controls, then the period's title and
  totals, then a timeline, then the list. The toolbar holds the window's view, the period
  (Day/Week/Month/Year), ‹ Today › and search.
- **Minimum widths** are what each toolbar needs, measured on the real app; never a »
  overflow menu (#315). Connections opens at 1120 × 844 pt, Ads and Trackers at
  900 × 724 pt.
- **Margins:** 20 pt at the window's sides, the most common padding in the code.
- **Rows:** about 27 pt tall in lists, with the value bar and the figure at the trailing
  edge.

## Elevation & Depth

Flat. Depth comes from the system: window toolbars, the grouped form's inset sections,
popovers and sheets. The app draws no shadows of its own.

## Shapes

The system's controls set the shapes. The app's own: capsule tags, rounded bars, and
rounded rectangles of 2–10 pt (eight different radii in the code, most often 6 and 8).

## Components

- **Toolbar controls:** segmented controls for the view and the period, a ‹ Today ›
  stepper, a search field; system glass in macOS 26 and later.
- **Scope row:** labelled segmented controls ("Group by", "Show") at the leading edge,
  the network filter (All, Wi-Fi, Hotspot) at the trailing edge.
- **Header:** the period as a large title, then one line of totals with the main figure
  in semibold and the rest in secondary text, separated by middle dots.
- **Timeline:** one bar per hour, day or month, in the accent colour (red in Ads and
  Trackers); click or drag to narrow the list.
- **List rows:** disclosure chevron, an app icon or SF Symbol, the name with any tags,
  then a proportional bar and the figure, right-aligned.
- **Tags:** capsule badges in a meaning colour with bold capitals.
- **Settings rows:** the grouped form's `LabeledContent`, switches on the trailing edge,
  footnotes under each section, explanations behind an ⓘ (`ExplainedRow`).
- **Offers:** a row with an SF Symbol, a bold line, a sentence and one button
  ("Know your Wi-Fi networks by name… Turn On…").
- **Empty states:** a centred SF Symbol, a bold line, a sentence and, when there's
  something to do, one button ("Ad blocking is off · Turn On").

## Do's and Don'ts

### Do:
- Use system controls, SF Symbols and semantic colours.
- Name every state in words beside its colour.
- Keep figures in tabular digits, aligned to the trailing edge.
- Put how something works behind an ⓘ, in plain words.
- Measure a window's minimum width on the real app.

### Don't:
- Add a brand colour, a custom font, gradients or shadows.
- Hide a control in an overflow menu when it doesn't fit (#315).
- Use technical terms in names and labels.
- Rely on colour alone.
