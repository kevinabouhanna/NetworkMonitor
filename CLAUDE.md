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
     - screenshots of anything that looks different, retaken from the real app,
       never mocked up

A change to the website alone still gets an issue, but it ships when `gh-pages`
is pushed and has no release of its own.

## Building and testing

- `make test` runs the suite. It is an executable, not `swift test`: Command Line
  Tools has no XCTest. The pre-push hook runs it too (`make hooks` installs it).
- `make app` builds `build/NetworkMonitor.app`.
- `make install` builds and installs to /Applications.
- **Command Line Tools only.** With the macOS 27 SDK, SwiftUI's `@State` is a
  macro, and its implementation ships only with Xcode. Hold view state in an
  `ObservableObject` instead; see `SettingsPaneState`.
- **The real speed test uses 70–200 MB per run.** Test against the stand-in
  script in `SpeedTestTests` rather than running it again and again.
- **A development build shares settings and data with the installed app.** Quit
  the installed copy before running one, put back any setting you change, and
  relaunch the installed copy afterwards.
