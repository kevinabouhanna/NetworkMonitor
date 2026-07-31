# NetworkMonitor

A lightweight macOS menu bar app that shows your live network speed and which apps
are using your data.

```
↓  128 KB/s ↑  12.0 KB/s
```

Click the menu bar item for a per-app breakdown of the day's usage.

## Features

- **Live speed in the menu bar** — download and upload, updated twice a second, in
  byte units (KB/s, MB/s), at a fixed width so nothing jitters.
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
automatically when you log in. Look for `↓ 0 B/s ↑ 0 B/s` in your menu bar.

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
| Reset *(network)* | Zero this network's totals |
| Reset All Networks | Zero everything |
| Rename This Network… | Give a network a friendly name |
| Networks | Today's total for every network seen |
| Track Per-App Usage | See below |
| Launch at Login | Toggle the login item |
| Quit | Quit the app |

### Track Per-App Usage

Per-app data comes from macOS's `nettop`, which is expensive to run — about 1.4
CPU cores whenever it's active. Your **live speed and daily total don't use it at
all** and are always accurate, so this setting only affects the per-app list:

| Mode | Behaviour |
|---|---|
| **While Plugged In** *(default)* | Full-day per-app totals on power; on battery, only while the popover is open |
| **Always** | Full-day per-app totals everywhere, at ~1.4 cores continuously |
| **Only While Open** | Lowest battery use; rows fill in about a second after you open the popover |

## Uninstall

```sh
./Scripts/uninstall.sh            # remove the app and login item
./Scripts/uninstall.sh --purge    # also delete usage history
```

## Building from source

```sh
make test     # run the test suite (95 tests)
make app      # build build/NetworkMonitor.app
make run      # build and launch
make install  # install to /Applications with launch at login
make clean
```

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

## Notes

- Per-app numbers won't add up to exactly the daily total — some network traffic
  belongs to the kernel rather than any app. The daily total is the accurate one.
- The app has been measured at ~99.9% agreement with the kernel's own byte
  counters.

## How it works

See [macOS_Network_Monitor_Spec.md](macOS_Network_Monitor_Spec.md) for the
technical design: why it reads `sysctl` instead of `getifaddrs`, why `nettop` needs
a pseudo-terminal, how VPN traffic is counted exactly once while AirDrop is
excluded, and the measurements behind each decision.

## License

MIT
