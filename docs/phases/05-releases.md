# Phase 5: Releases people check first

**Milestone:** Phase 5: Releases people check first · **Status:** Now

**Goal:** a new version reaches Kevin and beta users before everyone, and the tooling that
builds, checks and releases the app stays in order.

## The plans

- **Release 1.34.0 to everyone once the beta is good** (#778), Now: Usage History following
  midnight (#770) and the menu bar's top row (#772), both first written by defragekb. A beta
  first, then `v1.34.0` on its commit when Kevin says it's good.
- **Release 1.35.0: a beta first, with #754's switch** (#794), Now: beta 1 carries only the
  switch for measuring Safari with iCloud Private Relay (#786), off unless set by hand, for
  defragekb to run. 1.35.0 goes to everyone when Kevin says, with what lands by then.
- **Keep the tooling and the plan in order** (#606), standing: tooling chores (the vendored
  kits, local CI, the release workflow, the pictures' VM image, the plan and the board kept in
  step) are its steps. First among them: CI fails a change that keeps the app busy while it's
  idle, since nothing caught beta 1's battery drain (#723); the window tests fail while the screen is locked, so
  nothing can be pushed while Kevin is away (#626); then the pictures the VM gets wrong, for
  1.31.0 and again for 1.33.0 (#650). It stays open on purpose, so this phase stays open with it.

Done: **Release 1.33.0 to everyone** (#747), 26 Nov 2026: four betas (the first never
published, #751), then `v1.33.0` on beta 4's commit, after a signed copy in a VM updated itself
from beta 2 to beta 3 and from beta 3 to beta 4 with its filter back on. Kevin asked on 25 Nov
to review the open pull requests, merge what held, and release it all: the update settings,
YouTube without its ads (#741), and defragekb's web views (#761) and own-network traffic (#753,
#759, #763). **Update settings** (#710), 25 Nov 2026: an Updates section in Settings that says what
happens, and Install updates automatically, off by default, there and in the welcome window,
approved from a working prototype's pictures. **The tests never ask for a keychain password**
(#739), the same day. **Release 1.32.0 to everyone** (#722), 25 Nov 2026: beta 3, with the popover's fixes
(#728), was used and then promoted on its own commit, once product-kit read a release's tag
rather than its beta's (product-kit#115). **The first beta** (#716), 23 Nov 2026: 1.32.0-beta.1 with Enhanced ad blocking, then
beta 2 the same day, after beta 1's menu bar readout redrew itself in a loop and drained the
battery (#719). **Beta releases** (#585), 23 Nov 2026: **Get beta versions** in Settings, a second feed
for beta copies, and a beta's build number just below its release's
(`docs/development.md#betas`). **Release 1.31.0** (#643), 14 Nov 2026: the 36 changes merged since 1.30.2 (all of
phase 1, Pause, Rules), held since 11 Nov (#559), with the first notes in Chinese in the update
window (#640).
