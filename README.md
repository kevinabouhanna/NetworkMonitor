<p align="center">
  <img src="Resources/README/logo.png" alt="" width="132">
</p>

<h1 align="center">NetworkMonitor</h1>

<p align="center">
  <b>Live network speed in your macOS menu bar — and the apps behind it.</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13%2B-1d1d1f" alt="macOS 13 or later">
  <img src="https://img.shields.io/badge/permissions-none-51FF70" alt="No permissions required">
  <img src="https://img.shields.io/badge/telemetry-none-51FF70" alt="No telemetry">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT licence">
</p>

---

Your download and upload speed, always visible in the menu bar. Click it for
today's total and a per-app breakdown of who used it.

<p align="center">
  <img src="Resources/README/screenshot.png" width="423"
       alt="NetworkMonitor in the macOS menu bar showing 14.70 KB/s down and 23.90 KB/s up, with its popover open below: a 138.9 MB total for the day, then a list of apps sorted by usage — Google Chrome 29.6 MB, Code 3.0 MB, WhatsApp 2.7 MB, and smaller system processes.">
</p>

## Features

- **Live speed in the menu bar** — download and upload on two lines, updated twice
  a second, at a fixed width so nothing jitters as the numbers change.
- **See which apps are using your data** — sorted biggest first, with icons.
  Chrome's dozen helper processes show as one *Google Chrome* row; OS daemons
  collapse into a single *System* row.
- **A total per network** — every Wi-Fi network, Ethernet connection and hotspot
  gets its own running total. Leave a network and come back, and its total is
  still there.
- **Hotspot aware** — metered connections are flagged with a `METERED` badge, so
  you know when the bytes are costing you.
- **Resets daily** at local midnight, and survives restarts and reboots.
- **Stays out of the way** — no Dock icon, no app switcher entry, no window to
  manage. Just the menu bar.

## Privacy

NetworkMonitor watches your traffic *volume*, never its contents — and it has no
way to phone home.

- **No permission prompts.** It never asks for Location, and doesn't need it.
- **No network access.** The app makes no outbound connections of any kind. There
  is no analytics, no telemetry, no update check, no account.
- **Your data stays on your Mac**, in a single local file you can delete at any
  time.
- **Open source, MIT licensed** — read every line before you run it.

## Install

You'll need macOS 13 or later and Apple's Command Line Tools (`xcode-select
--install`). Xcode itself and an Apple Developer account are *not* required.

```sh
git clone https://github.com/kevinabouhanna/NetworkMonitor.git
cd NetworkMonitor
./Scripts/install.sh
```

That builds the app, installs it to `/Applications`, and starts it at login. Look
for the `↓`/`↑` readout in your menu bar.

To skip the login item, use `./Scripts/install.sh --no-login`.

## Using it

**Left-click** the menu bar item for today's total and the app list. **Right-click**
it for Settings and Quit.

The **gear icon** in the popover opens Settings, which holds start-at-login,
per-app tracking, the counting-since time, Reset Now and Quit.

Quitting and start-at-login are deliberately independent: quitting ends the app for
the rest of the session without turning the setting off, and turning the setting off
doesn't quit the running app.

## What the numbers mean

**Your speed and daily total are always accurate.** They come straight from the
kernel's own byte counters, cost about 3% of a CPU core, and run all the time.
They've been measured at 99.6–100.2% agreement with the kernel across three
independent transfers.

**Per-app numbers are a different trade-off**, and it's worth knowing why. macOS
only exposes per-app traffic through a tool that costs roughly 1.4 CPU cores while
it runs — no setting makes it cheaper. So NetworkMonitor chooses when to pay that
cost:

- **Keep tracking when plugged into power** is **on by default**, so per-app
  numbers cover your whole day whenever you're on the adapter.
- Turn it off in Settings to save battery, and per-app usage is counted only while
  the popover is open.

Either way, per-app totals count what was observed while the app was running, so
they won't quite add up to the daily total — some traffic is wire-level overhead
belonging to no app. **The daily total is the one to trust.**

> Numbers here won't match Activity Monitor or TripMode, and shouldn't. Activity
> Monitor counts bytes since each process *started* — often days ago. This app
> reports what it saw since midnight.

## Uninstall

```sh
./Scripts/uninstall.sh            # remove the app and login item
./Scripts/uninstall.sh --purge    # also delete usage history
```

## Roadmap

Next up: **hotspot metering** — warning you about, and reporting on, the apps
burning through your tethered connection.

## License

MIT — see [LICENSE](LICENSE).
