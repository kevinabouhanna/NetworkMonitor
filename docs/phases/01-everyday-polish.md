# Phase 1: Everyday polish

**Milestone:** Phase 1: Everyday polish · **Status:** Now

**Goal:** what people touch every day feels finished: the popover never jumps, the main
window's three lists behave the same, and the VoiceOver and keyboard work of 1.29 is checked
by a person.

## The plans

- **Kevin's checks after 1.29.0** (#525): what only a person can judge, with VoiceOver and the
  keyboard: Dock mode, the map's starting point, the Ads total, ⓘ with the keyboard.
- **In Chinese, VoiceOver reads the toolbar's Search and Sidebar buttons in English** (#621,
  a bug found by #527): their names come from AppKit, not the app's table.

Done (13 Nov 2026, not released yet): the popover keeps one height in all four views (#599),
the accessibility tests read the real main window, sidebar and all (#527), and the main
window's three lists expand, collapse and filter the same way (#593): a click anywhere on a
row opens or closes it, the arrows stay, and filtering is the row's own **Filter** button
(Kevin's revised option B, after he found "a click filters" misleading).
