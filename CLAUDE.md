# NetworkMonitor

## Workflow

`~/.claude/CLAUDE.md` has the workflow: issue → pull request → merge → install, carried
through without asking. What's particular to NetworkMonitor:

- **Releasing is routine here.** Carry each change on to a release, the installed app and
  the website without asking.
- Branches are named after the issue, e.g. `settings-v2-9`. `Closes #N` also moves the
  issue to Done on the NetworkMonitor project board.
- CI checks: `build-and-test`, `universal`.
- **Release it and update the app on this Mac.**
  - Write its What's new in `ReleaseNotes/X.Y.Z.md`, merged with a pull
    request before tagging: short bullets, each a bold lead and the issue,
    with no `]]>`. The Release workflow fails without it, and puts it both in
    the update window and in the release notes.
  - Tag `vX.Y.Z` on `main` and push the tag. The Release workflow builds,
    tests and publishes `NetworkMonitor.dmg` and the appcast Sparkle reads.
  - Update the installed app: `make install` from the tag when the signing
    keys are on this Mac (`~/.config/networkmonitor-signing/`); otherwise
    through Sparkle, once the release is published, so the installed app
    updates itself to the notarized build.
  - Bring the website (`gh-pages` branch) up to date:
    - the hero's version
    - the download line's version and DMG size, in 1024-based MB
    - the "What's in version" link
    - any copy the change affects
    - the About pane in the Settings section (`assets/settings/about.png`),
      which shows the version, so it changes with every release
    - screenshots of anything that looks different, retaken from the real app,
      never mocked up

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

- Branch from `gh-pages` and open the pull request against `gh-pages`. A
  release's site update goes the same way.
- `Closes #N` closes issues only for pull requests into `main`. Close the issue
  by hand once the PR is merged.
- Don't pass `--delete-branch` to `gh pr merge` while the branch is checked out
  in the worktree: `gh` removes the worktree with it. Merge, switch the worktree
  back to `gh-pages`, then delete the branch.
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
- **Measure a power profile without unplugging:**
  `open -n build/NetworkMonitor.app --args -powerProfile balanced` (or
  `performance`, `saver`). Only launch arguments are read, so nothing persists.
  Time CPU with `ps -o time=` on the app and its `nettop` child, in the
  foreground: `top -l` hangs when run in the background.
- **A development build shares settings and data with the installed app.** Quit
  the installed copy before running one, put back any setting you change, and
  relaunch the installed copy afterwards.
