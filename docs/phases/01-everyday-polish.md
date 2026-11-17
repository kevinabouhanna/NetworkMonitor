# Phase 1: Everyday polish

**Milestone:** Phase 1: Everyday polish · **Status:** Now

**Goal:** what people touch every day feels finished: the popover never jumps, the main
window's three lists behave the same, and the VoiceOver and keyboard work of 1.29 is checked.

## The plans

Open again (17 Nov 2026) for a bug Kevin found in what he uses every day:

- **#663** Copies of one app are one row. Today listed Home Control 83 times: every install
  of its iPhone build in the Simulator goes into a new folder, and every folder was its own
  row. Copies of one app (same bundle id and name) become one row, and a rule on it covers
  every copy. First in Now.

Done on 17 Nov 2026, on `main`, not released yet (releases are on hold until Kevin says, #667):

- the popover's scroll bar keeps one size when the list scrolls past an opened entry (#660):
  its lists lay out every row rather than guessing the height of those off screen, checked in
  a VM in Today, Connections and Ads blocked, and held by a test.

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
