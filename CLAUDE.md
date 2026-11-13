# NetworkMonitor

## Workflow

`~/.claude/CLAUDE.md` has the workflow: issue → pull request → merge → install, carried
through without asking. What's particular to NetworkMonitor:

- **Releases are on hold (Kevin, 11 Nov 2026, #559).** Until Kevin says to release, a
  change is done once it's merged into `main`: no tag, no release notes, no install, no
  `make site-shots` or `make site-audit`. Merging takes no pictures (local CI builds windows
  out of sight). When he says release, remove this bullet; the release takes everything
  merged since 1.30.2.
- **Releasing is routine here** (once the hold is lifted). Carry each change on to a
  release, the installed app and the website without asking.
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
    each under its check name. Its smoke test runs in a VM (`mac-vm`), so it takes no lane
    and runs while a review build is open (#528).
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
      updates the page (`docs/development.md#website-pictures`; it's product-kit's
      shots-kit, vendored as `Scripts/site-shots.swift`, the `shots-kit` skill). Rewrite the alt
      text of any picture it retook for an interface change, from the diff it
      prints, describing the interface, not its numbers. It runs in a VM, from
      the installed copy (#561): if the new version's filter asks to be allowed
      again there, remake the image (`Scripts/shots-vm-image.sh`) first.
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

## The plan

- **The plan** is `docs/PLAN.md`, with one page per phase in `docs/phases/` (Kevin,
  2026-11-13, #605). On GitHub it's one tree: the pinned root issue **#607 "The plan:
  NetworkMonitor"** (label `plan`), a **phase issue** per phase (#608–#615, the milestone's
  title, label `phase`, in its milestone, under #607; closed when the phase is done), each
  **item** a sub-issue of its phase issue, each **step** a sub-issue of its item. The board
  (https://github.com/users/kevinabouhanna/projects/4) has the **Level** (Plan, Phase, Item,
  Step, from the tree), **Order**, **Horizon** (Now, Next, Later) and rough **Start date** and
  **Target date** on each item; steps copy their item's Order and Horizon.
- **Every open issue is in the plan**, or `make plan-check` fails every pull request. A new
  issue goes in as a step of its item, or as a new item under its phase issue with an Order,
  a Horizon and dates. Tooling chores (the vendored kits, local CI, the release workflow, the
  VM image) are steps of the standing item **#606** "Keep the tooling and the plan in order".
- **Every session that changes the plan** (a new issue, a new order, a phase finished)
  changes the pages and GitHub together: the page for what was decided (each page mentions
  every open item in its phase); the issue in its place on GitHub; then
  `Scripts/docs-kit plan sync` (it makes the rest follow: sub-issues, milestones, Levels,
  steps' values, the phases' own values, #607's description, the Status lines and
  `docs/phases/README.md`; never by hand), then `Scripts/docs-kit plan check`, which must
  pass (`make plan-check`, in local CI). If it fails on something your change didn't touch (an
  item closed since), run `plan sync` and commit the pages with your change. It's
  product-kit's docs-kit, stage 1 (`.product-kit.json`'s `plan`; the `docs-kit` skill).
- **Kevin's Inbox:** what he adds between sessions (a bug, a feature, an idea, research) is a
  draft in the board's **Inbox** view, with an optional **Kind**: not an issue, not yet in the
  plan; `plan check` only mentions it. Never take an entry in unasked. When he says **"scan
  the inbox"** (or "scan the ideas"): `Scripts/docs-kit plan inbox`; work out the Kind where
  it's empty; a **Bug** starts from the app's logs (below), quoted in the issue, and is placed
  by severity (one that breaks daily use goes ahead of features, Now); a **Feature** gets a
  spec in plain words (Why, his words quoted; What; Done when); an **Idea** or **Research**
  becomes a decision issue (what to find out, how we'll decide), not a build. Fit each where
  it belongs (`--parent` for a step of an item), with what it waits for (`--blocked-by N`),
  moving others' Order when it should come first (`Scripts/docs-kit plan set <N> Order=<N>`).
  Take each in with `Scripts/docs-kit plan inbox --take <item id> --phase "<milestone>"
  --horizon <Now|Next|Later> --order <N> --body-file <spec.md>`, mention it on its phase's
  page, run `plan check`, then tell him where each went and what moved.
- **The app's logs** are in the unified log, under the subsystems
  `com.kevinabouhanna.NetworkMonitor` (the app) and `com.kevinabouhanna.NetworkMonitor.Filter`
  (the content filter): `/usr/bin/log show --last 1h --info --debug --predicate 'subsystem
  BEGINSWITH "com.kevinabouhanna.NetworkMonitor" OR process == "NetworkMonitor"'` (the full
  path: in zsh, `log` is a builtin). The app writes little of its own (lookups, the filter,
  updates, lists, history), so the process's lines from macOS (network paths, launch) often
  say more.

## Accessibility

Everything in the app must work with VoiceOver. A program catches the major
problems; the session judges the rest itself (#346, #525).

- **Checked automatically.** `make test` (so CI and the pre-push hook) builds
  every window and fails on a control with no name, a control named only by
  its SF Symbol ("Gear shape, filled"), or an image with no description that
  isn't hidden. `make site-audit` runs the same rules on the installed app,
  with real rows in its lists.
- **The keyboard too (#455), never by hand.** `make test` tours every window
  with Tab as with Keyboard navigation on, out of sight and without the
  screen: it fails on a stop VoiceOver can't name, a control that is two
  stops, a control Tab never reaches, and checks the sidebar's ↑ ↓, a
  switch's ← → and search's ⌘F and Escape. `make design-shots KEYBOARD=1`
  prints the tour of every window with rows in its lists: read it rather
  than asking Kevin to Tab through. A new window or pane goes into
  `KeyboardTests.swift`; a control that is one stop (a switch, a list the
  arrows move through) takes its parts out of Tab with `.focusable(false)`.
- **How to pass.** Name icon-only buttons and unlabelled switches and fields
  with `.accessibilityLabel` in plain words (what it does: "Settings", "Next",
  "Expand"). Hide an icon beside its own name with `.accessibilityHidden(true)`.
  A new window or pane goes into `AccessibilityTests.swift`.
- **Judge the rest yourself, never with a checklist for Kevin.** Kevin
  (13 Nov 2026, #525): "you do the test. I don't want to do it manually; I
  don't even know how. And if there's something blocking you, postpone it
  until later." When a change adds or reshapes the interface, check what
  VoiceOver will read and what the keyboard does yourself: the accessibility
  tree (`build/site-shots tree <name>`), the keyboard tour (`make design-shots
  KEYBOARD=1`), and in a VM (`mac-vm`: Keyboard navigation on, the Dock, the
  menu bar, real clicks and keys, read with Accessibility over `mac-vm ssh`).
  Decide whether a name makes sense to someone who can't see the screen,
  whether the order reads well, whether it can all be reached; fix what
  doesn't, and hold it with a test where one can. What truly can't be checked
  here goes to a later item in the plan with what was tried, never into a
  question for him.

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
  website's docs pages and the wiki are built from it by docs-kit (the `product-kit`
  plugin's `docs-kit` skill; `Scripts/docs-kit`, `.product-kit.json`), never edited. A pull
  request that changes the app's text changes the page in `docs/` that describes
  it, in every language; `make docs-check` (CI) fails it otherwise, unless the
  description says `No docs needed: <why>` (`docs/development.md#the-docs`).
- **Each language's glossary** (`<code>.lproj/Glossary.json`) names features and
  settings; `make test` holds the app's table to it (lang-kit: the `product-kit`
  plugin's `lang-kit` skill; `Scripts/lang-kit`, `lang` in `.product-kit.json`), and the docs and site use the
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
    build and `pkill`. The install, uninstall, helper and review-build scripts (the smoke test only outside a VM) and
    `make run` take it themselves. Launch a development build through it too:
    `MAC_LANE=networkmonitor mac-lane open -W -n build/NetworkMonitor.app --args …`
    holds the lane until that copy quits.
  - `screen`: the pointer, screen captures and recordings. `site-shots` with `HERE=1`
    takes both `screen` and `networkmonitor` itself, only while it reads or takes windows
    (#504); in its VM, the default, it takes neither.

  A busy lane waits and names its holder. Run those commands in the background so a
  wait can't time out. `mac-lane status` lists every lane, who holds it and for how long.
  Other apps' lanes (`home-control`…) don't wait on ours.
- **Stay off Kevin's two screens (#475,
  kevinabouhanna/claude-parallel-sessions#62).** Testing the app — anything that shows its
  windows: launching a build to look at it, UI checks, reading windows' trees, pictures,
  smoke tests with windows — runs in a VM (`mac-vm`, the shared-mac skill), not on his Mac.
  `open -g` and `-background YES` keep focus but the windows still appear on his screens
  (Kevin, 11 Nov 2026: a NetworkMonitor window every few seconds while pictures were taken;
  "I cannot use the computer"). On this Mac: installing and relaunching his own copy, and
  work that opens no windows.
  - `site-shots` (`make site-check`, `site-shots`, `site-trees`, `site-audit`) runs in a VM
    (#561): run it any time, in the background (a few minutes; one VM run per site at a time).
    Its image, `claude-image-networkmonitor`, has the app's approvals; after a macOS update of
    the golden image, or when a new version's filter asks to be allowed again, remake it with
    `Scripts/shots-vm-image.sh` (`docs/development.md#website-pictures`). `HERE=1` uses this
    Mac's screen instead: only while the Mac is idle, waiting silently
    (`MAC_LANE=screen MAC_LANE_IDLE=90 mac-lane make site-check HERE=1`), and never hold a
    release or a review on it.
  - Never ask Kevin to step away, in a notification or in chat (#521,
    kevinabouhanna/claude-parallel-sessions#27): he keeps using the Mac.
- **Quit and reopen the app through `Scripts/quit-and-open.sh`** (`nm_quit`,
  `nm_open`), never `pkill` and `open` straight after: launchd can keep a dead launch
  job and fail the `open` with error 37 (#508).
- **Computer use goes to a VM** (`mac-vm`'s look/vnc loop, the shared-mac skill): a clone
  with the app copied in, its own screen and pointer. Claude Code's computer-use tool drives
  Kevin's screen: only for what a VM can't do, from a short session, while the Mac is idle.
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
