# Building, testing and releasing

## Requirements

- **To run:** macOS 13 or later, Apple silicon or Intel.
- **To build:** Apple's **Command Line Tools** (`xcode-select --install`). Xcode and a
  developer account aren't needed, though everything works under Xcode too.
- **Swift:** a Swift 6 toolchain. `Package.swift` declares tools version 5.9 on
  purpose, which keeps the Swift 5 language mode, so the package builds without Swift 6
  strict-concurrency annotations.
- **No dependencies.** Usage History uses the system's own SQLite.
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
| `make install` | Builds, copies to /Applications, and lets the app register itself to start at login |
| `make install-only` | The same without starting at login |
| `make update` | `git pull --ff-only`, the tests, then `install`. Tests first, so a bad pull can't replace a working copy |
| `make uninstall` | `Scripts/uninstall.sh` (see below) |
| `make helper` | Installs the root helper by hand, with its hourly self-check. Asks for your password |
| `make helper-no-daemon` | The same without the hourly self-check |
| `make metering-report` | Prints what Hotspot mode reaches on this Mac, pending update downloads and the Low Data Mode state. Read-only, safe beside a running copy |
| `make icon` | Redraws `Resources/AppIcon.icns` from `Scripts/make-icon.swift` |
| `make geodata` | Rebuilds `Resources/Geo` from DB-IP's current month. The files are committed, because DB-IP removes old months; refresh them in a pull request of their own |
| `make dmg-background` | Redraws the disk image background |
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
| `ServerDirectory` | library | Which country an address is in and whose network it belongs to, from `Resources/Geo`. Pure Foundation, so the content filter can use it later without the app's frameworks |
| `GeoDataBuilder` | executable | Converts DB-IP's CSVs into `Resources/Geo`. Run by `make geodata`, never part of the app |
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
   `Contents/Library/LaunchServices/`, and `helper-setup.sh` in `Resources`.
4. **Signing**, inside out and without `--deep`: the helper first, with its own
   identifier, then the app. `--deep` re-signed the helper with an identifier guessed from
   its file name, which was the app's. With what:
   - **NetworkMonitor's own certificate** (issue #86), when it's there: the `.p12` in
     `SIGNING_P12` and its password in `SIGNING_P12_PASSWORD`, or by default
     `~/.config/networkmonitor-signing/signing.p12` and `password`. It's self-signed, so
     Gatekeeper still asks for Open Anyway. The point is that every build has the same
     designated requirement, the identifier plus this certificate, so macOS keeps Location
     (asked for Wi-Fi names) across updates. Checked: an ad-hoc rebuild was asked again,
     and two builds with this certificate and different hashes were not. Each build
     imports the key into a throwaway keychain and deletes it afterwards.
   - **Ad-hoc**, without it: forks and pull request CI. Each build is a new app to macOS.
   - **A Developer ID**, with `SIGN_IDENTITY` set: the hardened runtime and a timestamp,
     ready for notarization.

`Scripts/make-dmg.sh` packages the app with `dmgbuild` (`Scripts/dmg-settings.py`): an
LZFSE-compressed image with the app, an `Applications` link and a light background. The
background is light on purpose: Finder draws icon labels black over a background picture
even in dark mode. The file name has no version, so
`releases/latest/download/NetworkMonitor.dmg` always works; the website links to it.

## Other scripts

- `Scripts/install.sh` builds, copies to `/Applications`, strips the quarantine flag, and
  opens the app, which registers itself to start at login. `--no-login` skips that.
- `Scripts/uninstall.sh` quits the app and any `nettop` it left, puts back what Hotspot
  mode changed, removes the helper (password), the login item and the app. Unlike the
  in-app Uninstall, it **keeps your usage data** unless you pass `--purge`.
- `Scripts/install-helper.sh` installs the helper for development, through the same
  `helper-setup.sh` the app uses.
- `Scripts/smoke-test.sh` launches the built app and fails if it isn't still running five
  seconds later. Deliberately shallow: a crash on launch is the one bug an auto-updater
  would ship to everyone.

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

## Releasing

1. Tag `main` and push the tag: `git tag vX.Y.Z && git push origin vX.Y.Z`.
2. The **Release** workflow (`.github/workflows/release.yml`) runs the tests, builds the
   universal DMG with the tag's version, checks the version, the helper and the
   signature, and publishes `NetworkMonitor.dmg` with install and update instructions.
   It signs with the certificate in the repository secrets `SIGNING_P12_BASE64` and
   `SIGNING_P12_PASSWORD`, fails without them, and checks the signature names that
   certificate (fingerprint `96c1f2de…`).
3. Add a **What's new in X.Y.Z** section to the release notes by hand.
4. Update the website (below).

Notarization isn't done yet; see the [roadmap](roadmap.md).

## The website

[kevinabouhanna.github.io/NetworkMonitor](https://kevinabouhanna.github.io/NetworkMonitor/)
is a static page on the **`gh-pages`** branch, conveniently checked out as a worktree
beside the main checkout. Changes to it get an issue and a pull request against
`gh-pages`, but no release.

- `Closes #N` only closes issues for pull requests into `main`, so close the issue by hand.
- Don't merge with `gh pr merge --delete-branch` while the branch is checked out in the
  worktree: `gh` removes the worktree along with it.
- After each release, update the hero's version, the download line's version and DMG
  size (in 1024-based MB), the "What's in version" link, and the About pane capture
  (`assets/settings/about.png`), which shows the version.
- **Every image is a real capture of the app**, never a mock-up. The Settings section
  shows each pane as a capture in `assets/settings/`, with the window's size in points on
  each `<img>` and clickable areas placed in the same points.

## Measuring power

Measure a power profile without unplugging, using a launch argument that's read only for
that run:

```sh
open -n build/NetworkMonitor.app --args -powerProfile balanced   # or performance, saver
```

Open a window straight away, for a screenshot or a quick check, the same way:

```sh
open -n build/NetworkMonitor.app --args -open connections        # or settings
```

Then time the CPU of the app and its `nettop` child with `ps -o time=` over a couple of
minutes. Run it in the foreground: `top -l` hangs when run in the background, and its
`IDLEW` column is a running total, not a rate. [Accuracy and battery](accuracy-and-battery.md)
has the current figures.
