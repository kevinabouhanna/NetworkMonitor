# Phase 5: Releases people check first

**Milestone:** Phase 5: Releases people check first · **Status:** Now

**Goal:** a new version reaches Kevin and beta users before everyone, and the tooling that
builds, checks and releases the app stays in order.

## The plans

- **Release 1.32.0 to everyone once the beta is good** (#722), waiting on Kevin: 1.32.0-beta.2
  is out with the battery fix (#719); Kevin's copy updates to it. It goes to everyone as 1.32.0
  when he says it's good, once product-kit reads the release's tag rather than its beta's
  (product-kit#115).
- **Update settings: automatic updates on or off** (#710), Next: an Updates section in Settings
  that says what happens, and a switch to install new versions automatically, off by default
  (today Settings only has the daily check). It starts with pictures of updating as it is. After
  the ⓘ links (#230), before the Chrome extension (#257).
- **Keep the tooling and the plan in order** (#606), standing: tooling chores (the vendored
  kits, local CI, the release workflow, the pictures' VM image, the plan and the board kept in
  step) are its steps. First among them: CI fails a change that keeps the app busy while it's
  idle, since nothing caught beta 1's battery drain (#723); the window tests fail while the screen is locked, so
  nothing can be pushed while Kevin is away (#626); then the two pictures the VM got wrong for
  1.31.0 (#650). It stays open on purpose, so this phase stays open with it.

Done: **The first beta** (#716), 23 Nov 2026: 1.32.0-beta.1 with Enhanced ad blocking, then
beta 2 the same day, after beta 1's menu bar readout redrew itself in a loop and drained the
battery (#719). **Beta releases** (#585), 23 Nov 2026: **Get beta versions** in Settings, a second feed
for beta copies, and a beta's build number just below its release's
(`docs/development.md#betas`). **Release 1.31.0** (#643), 14 Nov 2026: the 36 changes merged since 1.30.2 (all of
phase 1, Pause, Rules), held since 11 Nov (#559), with the first notes in Chinese in the update
window (#640).
