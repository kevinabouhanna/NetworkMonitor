# Phase 2: Ad blocking that holds up

**Milestone:** Phase 2: Ad blocking that holds up · **Status:** Next

**Goal:** the best ad blocking a Mac app can do in every app, with the controls people know
from other ad blockers.

## The plans

- **Connections shows Traffic · Blocked · Rules in every build** (#638, a bug Kevin met
  reviewing #592): in a build without the Developer ID it hid the switch, so a review build
  opened on Rules had no way back to Traffic; Ads and Trackers always shows its own.
- **Ad blocking that holds up** (#246), what's left of it: **Enhanced ad blocking** (#256), an
  opt-in switch that removes ads inside pages and videos in every app, by opening secure
  connections on this Mac, never banking or health sites. Off by default.

Done (13 Nov 2026, not released yet):

- **Pause ad blocking from the menu bar** (#600). The popover's Ads blocked view opens with a
  bar saying whether ads are blocked, with **Pause** (for an hour, until tomorrow, or on this
  network) or **Resume**, and the menu bar item's right-click menu has the same.
- **Your own rules, where you look for them** (#592). A user couldn't find the rules they'd
  made: Connections' rules were listed only in its settings. Kevin approved the spec and asked
  that ad blocking's rules work the same way, so **Rules** sits beside Traffic and Blocked,
  and beside Overview and the Log, made of the same parts: each rule with what it did in the
  period, a menu to change it, Show and −, and a bar to add a site. Ad blocking's *Never
  block* and *Always block* are now **Always Allow** and **Block**, Connections' words, and
  Settings keeps no second copy of the lists.

The Chrome extension is a second product with its own store listing, so it's its own phase
(phase 3), as decided on 7 Nov 2026 (#256).
