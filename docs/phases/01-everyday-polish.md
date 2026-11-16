# Phase 1: Everyday polish

**Milestone:** Phase 1: Everyday polish · **Status:** Now

**Goal:** what people touch every day feels finished: the popover never jumps, the main
window's three lists behave the same, and the VoiceOver and keyboard work of 1.29 is checked.

## The plans

Open again (17 Nov 2026) for one bug Kevin found in the popover:

- **#660** The popover's scroll bar grows and shrinks when the list scrolls past an opened
  entry. Its lists only draw the rows on screen and guess the height of the rest, and an opened
  entry changes the guess; the fix measures every row once, and a test holds the list's height
  steady while it scrolls. First in Now: the popover is what people use every day.

Done on 13 Nov 2026, and shipped since:

- the popover keeps one height in all four views (#599);
- the main window's three lists expand, collapse and filter the same way (#593): a click
  anywhere on a row opens or closes it, the arrows stay, and filtering is the row's own
  **Filter** button (Kevin's revised option B, after he found "a click filters" misleading);
- the accessibility tests read the real main window, sidebar and all (#527);
- the sidebar's button and the search's glass read in the language shown (#621);
- the VoiceOver and keyboard checks after 1.29.0 (#525), which Kevin asked a session to do
  rather than him ("you do the test"): done in a VM, with View and Period now choosing with
  ← →.
