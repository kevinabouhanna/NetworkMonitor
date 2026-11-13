# Phase 1: Everyday polish

**Milestone:** Phase 1: Everyday polish · **Status:** Now

**Goal:** what people touch every day feels finished: the popover never jumps, the main
window's three lists behave the same, and the VoiceOver and keyboard work of 1.29 is checked
by a person.

## The plans

- **Expand, collapse and filter the same way everywhere** (#593). Usage History, Connections
  and Ads and Trackers each did it differently in the main window (the popover is fine).
  Option A (a click on a row filters to it) is on `main`; Kevin found it misleading
  (13 Nov 2026), so a revised option B waits for his second review: a click anywhere on a row
  opens or closes it, the arrows stay, and filtering is its own **Filter** button on the row.
Done (13 Nov 2026, not released yet): the popover keeps one height in all four views (#599);
the accessibility tests read the real main window, sidebar and all (#527); the sidebar's button
and the search's glass read in the language shown (#621); and the VoiceOver and keyboard checks
after 1.29.0 (#525), which Kevin asked a session to do rather than him ("you do the test"):
done in a VM, with View and Period now choosing with ← →.
