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
| `NetworkMonitor` | executable | A thin shell: `main.swift` and `AppDelegate.swift` (status item, popover, menus, Settings window, lifecycle) |
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

- **Live tests**, which need a real network and a real `nettop`, are skipped when `CI` is
  set. Run them anyway with `NETMON_LIVE_TESTS=1`. They include guards such as "the stream
  stays under 25% of a core" and "changing the interval leaves exactly one `nettop`".
- **The speed test is never run for real** in the suite: each real run costs 50–500 MB.
  It runs against a stand-in `networkQuality` script; see [speed test](speed-test.md).
- **Popover layout constants** are pinned by tests calibrated against what SwiftUI
  actually lays out.

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

- **`build-and-test`:** build, `make test` (live tests skipped), `make app`, checks on
  the bundle (signature, plist, icon), and the smoke test.
- **`universal`:** `make universal`, and checks that both architectures are there.

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
- **The Mac itself: one at a time, in the Mac lane.** A worktree doesn't keep apart the
  one app in /Applications, its content filter and helper daemon, its settings (which a
  development build shares), the pointer and the screen, or a `pkill` that stops every
  copy of the app. `Scripts/mac-lane.sh` runs whatever touches those one at a time,
  across every worktree and session: `install.sh`, `uninstall.sh`, `install-helper.sh`
  and `smoke-test.sh` take it themselves, and so do `make run`, `make site-check` and
  `make site-shots`. A second caller waits, and is told who holds the lane and since
  when; the lock is the kernel's, so it goes when its holder dies.
  `Scripts/mac-lane.sh status` says whether it's free. `install.sh` builds and notarizes
  before taking the lane, so the lane is held only for stopping, copying and starting
  the app.
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

Some things it can't stage: a speed test's result, a download in progress, the hero
video. Those are entries that only check a window (the popover, from `-open popover`)
and list the files that show it under `flags`. When that window changes, the check names
them to remake by hand, and keeps naming them until `make site-shots NAMES=popover`
records the new tree. Rewrite the alt text of any picture whose interface changed.

- It needs Accessibility and Screen Recording for the terminal it runs in. It quits and
  relaunches the app, clicks with the pointer when an entry says so, and leaves the app
  running as it found it.
- It must run against the installed, notarized app: a development build shows different
  rows, since it has no content filter or helper.
- To add a picture, write its entry, look at `build/site-shots tree <name>` to mark the
  data regions, and run `make site-shots NAMES=<name>`.
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

## Launch arguments

A development build reads a few launch arguments for that run only; nothing persists.

| Argument | Does |
|---|---|
| `-powerProfile balanced` (or `performance`, `saver`) | measures a power profile without unplugging (below) |
| `-open connections`, `-open ads -tab rules`, `-open welcome`, `-open popover`, `-open settings -pane history` | opens a window straight away, for a screenshot or a check |
| `-geoDataURL http://127.0.0.1:PORT/ -geoDataCheckNow YES` | fetches the monthly data from a local package, at once (#121) |
| `-updateFeedURL http://127.0.0.1:PORT/appcast.xml -checkForUpdatesNow YES` | checks a local appcast for an update, at once (#132) |
| `-historyDatabase ~/tmp/history.sqlite` | reads and writes Usage History, Connections and Ads and Trackers from another file, for test data (#251) |

Serve local test data on a port the system picks, so sessions working in parallel
never ask for the same one: `python3 -m http.server 0 --bind 127.0.0.1` in the
folder holding it prints `Serving HTTP on 127.0.0.1 port N`, and `N` is the `PORT`
above (#342).

A development build shares its settings and data with the installed app, so run it
in the Mac lane (`Scripts/mac-lane.sh`, see [Working in parallel](#working-in-parallel)):
`Scripts/mac-lane.sh open -W -n build/NetworkMonitor.app --args …` holds the lane
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
open -n build/NetworkMonitor.app --args -open settings -pane history   # any pane
```

Then time the CPU of the app and its `nettop` child with `ps -o time=` over a couple of
minutes. Run it in the foreground: `top -l` hangs when run in the background, and its
`IDLEW` column is a running total, not a rate. [Accuracy and battery](accuracy-and-battery.md)
has the current figures.
