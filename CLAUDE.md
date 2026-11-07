# NetworkMonitor

## Workflow

`~/.claude/CLAUDE.md` has the workflow: issue → pull request → merge → install, carried
through without asking. What's particular to NetworkMonitor:

- **Releasing is routine here.** Carry each change on to a release, the installed app and
  the website without asking.
- **Work in a worktree of your own, never in the main checkout:** several sessions
  work here at once (`docs/development.md#working-in-parallel`). Before your first
  edit, call `EnterWorktree` with the branch's name; a hook makes
  `.claude/worktrees/<branch>` on that branch from a fresh `origin/main`. Another hook
  refuses edits, `git checkout` and `git switch` in the main checkout.
- Branches are named after the issue, e.g. `settings-v2-9`. `Closes #N` also moves the
  issue to Done on the NetworkMonitor project board.
- **Once the PR is merged**, clean up in this order. Merge with `gh pr merge N --squash`,
  without `--delete-branch`: that would remove the worktree you are in. Then
  `ExitWorktree` with `remove` and `discard_changes: true` (the squash commit on `main`
  holds the work), `git pull --ff-only` in the main checkout so it has the latest hooks,
  and delete the branch: `git branch -D <branch>`, `git push origin --delete <branch>`.
- CI checks: `build-and-test`, `universal`.
- **Release it and update the app on this Mac.**
  - Write its What's new in `ReleaseNotes/X.Y.Z.md`, merged with a pull
    request before tagging: short bullets, each a bold lead and the issue,
    with no `]]>`. The Release workflow fails without it, and puts it both in
    the update window and in the release notes.
  - Tag `vX.Y.Z` on `main` and push the tag. The Release workflow builds,
    tests and publishes `NetworkMonitor.dmg` and the appcast Sparkle reads.
  - Do the release in a worktree too: `EnterWorktree` `release-X.Y.Z` for the
    release notes' pull request; once the tag is pushed, `git switch --detach
    vX.Y.Z` there, install, and clean up as above.
  - Update the installed app: `make install` from the tag when the signing
    keys are on this Mac (`~/.config/networkmonitor-signing/`); otherwise
    through Sparkle, once the release is published, so the installed app
    updates itself to the notarized build.
  - Bring the website (`gh-pages` branch) up to date:
    - the hero's version
    - the download line's version and DMG size, in 1024-based MB
    - the "What's in version" link
    - any copy the change affects
    - the pictures: `make site-shots` once the new version is installed. It
      retakes each picture whose window's interface changed, and About, and
      updates the page (`docs/development.md#website-pictures`). Rewrite the alt
      text of any picture it retook for an interface change, from the diff it
      prints, describing the interface, not its numbers.
    - videos it names as showing a changed window: ask Kevin before
      remaking them, since they take real work. The pictures, the popover's
      and the speed test's included, it retakes itself.
  - `make site-audit` against the new install: every window, with real data
    in its lists, checked for what VoiceOver can't name. Fix what it finds.

## Accessibility

Everything in the app must work with VoiceOver. A program catches the major
problems; Kevin answers what it can't judge (#346).

- **Checked automatically.** `make test` (so CI and the pre-push hook) builds
  every window and fails on a control with no name, a control named only by
  its SF Symbol ("Gear shape, filled"), or an image with no description that
  isn't hidden. `make site-audit` runs the same rules on the installed app,
  with real rows in its lists.
- **How to pass.** Name icon-only buttons and unlabelled switches and fields
  with `.accessibilityLabel` in plain words (what it does: "Settings", "Next",
  "Expand"). Hide an icon beside its own name with `.accessibilityHidden(true)`.
  A new window or pane goes into `AccessibilityTests.swift`.
- **Ask Kevin what a program can't judge.** When a change adds or reshapes
  the interface, look at what VoiceOver will read (the accessibility tree,
  `build/site-shots tree <name>`) and decide what you can yourself. Where you
  can't tell (a name that might not make sense to someone who can't see the
  screen, the order things are read in, whether it can all be reached and
  used from the keyboard), ask Kevin before merging: specific questions, all
  at once, each saying what to try and what you expect, e.g. "With VoiceOver
  on, open the popover and press VO-→: does it read *Speed test, button* and
  then *Connections, button*?"

## Words in the app

- Name features and settings in plain words, without technical terms: *Enhanced ad
  blocking*, not *HTTPS filtering*.
