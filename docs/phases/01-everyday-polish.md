# Phase 1: Everyday polish

**Milestone:** Phase 1: Everyday polish · **Status:** Now

**Goal:** what people touch every day feels finished: the popover never jumps, the main
window's three lists behave the same, and the VoiceOver and keyboard work of 1.29 is checked
by a person.

## The plans

- **The popover jumps when opening Wi-Fi, Ethernet or Hotspot** (#599, a bug). Data and
  Connections keep the popover's height; the network sections don't, so it twitches. They
  should keep the same height.
- **Expand, collapse and filter the same way everywhere** (#593). Usage History, Connections
  and Ads and Trackers each do it differently in the main window (the popover is fine). First
  two options, shown as a design page for Kevin, then the one he picks.
- **Kevin's checks after 1.29.0** (#525): what only a person can judge, with VoiceOver and the
  keyboard: Dock mode, the map's starting point, the Ads total, ⓘ with the keyboard.
- **Tests check the main window as one window again** (#527), now that the audit reads on the
  main thread (#500), so the tests check what people see.
