# Phase 2: Ad blocking that holds up

**Milestone:** Phase 2: Ad blocking that holds up · **Status:** Done

**Goal:** the best ad blocking a Mac app can do in every app, with the controls people know
from other ad blockers.

## The plans

- Nothing open.

Done:

- **YouTube plays without its ads, and its pages load faster than they did, with Enhanced ad
  blocking on** (#741), 25 Nov 2026, for 1.33.0: the ad slots in YouTube's own data get names its
  player doesn't know, and connections are kept. In a VM, 15 of 20 pages offered an ad with it on
  and none showed it; with it off, 5 of 15 offered one and all 5 showed it.
- **Enhanced ad blocking** (#256), released in 1.32.0 on 25 Nov 2026 (#722): an
  opt-in switch that hides the ads inside pages in the browsers, and in the apps chosen with
  **Apps…**, by opening secure connections on this Mac, never banking, health, government or
  payment sites. Built as steps: the rules for inside pages (#681), a certificate made on this
  Mac (#682), the page rewriter, which fails open (#683), which connections it opens (#684), the
  secure bridge (#701), requests refused by address (#699), the transparent proxy (#702), the
  switch in Settings (#685), and its own security review and battery cost (#686, fixes in
  #711). What was left,
  YouTube without its pre-roll ads on the day it reached everyone, was checked that day and
  didn't hold: #741.
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
