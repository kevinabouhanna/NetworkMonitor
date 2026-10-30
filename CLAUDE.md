# NetworkMonitor

## Workflow: issue → pull request → release

Nothing changes without all three, in this order.

1. **An issue.** Every change starts from an issue that says what and why. If none
   exists, open one first. Keep its description current: it is the record of
   what was decided.
2. **A pull request from a branch.**
   - Name the branch after the issue, e.g. `settings-v2-9`.
   - Put `Closes #N` in the PR description, so merging closes the issue and moves
     it to Done on the NetworkMonitor project board.
   - CI (`build-and-test`, `universal`) must be green before merging.
   - Squash-merge.
   - **Never push to `main` directly.**
3. **A release** once it is merged.
   - Tag `vX.Y.Z` on `main` and push the tag. The Release workflow builds,
     tests and publishes `NetworkMonitor.dmg`.
   - Add a "What's new in X.Y.Z" section to the release notes.
   - Install it on the Mac with `make install` from the tag.
   - Bring the website (`gh-pages` branch) up to date:
     - the hero's version
     - the download line's version and DMG size, in 1024-based MB
     - the "What's in version" link
     - any copy the change affects
     - the About pane in the Settings section (`assets/settings/about.png`),
       which shows the version, so it changes with every release
     - screenshots of anything that looks different, retaken from the real app,
       never mocked up

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
  helper daemon and the update feed. Keys and secrets are listed in
  `docs/DISTRIBUTION.md`; never paste one anywhere, and set secrets with
  `gh secret set NAME < file`.
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
