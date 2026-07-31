# NetworkMonitor

A lightweight macOS menu bar app that shows your live network speed and which apps
are using your data.

```
↓ 14.14 KB/s     ← download, #51FF70
↑ 28.69 KB/s     ← upload,   #E5E5E5
```

Click the menu bar item for a per-app breakdown of the day's usage.

## Features

- **Live speed in the menu bar** — download and upload stacked on two lines,
  updated twice a second, in byte units (KB/s, MB/s), at a fixed width so nothing
  jitters.
- **Per-app usage** — sorted biggest first, with app icons. Helper processes are
  folded into their parent, so Chrome's dozen helpers show as one "Google Chrome"
  row, and OS daemons collapse into a single "System" row.
- **Per-network totals** — usage is tracked separately for each Wi-Fi network,
  Ethernet connection and hotspot. Dropping off a network and rejoining it keeps
  its total; switching networks shows that network's own total.
- **Hotspot aware** — metered networks (Personal Hotspot, cellular) are flagged
  with a `METERED` badge.
- **Resets daily** at local midnight, and survives restarts and reboots.
- **No permission prompts.** It never asks for Location, and it doesn't need it.
- **Menu bar only** — no Dock icon, no app switcher entry.

## Requirements

- macOS 13 or later (developed and tested on macOS 26)
- Xcode **not** required — Command Line Tools are enough:
  ```sh
  xcode-select --install
  ```
- No Apple Developer account needed.

## Install

```sh
git clone <this-repo> NetworkMonitor
cd NetworkMonitor
./Scripts/install.sh
```

That builds the app, installs it to `/Applications`, and sets it to start
automatically when you log in. Look for the two-line `↓`/`↑` readout in your menu
bar.

To install without adding it to login items:

```sh
./Scripts/install.sh --no-login
```

> **No code signing required.** The app is signed ad-hoc, which is all macOS needs
> to run it locally, and launch-at-login uses a plain LaunchAgent that needs no
> signature at all. A Developer ID is only needed if you want to distribute the app
> to other people.

## Usage

**Left-click** the menu bar item to open the usage popover.

**Right-click** it for the menu:

| Item | What it does |
|---|---|
| Settings… | Everything below |
| Quit | Quit the app |

The popover itself is just a total and the app list. The **gear icon** in it opens
Settings, which holds start-at-login, per-app tracking, the counting-since time,
Reset Now, and Quit.

### Quitting and starting at login

These are independent, which is the point:

- **Quit** (or killing the process) ends the app for the rest of the session. It
  will *not* come back on its own.
- **Start at login** is on by default and brings it back at your next login. Turn
  it off in Settings and it stays off.

Turning *off* start-at-login does not quit the running app, and quitting does not
turn off start-at-login.

### Per-app tracking and what the numbers mean

Per-app data comes from macOS's `nettop`, which costs about **1.4 CPU cores while
it runs** — and that cost is fixed, unaffected by how often it samples. So when it
runs is a real battery-versus-completeness choice.

A per-app total only counts traffic seen while `nettop` was running, and nothing
can recover traffic from before the app launched.

**Keep tracking when plugged into power** is **on by default**, so per-app numbers
cover your whole day and are comparable with always-on tools. It keeps counting
with the menu closed whenever your Mac is on its power adapter. Turn it off in
Settings to save battery — per-app usage is then only counted while the menu is
open.

Note that even with it on, per-app counting pauses on battery with the menu closed.
For a like-for-like comparison against an always-on tool, stay plugged in.

**Your live speed and daily total never use `nettop`.** They come from kernel
interface counters, cost about 3% of a core, always run, and have been measured at
99.6–100.2% agreement with the kernel's own byte counters.

> Comparing per-app numbers with Activity Monitor or TripMode will not line up.
> Activity Monitor reports bytes **since each process started** — often days — and
> TripMode runs an always-on network extension. This app reports what it observed
> since midnight, while running.

## Uninstall

```sh
./Scripts/uninstall.sh            # remove the app and login item
./Scripts/uninstall.sh --purge    # also delete usage history
```

## Building from source

```sh
make test     # run the test suite (100 tests)
make app      # build build/NetworkMonitor.app
make run      # build and launch
make install  # install to /Applications with launch at login
make icon     # redraw Resources/AppIcon.icns (committed; only after editing it)
make clean
```

The app icon is drawn in code, in [Scripts/make-icon.swift](Scripts/make-icon.swift) —
the same green down arrow and light up arrow as the menu bar, on a dark squircle.

Your usage history is stored at
`~/Library/Application Support/NetworkMonitor/usage.json`.

## Distributing to other people

Only this step needs a paid Apple Developer account:

```sh
export SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
./Scripts/bundle.sh --universal          # arm64 + x86_64
xcrun notarytool submit build/NetworkMonitor.app --wait \
      --apple-id … --team-id … --password …
xcrun stapler staple build/NetworkMonitor.app
```

The app can't be sandboxed (it runs `nettop`), so it isn't eligible for the Mac
App Store.

## Roadmap

The next major feature is **metering the hotspot connection** — stopping apps from
updating while you're tethered.

Worth knowing up front: everything today only *observes* traffic, which needs no
permissions. *Blocking* an app's traffic needs a Network Extension system extension,
which requires a paid Apple Developer account, an Apple-granted entitlement, a
Developer ID signature and user approval. That's how TripMode does it, and there's
no unprivileged shortcut.

A useful first step that needs none of that is to warn and report on hotspot usage
rather than enforce — macOS already suppresses many background updates on networks
it considers expensive. See
[the spec](docs/macOS_Network_Monitor_Spec.md) §9 for the full analysis.

## Notes

- Per-app numbers won't add up to exactly the daily total — some traffic is
  wire-level overhead belonging to no app, and per-app tracking only runs part of
  the time (see above). The daily total is the accurate one.
- The daily total and live speed have been measured at 99.6–100.2% agreement with
  the kernel's own byte counters, across three independent transfers including a
  sustained 52 MB one.

## How it works

See [docs/macOS_Network_Monitor_Spec.md](docs/macOS_Network_Monitor_Spec.md) for the
technical design: why it reads `sysctl` instead of `getifaddrs`, why `nettop` needs
a pseudo-terminal, how VPN traffic is counted exactly once while AirDrop is
excluded, and the measurements behind each decision.

## License

MIT
