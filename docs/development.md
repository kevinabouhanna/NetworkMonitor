# Building, testing and releasing

## Requirements

- **To run:** macOS 13 or later, Apple silicon or Intel.
- **To build:** Apple's **Command Line Tools** (`xcode-select --install`). Xcode and a
  developer account aren't needed, though everything works under Xcode too. Notarizing,
  which only a Developer ID build needs, uses `notarytool` and `stapler`, which come with
  Xcode.
- **Swift:** a Swift 6 toolchain. `Package.swift` declares tools version 5.9 on
  purpose, which keeps the Swift 5 language mode, so the package builds without Swift 6
  strict-concurrency annotations.
- **One dependency: Sparkle** (#132), pinned to an exact release in `Package.swift` and
  fetched by SwiftPM with its checksum. Usage History uses the system's own SQLite.
- `make dmg` also needs `python3` (part of the Command Line Tools) and network access the
  first time, to install `dmgbuild` into `.build/dmgbuild-venv`. Nothing is added to the
  system Python.

## Quick start

```sh
git clone https://github.com/kevinabouhanna/NetworkMonitor.git
cd NetworkMonitor
make hooks   # once per clone: run the tests before every push
make test    # run the suite
make run     # build build/NetworkMonitor.app and open it
```

> [!IMPORTANT]
> A development build has the same bundle identifier as the installed app, so it
> **shares its settings and data**. Quit the installed copy before running one, put back
> any setting you change, and relaunch the installed copy afterwards.

## Make targets

| Target | What it does |
|---|---|
| `make test` | Runs the test suite |
| `make build` | Debug build of the package |
| `make app` | Release build of `build/NetworkMonitor.app` for this Mac's architecture, signed (see step 4 below), with the helper inside |
| `make universal` | The same, for arm64 and x86_64 |
| `make dmg` | `universal`, then `build/NetworkMonitor.dmg` |
| `make run` | `app`, then quit any running copy and open the new one |
| `make install` | Builds, notarizes it when it carries the content filter (the login keychain must be unlocked), copies to /Applications, and lets the app register itself to start at login |
| `make install-only` | The same without starting at login |
| `make update` | `git pull --ff-only`, the tests, then `install`. Tests first, so a bad pull can't replace a working copy |
| `make uninstall` | `Scripts/uninstall.sh` (see below) |
| `make helper` | Installs the `sudo` helper by hand, with its hourly self-check, for builds without a Developer ID. Asks for your password |
| `make helper-no-daemon` | The same without the hourly self-check |
| `make metering-report` | Prints what Hotspot mode reaches on this Mac, pending update downloads and the Low Data Mode state. Read-only, safe beside a running copy |
| `make icon` | Redraws `Resources/AppIcon.icns` from `Scripts/make-icon.swift` |
| `make public-suffixes` | Regenerates `Sources/FirewallPolicy/PublicSuffixes.swift` from the Public Suffix List (#318), which tells a name's site. Committed too; refresh it now and then in a pull request of its own |
| `make geodata` | Rebuilds `Resources/Geo` from DB-IP's current month. The files are committed, because DB-IP removes old months; refresh them in a pull request of their own |
| `make dmg-background` | Redraws the disk image background |
| `make site-check` | Says which of the website's pictures show a window whose interface changed (below) |
| `make site-shots` | Retakes those pictures, or the ones in `NAMES`, and updates the page |
| `make site-trees NAMES=…` | Records those windows' trees as they read now, without retaking their pictures, after marking more of them as data (below) |
| `make asset-check` | Fails on any image, GIF or video the site, README or docs use that isn't listed with the window it shows (below) |
| `make translation-check` | Fails when this branch changes an English page for people using the app but not its translation ([Languages](#languages)) |
| `make translation-review FROM=vX.Y.Z` | The text added or changed since that release in each language, as a table for its native reviewer ([Adding a language](#adding-a-language)) |
| `make site-audit` | Checks the installed app's windows, with real data, for what VoiceOver can't name |
| `make hooks` | Points git at `Scripts/hooks`, so `pre-push` runs the tests |
| `make clean` | Removes `.build` and `build` |

## Command Line Tools quirks

Two things in the Command Line Tools 27 shape the code:

- **SwiftUI's `@State` is a macro** in the macOS 27 SDK, and its implementation ships only
  with Xcode, so `@State` doesn't compile ("plugin for module 'SwiftUIMacros' not
  found"). View state lives in small `ObservableObject`s with `@Published` instead; see
  `SettingsPaneState`.
- **Swift 6.4's default `swiftbuild` build system** fails before compiling anything
  ("Unknown error parsing property list"). Every build goes through `Scripts/swiftpm.sh`,
  which asks for the native build system. SwiftPM prints a deprecation warning about it on
  every run; that's expected. Drop the wrapper once `swiftbuild` works with the Command
  Line Tools.

## Package layout

| Target | Kind | What's in it |
|---|---|---|
| `NetworkMonitorCore` | library | Almost everything: measurement, attribution, storage, Hotspot mode, speed test, all the SwiftUI views |
| `NetworkMonitor` | executable | A thin shell: `main.swift` and `AppDelegate.swift` (status item, popover, menus, the main window, lifecycle) |
| `LowDataMode` | library | Interface flags, the helper's report, and `HelperProtocol.version`, shared by the app and the helper so the two can't disagree |
| `HostsFile` | library | `/etc/hosts` editing, shared by the helper and the tests |
| `ServerDirectory` | library | Which country an address is in and whose network it belongs to, from `Resources/Geo`. Pure Foundation, so the content filter can use it without the app's frameworks |
| `GeoDataBuilder` | executable | Converts DB-IP's CSVs into `Resources/Geo`. Run by `make geodata`, never part of the app |
| `MapDataBuilder` | executable | Converts Natural Earth's countries into `Resources/Geo/world.bin`, the Connections map. Run by `Scripts/mapdata.sh`, never part of the app |
| `FilterProtocol` | library | What the app and its content filter agree on: identities, the XPC interfaces, `FlowReport`. Foundation only |
| `FirewallPolicy` | library | What may connect (#114): the rules, the mode and the decision, for the app that keeps them and the filter that applies them. Foundation only |
| `NetworkMonitorFilter` | executable | The content filter, a Network Extension system extension (#128). In the bundle only for Developer ID builds |
| `NetworkMonitorHelper` | executable | The root helper. Links only `LowDataMode` and `HostsFile`, never Core: a root binary shouldn't carry a menu bar app's dependencies |
| `NetworkMonitorTests` | executable | The test suite |

Tested internals are `public` rather than reached with `@testable import`, which compiled
in debug but broke `make app`.

[Architecture](architecture.md) explains how the parts fit together.

## Tests

`make test` runs `NetworkMonitorTests`, a plain executable rather than `swift test`,
because neither XCTest nor swift-testing ships with the Command Line Tools. It has a small
harness (`Harness.swift`): `Check.suite`, `Check.test`, `expectEqual` and friends, named
after XCTest so moving to a real test target later is a rename. It prints a line per test
and exits non-zero if anything fails.

- **The asset check's cases.** `make test` also runs `build/site-shots coverage-test`:
  made-up pages that put a picture in each place [the asset check](#every-asset-is-listed)
  must find it (#425).
- **The CI fallback's decisions.** `make test` also runs `Scripts/tests/local-ci-test.sh`:
  `Scripts/local-ci.sh --fallback` against a stand-in `gh` that answers from files in
  `Scripts/tests/local-ci/`, one folder per case, with GitHub's own billing texts (#461). It
  checks only which way the script decides: GitHub passed or failed, so report that; or a
  billing or spending-limit error, a job still queued after the start window, or no checks
  at all, so run both jobs here. Nothing is built or fetched, and it takes seconds.
- **Live tests**, which need a real network and a real `nettop`, are skipped when `CI` is
  set. Run them anyway with `NETMON_LIVE_TESTS=1`. They include guards such as "the stream
  stays under 25% of a core" and "changing the interval leaves exactly one `nettop`".
- **The speed test is never run for real** in the suite: each real run costs 50–500 MB.
  It runs against a stand-in `networkQuality` script; see [speed test](speed-test.md).
- **Popover layout constants** are pinned by tests calibrated against what SwiftUI
  actually lays out.
- **Accessibility** (#346): `AccessibilityTests.swift` builds the main window's sidebar,
  every section and settings page, and the popover, out of sight, and reads each
  one's accessibility tree through the Accessibility API, as VoiceOver does
  (`AccessibilityAudit`). A control with no name, a control named only by its SF Symbol, or
  an image with no description that isn't hidden fails the test. A first test checks the
  check itself on a window with each problem in it. The windows are built with empty data,
  so `make site-audit` runs the same rules against the installed app, with real list rows.
  What a program can't judge is asked of Kevin (see CLAUDE.md).

## How the app is built

There's no Xcode project. `Scripts/bundle.sh` assembles the bundle by hand, because
`LSUIElement` (menu bar only, no Dock icon) only works from a real `Contents/Info.plist`:

1. **Version stamping.** `CFBundleShortVersionString` is the latest git tag;
   `CFBundleVersion` is the commit count, which only ever increases (an updater compares
   it). Both are stamped into the plist before signing, and `MARKETING_VERSION` and
   `BUILD_NUMBER` override them. Any CI checkout that bundles needs `fetch-depth: 0`, or
   every build is number 1.
2. **Release build** of the app and the helper. A universal build compiles each
   architecture in its own scratch directory and joins them with `lipo`, because the
   one-step `--arch arm64 --arch x86_64` needs Xcode's build system. The helper is
   universal too, since it's installed from inside the bundle on whatever Mac runs it.
3. **Layout:** the app binary, `Info.plist`, the icon, the helper in
   `Contents/Library/LaunchServices/`, `helper-setup.sh` in `Resources`, the country and
   map data in `Resources/Geo`, and `Sparkle.framework` in `Contents/Frameworks`, without
   its XPC services, which only sandboxed apps need.
4. **Signing**, inside out and without `--deep`: the helper first, with its own
   identifier, then the app. `--deep` re-signed the helper with an identifier guessed from
   its file name, which was the app's. `Scripts/signing.sh` chooses what with, the first
   of these that's there:
   - **The Developer ID** (issue #119): `SIGN_IDENTITY` for an identity already in a
     keychain, or the `.p12` in `DEVID_P12` and its password in `DEVID_P12_PASSWORD`, by
     default `~/.config/networkmonitor-signing/developer-id.p12` and
     `developer-id.password`. Both get the hardened runtime and a timestamp, and the app
     gets `Resources/NetworkMonitor.entitlements`, whose one entitlement is Location for
     Wi-Fi names (#85). Running `nettop`, and AppleScript's `do shell script` for the
     helper's prompt, were checked to need nothing. Offline there's no timestamp: the
     build is signed without one and says it can't be notarized.
   - **NetworkMonitor's own certificate** (issue #86): the `.p12` in `SIGNING_P12` and
     its password in `SIGNING_P12_PASSWORD`, or `signing.p12` and `password` in the same
     folder. It's self-signed, so Gatekeeper asks for Open Anyway, but every build has the
     same designated requirement, so macOS keeps Location across updates.
   - **Ad-hoc**, without either: forks and pull request CI. Each build is a new app to macOS.

   A `.p12` is imported into a throwaway keychain, deleted afterwards, so the key never
   sits in the login keychain and nothing prompts.
   Sparkle's pieces are re-signed inside out with whichever of these the build uses.

   With the Developer ID, `bundle.sh` also adds the helper daemon's plist
   (`Contents/Library/LaunchDaemons/com.kevinabouhanna.NetworkMonitor.daemon.plist`, #131)
   and Sparkle's feed and public key to `Info.plist` (#132), and assembles the content
   filter's bundle
   (`Contents/Library/SystemExtensions/com.kevinabouhanna.NetworkMonitor.Filter.systemextension`),
   embeds the two provisioning profiles from `Resources/Profiles/`, which grant its
   entitlements and ship in every copy, and signs the filter, the helper and the app inside
   out. The app then uses `Resources/NetworkMonitor+Filter.entitlements`. The country and
   owner tables move into the filter, which needs them, and the app links to them there. The
   filter's XPC service is named after the build (#142). Without the Developer ID or the
   profiles, the filter is left out and nothing else changes.

   macOS only activates a system extension from a notarized app, and the helper daemon and
   Sparkle need one too, so try them with `make install`, which notarizes.
5. **Notarizing**, with `Scripts/notarize.sh <app or dmg>`: submits to Apple, waits, and
   staples the ticket. It uses the API key in `NOTARY_KEY`, `NOTARY_KEY_ID` and
   `NOTARY_ISSUER` if set, or else the keychain profile `networkmonitor`, saved once with
   `xcrun notarytool store-credentials networkmonitor --key … --key-id … --issuer …`.
   `NOTARIZE=1 make dmg` notarizes the app before packaging it, then the disk image.

`Scripts/make-dmg.sh` packages the app with `dmgbuild` (`Scripts/dmg-settings.py`): an
LZFSE-compressed image with the app, an `Applications` link and a light background. The
background is light on purpose: Finder draws icon labels black over a background picture
even in dark mode. The file name has no version, so
`releases/latest/download/NetworkMonitor.dmg` always works; the website links to it.

## Other scripts

- `Scripts/install.sh` builds, copies to `/Applications`, strips the quarantine flag, and
  opens the app, which registers itself to start at login. `--no-login` skips that.
- `Scripts/uninstall.sh` quits the app and any `nettop` it left, puts back what Hotspot
  mode changed, removes the helper (with `sudo`, so it asks for your password), withdraws
  the login item and the helper daemon, and removes the app. Unlike the in-app Uninstall,
  it **keeps your usage data** unless you pass `--purge`.
- `Scripts/install-helper.sh` installs the helper for development, through the same
  `helper-setup.sh` the app uses.
- `Scripts/smoke-test.sh` launches the built app and fails if it isn't still running five
  seconds later. Deliberately shallow: a crash on launch is the one bug an auto-updater
  would ship to everyone.
- `Scripts/appcast.sh` and `Scripts/ed25519-sign.swift` sign a release's disk image with the
  update key and write its appcast (#132). `Scripts/geodata.sh` and `GeoDataBuilder package`
  convert and sign a month of country data (#121).

## CI

`.github/workflows/ci.yml` runs on every push to `main` and every pull request. Both jobs
must be green before a merge.

- **`build-and-test`:** on a pull request, `make translation-check` first; then build,
  `make test` (live tests skipped), `make asset-check`, `make app`, checks on the bundle
  (signature, plist, icon), and the smoke test.
- **`universal`:** `make universal`, and checks that both architectures are there.

**When GitHub can't run it** (a billing or spending-limit error, or no runner for 15 minutes),
`Scripts/local-ci.sh --fallback <pr>` runs the same two jobs on this Mac (#456). It records
each result on the commit under the same name, so a pull request reads the same either way.
- It watches GitHub's checks first, and doesn't run anything here when GitHub can do it.
- Without `--fallback`, it runs here straight away.
- `CI_START_MINUTES` (15) sets how long it waits for GitHub to start; `CI_START_SECONDS`,
  `CI_POLL_SECONDS` and `LOCAL_CI_DECIDE_ONLY=1` are for its tests (see [Tests](#tests)).
- Builds reuse one worktree in `~/Library/Caches/networkmonitor-dev/ci`, one run at a time.
- The smoke test runs in the `networkmonitor` Mac lane, and opens the installed copy again
  afterwards.

Releases stay on GitHub. The keys they're signed with are repository secrets.

## Contributing

Every change follows the same path:

1. **An issue** that says what and why. Keep its description current: it's the record of
   what was decided.
2. **A pull request** from a branch named after the issue (for example `settings-v2-9`),
   with `Closes #N` in its description. CI must be green. Squash-merge. Nothing is pushed
   to `main` directly.
3. **A release** once it's merged (below), unless the change is to the website or docs
   only.

## Working in parallel

Several Claude Code sessions often work here at once (#342). Files and the Mac itself
are kept apart differently:

- **Files: a worktree each.** A session works in `.claude/worktrees/<branch>`, made with
  `EnterWorktree` or `claude -w <branch>`. `.claude/hooks/worktree-create.sh` puts it on
  branch `<branch>`, from a freshly fetched `origin/main`. The main checkout stays on
  `main` and is never edited: `.claude/hooks/require-worktree.sh` refuses edits there,
  and `git checkout` or `git switch`, until the session has entered a worktree, and from
  then on Claude Code keeps the session out of the main checkout itself. Each worktree
  builds into its own `.build/` and `build/`.
- **The Mac itself: one at a time, in Mac lanes (#342, #451).** A worktree doesn't keep
  these apart:
  - the one app in /Applications, its content filter and helper daemon;
  - its settings (which a development build shares);
  - a `pkill` that stops every copy of the app;
  - the pointer and the screen.

  `Scripts/mac-lane.sh` runs whatever touches those one at a time, across every worktree,
  session and project, with one lane per shared part:
  - **`networkmonitor`**: the app, filter, helper and settings. `install.sh`,
    `uninstall.sh`, `install-helper.sh`, `smoke-test.sh`, `review-build.sh` and `make run`
    take it themselves.
  - **`screen`**: the pointer, screen captures and recordings. `make site-check` and
    `make site-shots` take it as well as `networkmonitor`.

  Other projects have their own app lanes (`home-control`), so a review build here
  doesn't hold up their installs. A second caller waits, and is told who holds the lane
  and for how long. The lock is the kernel's, so it goes when its holder dies.
  `Scripts/mac-lane.sh status` lists every lane. `install.sh` builds and notarizes before
  taking the lane, so the lane is held only for stopping, copying and starting the app.
- **Ports.** Local test servers take a port the system picks (see
  [Launch arguments](#launch-arguments)).
- **Overlaps.** [Worktrunk](https://worktrunk.dev)'s `wt list` (`brew install worktrunk`)
  lists every worktree with its changes, and marks with ✗ one whose changes would
  conflict with `main`. Once one branch merges, the others it overlaps show it.

## Releasing

1. Write the version's **What's new** in `ReleaseNotes/X.Y.Z.md` and merge it like any
   change. It's Markdown: short bullets, each with a bold lead and its issue, and no
   `]]>`. Sparkle shows it in the update window, carried in the appcast (#152) with the
   nine versions before it, as HTML from `Scripts/release-notes.swift`. Each version is
   a `<div data-sparkle-version="BUILD">`, and Sparkle hides the installed one and
   everything older, so a reader several versions behind sees each version they missed
   (#163). The workflow puts this version's file alone in the release notes, under
   **What's new in X.Y.Z**. A tag without it fails in the first seconds.
2. Tag `main` and push the tag: `git tag vX.Y.Z && git push origin vX.Y.Z`.
3. The **Release** workflow (`.github/workflows/release.yml`) runs the tests, builds the
   universal DMG with the tag's version, checks the version, the helper, the content filter
   and the signature, signs the update and writes the appcast with `SPARKLE_ED_KEY`, and
   publishes `NetworkMonitor.dmg` and `appcast.xml` with install and update instructions.
   It signs with the Developer ID in the repository secrets `DEVID_P12_BASE64` and
   `DEVID_P12_PASSWORD`, notarizes with the API key in `NOTARY_KEY_BASE64`,
   `NOTARY_KEY_ID` and `NOTARY_ISSUER`, and fails without them. It then checks the team
   (`GRQKG7M8CL`), the Location entitlement, and that `spctl` accepts both the app and
   the disk image as *Notarized Developer ID*.
4. Install it with `make install` from the tag.
5. Update the website (below), including `make site-shots` against the new install.
6. **The native review**, when the release changes text in a language (#434). Post
   `make translation-review FROM=<the last release's tag>` on the release's issue, or on
   the pull request with its release notes. It's a table of each language's new and
   changed text, English beside the translation, with the language's reviewer (its
   glossary's `reviewer`) mentioned. They read it in the updated app; their changes
   follow on that issue, in a pull request of their own. Nothing waits on the review.

The keys behind these secrets are never committed. The update key's public half is
`SUPublicEDKey` in `bundle.sh`, and the data key's is `GeoDataUpdater.publicKey`; the
*Data refresh* workflow signs with `GEODATA_SIGNING_KEY`. The Developer ID certificate is
valid until 28 November 2027. The provisioning profiles name it, so they're renewed with it.

## The website

[kevinabouhanna.github.io/NetworkMonitor](https://kevinabouhanna.github.io/NetworkMonitor/)
is a static page on the **`gh-pages`** branch, conveniently checked out as a worktree
beside the main checkout. Changes to it get an issue and a pull request against
`gh-pages`, but no release.

- `Closes #N` only closes issues for pull requests into `main`, so close the issue by hand.
- Don't merge with `gh pr merge --delete-branch` while the branch is checked out in the
  worktree: `gh` removes the worktree along with it.
- After each release, update the hero's version, the download line's version and DMG
  size (in 1024-based MB), and the "What's in version" link, and run `make site-shots`
  (below).
- **Every image is a real capture of the app**, never a mock-up. The Settings section
  shows each pane as a capture in `assets/settings/`, with the window's size in points on
  each `<img>` and clickable areas placed in the same points.
- **No "ad" or "ads" in a file, id, class, data value or `aria-label`** on the page (#377,
  #392). A panel labelled `aria-label="Ads"` was hidden whole by `##div[aria-label="Ads"]`;
  it's `aria-labelledby` its tab now. Browser ad
  blockers hide and block by those names, so the Ads pane's picture went missing for a
  visitor running one (AdGuard, #377). The feature's
  pictures and anchors are named after the pane's icon, `shield`, with no word a blocker
  might match (#384).
- Alt text describes the interface, not the figures in it ("how many were blocked
  today", not "3,356"), so a retake with new numbers doesn't make it wrong.

### Website pictures

`Scripts/site-shots.swift` keeps the pictures of the app current (#329), so nobody has to
notice that one went stale. `gh-pages` lists them in `shots/shots.json`: for each one,
the launch arguments that open its window, anything to click first, which parts of the
window are data, an optional crop, and the clickable areas laid over it on the page.

For each picture it opens the **installed** app, and reads the window's accessibility
tree: each element's role, labels and size. Numbers, dates, settings' values, scroll bars
and the regions marked as data are masked. If that tree differs from the one recorded
with the picture (`shots/trees/<name>.txt`), the interface changed, and the diff says how.
New numbers, a longer list or a switch turned off change nothing. Because the check reads
the tree rather than looking at the picture, it costs nothing to run and never tires.

**The look too** (#423). A change only to how something looks (a colour, an icon,
spacing, a font) leaves the tree the same, so each picture also keeps its look:
`shots/trees/<name>.look`, a thumbnail 128 cells along the picture's longer side, each
cell's average colour at five bits a channel. Cells over anything the tree masks (data
regions, a number, a setting's value, an ignored line, a scroll bar) are left out
(`----`). `site-check` takes a fresh capture, masks it the same way, and names the
windows where more than one cell differs by more than one level in a channel, or whose
size changed.

- **Advice, not a failure.** It's listed after the tree's changes and doesn't change
  `site-check`'s exit status, and `update` doesn't retake a window for it: look at
  the two, and retake the ones that changed with `make site-shots NAMES=…`. Pixels
  follow things the app doesn't (the wallpaper behind a translucent sidebar, the
  screen a window is on), which a few hours' captures on one Mac can't rule out.
- **How it was tuned** (#423): fresh captures of all fourteen windows, in English and
  Chinese, against pictures taken hours before on the same Mac, Ethernet both times:
  no cell differed. A red 8-point square over a sidebar icon changed 2 cells, a
  16-point one 6, the lower half of Network moved down 2 points about 120, a faint
  blue wash over one row about 230. With 64 cells and four bits, a 2-point move went
  unseen.
- `update` keeps each picture's look as it retakes it. `make site-trees NAMES=…` keeps
  it from the picture as it is, with the window's masks as it lays out now, without
  retaking it (and says so when the picture's size no longer matches).
- Only a shot with a picture has a look: not `menubar` or `popover`, which are
  checked by their trees alone.

```sh
make site-check                         # what changed; exits 1 if anything did
make site-shots                         # retake what changed, update index.html
make site-shots NAMES="settings-ads"    # retake these whether or not they changed
```

`site-shots` retakes each changed window with ScreenCaptureKit, at 2x and active, and
records its new tree. It then updates the page: each picture's `width`, `height`,
`data-w` and `data-h`; the `--x`, `--y`, `--w` and `--h` of the areas over it, from the
elements' positions; and a `?v=` with a hash of each asset's contents on every asset link,
so a browser never pairs a new page with a picture it kept from the last one. About is
retaken every time, since it shows the version.

An entry can set the window up before it's read and taken (#360): `click` (a button is
pressed through accessibility, anything else with the pointer), `scroll` a list to its
end, and `waitFor` an element, such as a speed test's *Test Again*. Specs can be scoped,
`AXOpaqueProviderGroup>AXButton` for the popover's first row that opens. `Role:~text` matches text anywhere in a label, for a line that starts with a number. Numbers are masked with their unit, so a total in MB one day and GB the next reads the same (#374). `ignore` leaves
out lines that come and go with the Mac's state, such as Hotspot's "already in Low Data
Mode". The popover opens on the Retina screen (`-popoverScreen retina`), since on a 1x
main screen it would be captured at half resolution.

The speed test result costs 70–200 MB to take, so its entry has `when: popover`: it's
retaken only when the popover's tree differs from the one it was last taken with (kept in
`shots/trees/<name>.base.txt`), or when named, and a check never runs it.
It's skipped on a hotspot (`skipIf`), where the app asks before spending the data, and
tried again on the next update.

Each tree is read once it has settled (the same twice in a row), since lists and charts
fill in a moment after a window opens, and a window that doesn't show is tried once more
from a fresh launch. Containers keep their height only: a scroll bar that comes with a
longer list narrows each of them.

**Every language** (#431). `shots.json`'s `languages` lists the site's other pages:
each one's code, page (`zh/index.html`) and pictures folder (`assets/zh-Hans/`). Each
shot is taken again in each language, from the app launched with `-language`, into that
folder, for that page, with its trees in `shots/trees/<code>/`. The entries name their
elements once, in English: the tool translates each label with the app's own table, and a
language's `specs` says what the table can't, such as the start of a longer line. A run
names any label it couldn't translate. `--language zh-Hans` (or `en`) takes one language
only; `--app` takes them from another copy of the app, such as a development build of a
version not released yet.

**The README's pictures too** (#434). A picture in the README or the docs that is a
shot's picture is listed in `Resources/README/assets.json` with `copy` and the shot's
name, once, in English. Each time `site-shots` retakes that shot, it copies the
picture into the checkout it runs from: the English one to the listed file, and each
language's to the same folder under the language's code (`Resources/README/zh-Hans/`).
A language's copy needn't be listed; it's made once a page uses it.
`build/site-shots readme --site <site>` copies them all, from files only.
So one run changes two branches: the site's pictures on `gh-pages`, and the README's
on the `main` worktree it ran from. Each goes in its own pull request.

#### Every asset is listed

Every image, GIF and video that the site, the README, `SECURITY.md` and `docs/` use
must be listed, so none can go stale unnoticed (#413). `make asset-check` finds them all
in the pages, and fails on any that isn't one of these. It looks wherever a page can use
one (#425):

- **On the site:** every page, in folders too (not `shots/`, hidden folders or another
  checkout inside it); its stylesheets, inline and `.css`; and its scripts, inline and
  `.js`, for a path to `assets/` written whole. Attributes, `srcset`, `url(…)`, and the
  social preview in `<meta>` tags.
- **In the README, `SECURITY.md` and `docs/`:** each language's README and every page in
  `docs/`, however deep. `src`, `poster`, `srcset` (a `<picture>`'s `<source>` too), and
  Markdown images, inline or by reference (`![alt][ref]` with `[ref]: path`). Not in code.

Each must be one of these:

- **A picture this tool takes:** a shot's `file`.
- **Copied from a shot's picture:** a README or docs picture listed with `copy`
  (above), and each language's copy of it.
- **Made by hand from the app's windows:** videos, GIFs, the social image, the README's
  other pictures. Each is listed under `assets` with the shots whose windows it `shows`:
  - in `shots/shots.json` on `gh-pages`, for the site's;
  - in `Resources/README/assets.json` on `main`, for the README's and the docs'.
- **Showing no window this tool can check:** listed with `none` and why. Icons, the disk
  image's window.

The menu bar readout is a shot with no picture of its own, `menubar` (#424), so the
strip made by hand (`assets/menubar.png`) `shows` it. Its window is `AXMenuBarItem`,
the status item: the tree keeps its name, the rates as VoiceOver reads them ("Download
# ‹unit›, upload # ‹unit›") and its width, which is the same in bits or bytes, so a new
layout or a new line in it is named. A new colour or arrow at the same width isn't.

It also fails on an entry that nothing uses, a file that doesn't exist, or a window that
isn't a shot. CI runs it on every pull request into `main` and into `gh-pages`. So a new
section's picture, or a GIF of a feature, can't merge without saying which window it
shows, and which version of the app it was made from:

```json
{ "file": "assets/hotspot.gif", "shows": ["main-network", "popover"], "made": "1.28.1" }
```

**Check `shows` frame by frame** (#422). The check trusts the list: a window left out
is never compared, so a change to it never names the asset. Before listing an asset, or
after remaking one, step through it and name every window any frame shows, a sheet, a
section or a list opened in it included. A pull request that adds or remakes one says
it was checked (the pull request template asks).

**`made`: the version it was made from** (#421). Every entry with `shows` needs it.
Each window's record has a version too: `shots/trees/versions.json` gives, for each
tree file, the version of the app it was taken from. `site-shots` keeps a record's
version while its tree stays the same, and sets the installed app's when it changes.
The check fails on an asset made from a version older than the record of a window it
shows. That record is `<name>.made.txt` when there is one (the tree what's made by hand
was last remade from), the window's own tree otherwise. So an asset already out of
date the day it's listed fails, where a comparison of trees alone would pass it.

- **Remade it?** Set `made` to the version it was made from.
- **Can't remake it yet?** Set `stale` to the issue its remake waits on
  (`"stale": "#458"`). The check names it, and passes. Once the asset is remade and
  `made` is as new as its windows, `stale` has to come out.
- **A window known to look the same in an earlier version** can have that version in
  `versions.json`, written by hand, when the release notes show it didn't change.

When one of those windows changes, `site-check` names everything made by hand from it,
on either branch, until it's remade:

- **The reminder stays after a retake.** Retaking the window's own picture doesn't end
  it. The tree each was made from is kept in `shots/trees/<name>.made.txt`.
- **To end it:** remake them, set their `made`, then run `make site-shots NAMES=<window>`.
  That records the window as it is today, for everything made by hand from it, so
  anything left unremade fails the check, unless it's marked `stale`.

Rewrite the alt text of any picture whose interface changed.

- It needs Accessibility and Screen Recording for the terminal it runs in. It quits and
  relaunches the app, clicks with the pointer when an entry says so, and leaves the app
  running as it found it.
- One run at a time: a second one, from another terminal or session, stops at once
  rather than relaunching the app under the first. Don't install a new version during
  a run either.
- A value that follows the Mac's state, not the interface (a time, plugged in or on
  battery, on a hotspot or not), is marked as data with `skip: 1` on the label beside it.
  A line that comes and goes with it is left out with `ignore`, or, where what comes
  and goes can't be named, covered by a region with `optional: true`: it may be
  empty, and only that it's there is kept. The Mac's connection is one (#416): the
  popover's Network button and the lines that can show under it ("Not using …", an
  update that got through); in Network the "Right now" row, the note under it, and
  the status lines at the end of Hotspots ("Low Data Mode is on"). So a check on
  Wi-Fi or a hotspot reads the same as one on Ethernet.
- **After adding a mark**, record the trees again without retaking the pictures:
  `make site-trees NAMES="popover-subprocesses main-network"`. The diff it prints
  should be only what the new marks cover. What's made by hand stays flagged if it was
  already, and a `when` shot named with its base (`popover speed-test-result`) records
  only that it was taken with the base as it reads now, without running.
- It must run against the installed, notarized app: a development build shows different
  rows, since it has no content filter or helper.
- To add a picture, write its entry, look at `build/site-shots tree <name>` to mark the
  data regions, and run `make site-shots NAMES=<name>`. To add one made by hand, list it
  under `assets` (above); `make asset-check` says if anything is missing.
- **Videos.** Real behaviour, like `live.mp4`, is a screen recording of the app. Designed
  videos, like the hero, are made with Hyperframes (`/hyperframes`) or `/brag`, which is
  built on it, or Remotion when it suits; all three are installed as Claude Code skills.

## The wiki

The [wiki](https://github.com/kevinabouhanna/NetworkMonitor/wiki) is a copy of `docs/` and
`SECURITY.md`, made by `Scripts/wiki.py` (#177). The **Wiki** workflow
(`.github/workflows/wiki.yml`) rebuilds it whenever they change on `main`, so change the
docs here, never the wiki.

- A page comes and goes with its doc, and the sidebar follows the tables in
  `docs/README.md`.
- Links are rewritten for the wiki, and images point at the commit that was copied.
- Only files git tracks are copied, so the private notes git ignores in `docs/` stay
  private.
- To rebuild it by hand, run the workflow from the Actions tab, or
  `python3 Scripts/wiki.py <wiki checkout>` and push.

## Languages

The app opens in the Mac's language when it has a table for it, and English
otherwise; Settings › Language chooses one for the app alone (#433). The
choice is the app's own `AppleLanguages`, the setting System Settings › General ›
Language & Region › Applications writes, so the two are one setting.

- **Text goes through `L("…")`.** Every piece of text the interface shows, VoiceOver's
  included, is written in English where it's used, inside `L("…")`. The English is
  the key. Its argument is one plain literal, never built with `+` or `\(…)`; what
  varies is a `%@`, filled in order from `String`s: `L("Apps paused (%@ of %@)",
  String(on), String(total))`. A table can number them (`%2$@ … %1$@`) where its
  language puts them the other way round.
- **One table per language**, `Resources/Localization/<code>.lproj/Localizable.strings`,
  English text to its translation. `bundle.sh` copies the folders into the app, which
  is also how macOS knows which languages to offer for it. Adding a language is
  adding its folder: Settings lists it by its own name, with no code to change.
  English has an empty table; a string a table lacks shows in English.
- **The language changes at once.** Each window's SwiftUI root carries
  `.localizedRoot()`, which rebuilds it in the new language; what AppKit shows
  (window titles, toolbar labels, menus) is set again on `Localization.didChange`.
- **Checked by `make test`:** every `L()` is a plain literal; no text reaches a
  `Text`, `Button`, `.help`, `.accessibilityLabel`, a title or a tooltip without
  `L()` (a line that only looks that way ends `// untranslated: why`); every table
  has every key, with the same placeholders, and none the app no longer uses; and
  every window passes the accessibility checks in every language.
- **The docs too** (#430). The README and the pages for people using the app have a
  copy per language: `README.zh-Hans.md` and `docs/zh-Hans/`, with its own index,
  each linked to and from its English page under the title. The pages for working
  on the app (architecture, building, decisions, roadmap) are English only. The
  wiki publishes each copy as the English page's name with the code after it
  (`Features-zh-Hans`, `Home-zh-Hans`) and lists them in a section of the sidebar.
  A change to an English page changes its copies in the same pull request, using
  the app's own words for anything in the app (its table, above). The website has
  a page per language too: `zh/index.html` on `gh-pages`. In Chinese pages, bold is
  `<strong>…</strong>`, and a paragraph is one line: GitHub's Markdown leaves `**`
  showing next to Chinese punctuation, and turns a line break into a space.
- **A glossary per language** (#434), `Resources/Localization/<code>.lproj/Glossary.json`:
  the language's words for the app's windows, sections, features and settings, its style
  rules, and words no translation uses. The app's table, the docs, the README, the wiki
  and the website all use them. `make test` holds the app's table to it (below); the
  pages follow it by hand. `bundle.sh` leaves it out of the app.
- **Nothing drifts** (#434). A pull request that changes English changes every language
  with it, rather than in a catch-up later:
  - **The app's text:** `make test` fails until each new or changed `L("…")` has a
    translation in every table.
  - **The pages:** `make translation-check`, run by CI on every pull request, fails when
    the branch changes `README.md`, `SECURITY.md` or a page in `docs/` with a copy, but
    not the copy (`README.<code>.md`, `docs/<code>/security.md`, `docs/<code>/<page>`),
    or adds a page to `docs/` with no copy. Pages for working on the app, like this one,
    have no copy, so they ask for nothing.
  - **English only on purpose** (a typo, a link, a page for developers): a line in the
    pull request's description says so and why, `No translation needed: <why>`. The check
    reads the description when it runs, so re-run the job after adding it.

## Adding a language

From an empty table to a release, in order (#434). Chinese (`zh-Hans`, #428) went this
way, and its files are the examples. `<code>` is the language's code as macOS writes it:
`fr`, `pt-BR`, `zh-Hant`.

1. **The glossary, first.** Copy `Resources/Localization/zh-Hans.lproj/Glossary.json` to
   `<code>.lproj/`. Keep each term's `en` and write its `text`; set `language`, the
   language's own `name` (the wiki's sidebar uses it), its `style` rules and `avoid`
   words, and `reviewer`: the GitHub login of the native speaker who asked for it.
   Settle the words with them on the language's issue before translating anything
   else, since everything after uses them. `make test` then holds the app's table to it:
   - a term whose English is a whole piece of the app's text translates to exactly the
     term;
   - with `"everywhere": true`, every piece of the app's text that says the English, as a
     whole word, holds the term too;
   - no translation uses an `avoid` word;
   - a term the app no longer says fails, unless it's marked `"where": "docs"`, a name
     only the docs and the website use.
2. **The text, in one pass, with the glossary's words.** One pull request into `main`,
   and one into `gh-pages` for the website:
   - **The app:** `<code>.lproj/Localizable.strings`, a translation for every key in
     `zh-Hans.lproj/Localizable.strings`. `make test` names any missing, and runs every
     window's accessibility checks in it. Settings › Language lists it once its folder
     is there. Look at each window in it for width and toolbar, with a build launched
     with `-language <code>` ([Launch arguments](#launch-arguments)).
   - **The README:** `README.<code>.md`, linked to and from `README.md` under the title.
   - **The docs:** a copy in `docs/<code>/` of each page in `docs/zh-Hans/`, its index
     included, each linked to and from its English page.
   - **The wiki:** nothing to do. `Scripts/wiki.py` publishes each copy, and gives the
     language a section of the sidebar, under its glossary's `name`.
   - **The website:** a page in a folder of its own (`zh/index.html` for Chinese) on
     `gh-pages`, with the language switch and `hreflang` on every page. Add the language
     to `shots/shots.json`'s `languages`, with its page and its pictures' folder
     (`assets/<code>/`). Until its pictures are taken (step 5), the page uses the
     English ones.
   - `make translation-check` and `make asset-check` pass.
3. **Release it** ([Releasing](#releasing)) once it's merged. Nothing waits on a review.
4. **The native review, after the release.** Post
   `make translation-review FROM=<the last release's tag>` on the language's issue: the
   first time, that's every piece of text in the language, English beside it, with the
   reviewer mentioned. They read it in the updated app. Their changes follow on the
   issue, in pull requests like any other, and go into the glossary where they name
   something. From then on, each release does the same with what it changed
   ([Releasing](#releasing), step 6).
5. **Pictures, by command.** Once the release is installed, `make site-shots` (from a
   `main` worktree, with `SITE=` a `gh-pages` worktree) takes every shot in the new
   language too, since it has no trees yet, and copies the README's into
   `Resources/README/<code>/`. Check the run names no label it couldn't translate, and
   add any to the language's `specs`. Then a pull request on each branch.
6. **Videos, only if Kevin wants them.** Videos and GIFs are recordings made by hand:
   the README's `demo.gif`, the site's `live.mp4` and `brag.mp4`. Until one is remade,
   the language's pages show the English one. Ask Kevin before remaking any (#432 did
   Chinese's).

After that there are no phases. Each pull request that changes English changes every
language with it, held there by `make test` and `make translation-check`.

## Launch arguments

A development build reads a few launch arguments for that run only; nothing persists.

| Argument | Does |
|---|---|
| `-powerProfile balanced` (or `performance`, `saver`) | measures a power profile without unplugging (below) |
| `-open history` (or `connections`, `ads`, `network`), `-open ads -tab log` (or `rules`, `lists`, in its settings), `-open welcome`, `-open popover`, `-open about`, `-open settings`, `-open settings -pane history` (a section's settings; `hotspot` opens Network, `speedTest` Network's settings) | opens a window straight away, for a screenshot or a check |
| `-open popover -popoverScreen retina` | opens the popover on a Retina screen's menu bar rather than the main screen's, for a full-resolution capture (#360) |
| `-geoDataURL http://127.0.0.1:PORT/ -geoDataCheckNow YES` | fetches the monthly data from a local package, at once (#121) |
| `-updateFeedURL http://127.0.0.1:PORT/appcast.xml -checkForUpdatesNow YES` | checks a local appcast for an update, at once (#132) |
| `-historyDatabase ~/tmp/history.sqlite` | reads and writes Usage History, Connections and Ads and Trackers from another file, for test data (#251) |
| `-language zh-Hans` (or `en`) | shows the app in that language for that run, whatever the Mac's or the one chosen in Settings (#433) |

Serve local test data on a port the system picks, so sessions working in parallel
never ask for the same one: `python3 -m http.server 0 --bind 127.0.0.1` in the
folder holding it prints `Serving HTTP on 127.0.0.1 port N`, and `N` is the `PORT`
above (#342).

A development build shares its settings and data with the installed app, so run it
in its Mac lane (`Scripts/mac-lane.sh`, see [Working in parallel](#working-in-parallel)):
`MAC_LANE=networkmonitor Scripts/mac-lane.sh open -W -n build/NetworkMonitor.app --args …` holds the lane
until that copy quits.

## Measuring power

Measure a power profile without unplugging, using a launch argument that's read only for
that run:

```sh
open -n build/NetworkMonitor.app --args -powerProfile balanced   # or performance, saver
```

Open a window straight away, for a screenshot or a quick check, the same way:

```sh
open -n build/NetworkMonitor.app --args -open connections
open -n build/NetworkMonitor.app --args -open settings -pane history   # any section's settings
```

Then time the CPU of the app and its `nettop` child with `ps -o time=` over a couple of
minutes. Run it in the foreground: `top -l` hangs when run in the background, and its
`IDLEW` column is a running total, not a rate. [Accuracy and battery](accuracy-and-battery.md)
has the current figures.
