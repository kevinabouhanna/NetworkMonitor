# Phase 5: Releases people check first

**Milestone:** Phase 5: Releases people check first · **Status:** Now

**Goal:** a new version reaches Kevin and beta users before everyone, and the tooling that
builds, checks and releases the app stays in order.

## The plans

- **Beta releases** (#585), Now: a beta channel in Sparkle, a setting to opt in, and a release
  promoted to everyone only once Kevin says it's good. Everything up to a release is automatic
  now; what a program can't judge is whether it looks and works right to a person. Built before
  Enhanced ad blocking (#256) ships, so that feature reaches beta users first. Built on 23 Nov
  2026, while releases are on hold: **Get beta versions** in Settings, a second feed for beta
  copies, and a beta's build number just below its release's (`docs/development.md#betas`).
- **The first beta** (#716), Later, waiting on Kevin: once releases resume, the next version
  goes to beta copies, his included, then to everyone when he says it's good.
- **Keep the tooling and the plan in order** (#606), standing: tooling chores (the vendored
  kits, local CI, the release workflow, the pictures' VM image, the plan and the board kept in
  step) are its steps. First among them: the window tests fail while the screen is locked, so
  nothing can be pushed while Kevin is away (#626); then the two pictures the VM got wrong for
  1.31.0 (#650). It stays open on purpose, so this phase stays open with it.

Done: **Release 1.31.0** (#643), 14 Nov 2026: the 36 changes merged since 1.30.2 (all of
phase 1, Pause, Rules), held since 11 Nov (#559), with the first notes in Chinese in the update
window (#640).
