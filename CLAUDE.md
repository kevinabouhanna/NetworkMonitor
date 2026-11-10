# NetworkMonitor

## Workflow

`~/.claude/CLAUDE.md` has the workflow: issue → pull request → merge → install, carried
through without asking. What's particular to NetworkMonitor:

- **Releasing is routine here.** Carry each change on to a release, the installed app and
  the website without asking.
  - **Only when the app changes (#484).** A tag offers every installed copy an update, so
    tooling-only work (Scripts/, CI, the site's tooling, development docs) is done once
    merged into `main` or `gh-pages`, and rides along with the next release. Release when
    something the app ships changes: `Sources/`, or `Resources/` it bundles.
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
- CI checks: `build-and-test`, `universal`. Merge once both pass.
  - They run on this Mac, never on GitHub Actions (Kevin, 10 Nov 2026: local first, GitHub
    only for releases; #490). For every pull request run `local-ci <pr>` (the `shared-mac`
    plugin's; `Scripts/local-ci.sh <pr>` is the same, with a fallback copy) from your worktree,
    in the background: 5–15 minutes. It runs both jobs from `.claude/ci.conf.sh` and records
    each under its check name. Its smoke test takes the `networkmonitor` lane, so tell other
    sessions first.
  - Nothing in it waits forever: another run up to 2 h, a job up to 60 min (#483).
  - Releases stay on GitHub's Release workflow: the signing, notary and Sparkle keys are
    GitHub secrets, not on this Mac.
- **Release it and update the app on this Mac.**
  - Write its What's new in `ReleaseNotes/X.Y.Z.md`, merged with a pull
    request before tagging: short bullets, each a bold lead and the issue,
    with no `]]>`. The Release workflow fails without it, and puts it both in
    the update window and in the release notes.
  - Before tagging, `gh-actions can-run` (seconds: the Actions billing, or the no-op
    `canary.yml`; kept an hour). If it says no, stop and tell Kevin: without the signing keys
    on this Mac there's no local release, and keys are never copied around.
  - Tag `vX.Y.Z` on `main` and push the tag. The Release workflow builds,
    tests and publishes `NetworkMonitor.dmg` and the appcast Sparkle reads.
    Watch it in the background with `gh-actions watch --ref vX.Y.Z --jobs release`: 0 passed,
    1 failed (fix it), 4 GitHub couldn't run it (stop and tell Kevin), 3 still running.
  - Do the release in a worktree too: `EnterWorktree` `release-X.Y.Z` for the
    release notes' pull request; once the tag is pushed, `git switch --detach
    vX.Y.Z` there, install, and clean up as above.
  - Update the installed app: `make install` from the tag when the signing
    keys are on this Mac (`~/.config/networkmonitor-signing/`); otherwise
    through Sparkle, once the release is published, so the installed app
    updates itself to the notarized build.
  - Bring the website (`gh-pages` branch) up to date:
    - the docs pages: `make docs-site SITE=<site worktree>` from the tag, so they
      describe the version people can download (#334)
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
      and the speed test's included, it retakes itself, and copies the
      README's into the `main` worktree it ran from: commit those in a pull
      request into `main`.
  - `make site-audit` against the new install: every window, with real data
    in its lists, checked for what VoiceOver can't name. Fix what it finds.
  - The native review: when the release changes text in a language, post
    `make translation-review FROM=<last tag>` on the release's issue (it
    mentions the reviewer). Nothing waits on it; their changes follow there.

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
- **Every language, in the same pull request** (#428). The app's text is in
  `L("…")`, with a translation in each `Resources/Localization/<code>.lproj` table,
  and `make test` fails until a new or changed piece has one. The README, the user
  docs (`docs/zh-Hans/`) and the website (`zh/index.html`) have a Chinese copy: a
  change to the English changes the copy too, using the app's own words
  (`docs/development.md#languages`).
- **The docs change with the feature** (#334). `docs/` is the one source: the
  website's docs pages and the wiki are built from it by docs-kit (the `docs-kit`
  plugin's skill; `Scripts/docs-kit`, `.docs-kit.json`), never edited. A pull
  request that changes the app's text changes the page in `docs/` that describes
  it, in every language; `make docs-check` (CI) fails it otherwise, unless the
  description says `No docs needed: <why>` (`docs/development.md#the-docs`).
- **Each language's glossary** (`<code>.lproj/Glossary.json`) names features and
  settings; `make test` holds the app's table to it, and the docs and site use the
  same words. `make translation-check` (CI) fails a pull request that changes an
  English page but not its copy; when that's deliberate, the description says
  `No translation needed: <why>`. A new language follows
  `docs/development.md#adding-a-language`.

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
- `gh-pages` takes only pull requests that pass its `asset-check` (a ruleset,
  #426). Nothing pushes to it directly.
- A change both branches' asset checks depend on (a shot renamed, what
  `site-shots` finds) goes in order or on paired branches, `<branch>` and
  `<branch>-site` (`docs/development.md#changing-both-branches`).
- `Closes #N` closes issues only for pull requests into `main`. Close the issue
  by hand once the PR is merged.
- Merge and clean up as for `main`: without `--delete-branch`, which removes the
  worktree the branch is checked out in.
- The Settings section shows each pane as a real capture in `assets/settings/`.
- **Every image, GIF and video is listed with the window it shows** (#413):
  on the site in `shots/shots.json`, in the README and docs in
  `Resources/README/assets.json`. CI fails on one that isn't
  (`make asset-check`; `docs/development.md#every-asset-is-listed`).
- Never put "ad" or "ads" in a file name, id, class, data value or `aria-label` on the
  site (a panel labelled "Ads" was hidden whole, #392; label it with `aria-labelledby`): browser
  ad blockers hide them (#377, #384). The ad blocker's pictures and anchors are named
  after the pane's icon, `shield`, with no word a blocker might match.
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
- **Mac lanes: one at a time per shared part of the Mac (#451).** `mac-lane` (on PATH from
  the `shared-mac` plugin, kevinabouhanna/claude-parallel-sessions#3) runs work one at a time
  across every worktree, session and project, with a lane per part. Its `shared-mac` skill has
  the rules (narrowest lane, briefly; wait in the session, never launchd, `nohup`, `at` or
  `disown`). `Scripts/mac-lane.sh` is the fallback copy for GitHub's runners and anywhere
  without the plugin, and hands over to the shared one when it's there. This repo's lanes:
  - `networkmonitor`: the installed app, the filter, the helper, settings, a development
    build and `pkill`. The install, uninstall, helper, smoke-test and review-build scripts and
    `make run` take it themselves. Launch a development build through it too:
    `MAC_LANE=networkmonitor mac-lane open -W -n build/NetworkMonitor.app --args …`
    holds the lane until that copy quits.
  - `screen`: the pointer, screen captures and recordings. `site-shots` (`make
    site-check`, `site-shots`…, `build/site-shots tree`) takes both `screen` and
    `networkmonitor` itself, only while it reads or takes windows: it waits for Kevin
    to step away with the lanes free (#504).

  A busy lane waits and names its holder. Run those commands in the background so a
  wait can't time out. `mac-lane status` lists every lane, who holds it and for how long.
  Other apps' lanes (`home-control`…) don't wait on ours.
- **Stay off Kevin's two screens (#475).** Open the app with `open -g`, never a plain
  `open`, and pass `-background YES` with `-open` when only the accessibility tree is
  needed. Anything that brings a window forward or moves the real pointer waits until
  he steps away: `make site-shots` does (`MAC_LANE_IDLE=90`: no keyboard or mouse for
  90 s, or the screen locked); for your own, take `screen` with `MAC_LANE_IDLE=90`.
- **Quit and reopen the app through `Scripts/quit-and-open.sh`** (`nm_quit`,
  `nm_open`), never `pkill` and `open` straight after: launchd can keep a dead launch
  job and fail the `open` with error 37 (#508).
- **Computer use has its own lock, held until the session exits.** Check windows
  with the accessibility tree (`make site-check`, `build/site-shots tree <name>`)
  first. Use computer use only for what that can't show, from a short session that
  exits when it's done.
- **Local test servers take a port the system picks**
  (`python3 -m http.server 0 --bind 127.0.0.1`), never a fixed one.
- **Measure a power profile without unplugging:**
  `MAC_LANE=networkmonitor mac-lane open -W -n build/NetworkMonitor.app --args -powerProfile balanced`
  (or `performance`, `saver`). Only launch arguments are read, so nothing persists.
  Time CPU with `ps -o time=` on the app and its `nettop` child, in the
  foreground: `top -l` hangs when run in the background.
- **A development build shares settings and data with the installed app.** In the
  lane, quit the installed copy before running one, put back any setting you
  change, and relaunch the installed copy afterwards.
