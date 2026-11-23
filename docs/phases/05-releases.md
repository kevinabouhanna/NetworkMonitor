# Phase 5: Releases people check first

**Milestone:** Phase 5: Releases people check first · **Status:** Now

**Goal:** a new version reaches Kevin and beta users before everyone, and the tooling that
builds, checks and releases the app stays in order.

## The plans

- **The first beta** (#716), Now, waiting on Kevin: 1.32.0-beta.1 went out on 23 Nov 2026,
  with Enhanced ad blocking; Kevin's copy is on it. It goes to everyone as 1.32.0 when he says
  it's good, once product-kit reads the release's tag rather than its beta's (product-kit#115). Its first step: the menu bar readout redrawing itself in a loop in the beta, which drains the battery (#719).
- **Keep the tooling and the plan in order** (#606), standing: tooling chores (the vendored
  kits, local CI, the release workflow, the pictures' VM image, the plan and the board kept in
  step) are its steps. First among them: the window tests fail while the screen is locked, so
  nothing can be pushed while Kevin is away (#626); then the two pictures the VM got wrong for
  1.31.0 (#650). It stays open on purpose, so this phase stays open with it.

Done: **Beta releases** (#585), 23 Nov 2026: **Get beta versions** in Settings, a second feed
for beta copies, and a beta's build number just below its release's
(`docs/development.md#betas`). **Release 1.31.0** (#643), 14 Nov 2026: the 36 changes merged since 1.30.2 (all of
phase 1, Pause, Rules), held since 11 Nov (#559), with the first notes in Chinese in the update
window (#640).