- How it works goes behind an ⓘ beside it, shown on hover: briefly what it does and
  how, with the technical terms there for whoever wants them (as in Settings, #185, #189).

## Layout

- **When controls don't fit, say so and propose layouts.** Never fall back on a
  menu that repeats them, such as a toolbar item's » overflow form (#315).
  Until there's a better layout, a window's minimum width is what its toolbar
  needs, measured on the real app.

## The website

The site is the `gh-pages` branch, checked out as a worktree at
`../NetworkMonitor-site`. A change to it follows the same workflow, with no
release of its own:

- Branch from `gh-pages` in a worktree of your own, and open the pull request
  against `gh-pages`. A release's site update goes the same way. The hook starts
  new branches from `main`, so make this one yourself:
  `git worktree add --no-track -b <branch> .claude/worktrees/<branch> origin/gh-pages`,
  then `EnterWorktree` with its `path`. Point the pictures at it with
  `make site-shots SITE=<that path>`, run from your main-branch worktree.
  `../NetworkMonitor-site` stays on `gh-pages`; never switch its branch.
- `Closes #N` closes issues only for pull requests into `main`. Close the issue
  by hand once the PR is merged.
- Merge and clean up as for `main`: without `--delete-branch`, which removes the
  worktree the branch is checked out in.
- The Settings section shows each pane as a real capture in `assets/settings/`.
  Each `<img>` carries the window's size in points (`data-w`, `data-h`), and
  the buttons over it are placed in the same points.

## Building and testing

- `make test` runs the suite. It is an executable, not `swift test`: Command Line
  Tools has no XCTest. The pre-push hook runs it too (`make hooks` installs it).
- `make app` builds `build/NetworkMonitor.app`.
- `make install` builds, notarizes and installs to /Applications. Notarizing needs the
  login keychain unlocked.
- **Signing.** Builds are signed with the Developer ID (team GRQKG7M8CL) from
  `~/.config/networkmonitor-signing/` when it's there, falling back to
  NetworkMonitor's own certificate, then ad-hoc; the Release workflow uses the copies
  in the repository secrets. Only a Developer ID build carries the content filter, the
  helper daemon and the update feed. Every key and secret, and where each lives, is
  in `docs/DISTRIBUTION.md`, a private note that git ignores. Never paste a key
  anywhere, and set secrets with `gh secret set NAME < file`.
- **Test the filter, the helper daemon and Sparkle on a notarized build in
  /Applications**, which `make install` makes; they don't work from `build/`. Point a
  development build at local test data with launch arguments instead of publishing
  anything (`docs/development.md#launch-arguments`).
- **Command Line Tools only.** With the macOS 27 SDK, SwiftUI's `@State` is a
  macro, and its implementation ships only with Xcode. Hold view state in an
  `ObservableObject` instead; see `SettingsPaneState`.
- **The real speed test uses 70–200 MB per run.** Test against the stand-in
  script in `SpeedTestTests` rather than running it again and again.
- **The Mac lane: one at a time on the Mac itself.** Whatever uses the Mac as a
  whole goes through `Scripts/mac-lane.sh`, one at a time across every worktree and
  session. That covers the installed app, the filter, the helper, settings, the
  pointer and screen, and `pkill`. The install, uninstall, helper and smoke-test
  scripts and `make run`, `site-check` and `site-shots` take the lane themselves.
  Launch a development build through it too:
  `Scripts/mac-lane.sh open -W -n build/NetworkMonitor.app --args …` holds the lane
  until that copy quits. A busy lane waits and names its holder. Run those commands
  in the background so a wait can't time out. `Scripts/mac-lane.sh status` says
  whether the lane is free.
- **Computer use has its own lock, held until the session exits.** Check windows
  with the accessibility tree (`make site-check`, `build/site-shots tree <name>`)
  first. Use computer use only for what that can't show, from a short session that
  exits when it's done.
- **Local test servers take a port the system picks**
  (`python3 -m http.server 0 --bind 127.0.0.1`), never a fixed one.
- **Measure a power profile without unplugging:**
  `Scripts/mac-lane.sh open -W -n build/NetworkMonitor.app --args -powerProfile balanced`
  (or `performance`, `saver`). Only launch arguments are read, so nothing persists.
  Time CPU with `ps -o time=` on the app and its `nettop` child, in the
  foreground: `top -l` hangs when run in the background.
- **A development build shares settings and data with the installed app.** In the
  lane, quit the installed copy before running one, put back any setting you
  change, and relaunch the installed copy afterwards.
