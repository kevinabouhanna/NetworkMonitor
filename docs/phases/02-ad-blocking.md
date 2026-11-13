# Phase 2: Ad blocking that holds up

**Milestone:** Phase 2: Ad blocking that holds up · **Status:** Now

**Goal:** the best ad blocking a Mac app can do in every app, with the controls people know
from other ad blockers.

## The plans

- **Enhanced ad blocking** (#256), Now, second in the order after the release: an opt-in
  switch that removes ads inside pages and videos in every app, by opening secure connections
  on this Mac, never banking or health sites. Off by default. It reaches people as a beta first
  (#585, phase 5), since it's the one feature that opens secure connections.

Done:

- **Ad blocking that holds up** (#246), closed 13 Nov 2026 with everything but Enhanced ad
  blocking shipped: an Ads and Trackers window of its own with an overview and a live log, the
  lists' own record of what they block, rules, more lists, trackers hiding behind a site's own
  name, and one total. Enhanced ad blocking became its own item, so the board shows it rather
  than an umbrella with the phase's name (#644).
- **Pause ad blocking from the menu bar** (#600). The popover's Ads blocked view opens with a
  bar saying whether ads are blocked, with **Pause** (for an hour, until tomorrow, or on this
  network) or **Resume**, and the menu bar item's right-click menu has the same.
- **Your own rules, where you look for them** (#592, #638). A user couldn't find the rules
  they'd made: Connections' rules were listed only in its settings. Kevin approved the spec and
  asked that ad blocking's rules work the same way, so **Rules** sits beside Traffic and
  Blocked, and beside Overview and the Log, made of the same parts: each rule with what it did
  in the period, a menu to change it, Show and −, and a bar to add a site. Ad blocking's *Never
  block* and *Always block* are now **Always Allow** and **Block**, Connections' words, and
  Settings keeps no second copy of the lists. The switch shows in every build (#638).

Pause and Rules are merged, not released yet: they go out with 1.31.0 (#643).

The Chrome extension is a second product with its own store listing, so it's its own phase
(phase 3), as decided on 7 Nov 2026 (#256).
