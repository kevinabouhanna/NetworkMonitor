# Privacy

NetworkMonitor measures how much data moves, never what it is. Nothing it learns
leaves your Mac.

## What it reads

- **Byte counters per network interface**, from the kernel (`sysctl`), for the live
  speed and the connection total.
- **Bytes per process and connection**, from macOS's own `nettop` tool, for the app
  list. It sees which process moved how many bytes, and whether the other end was on
  the internet or on your own network. It never sees the contents of any traffic.
- **The default gateway's hardware address**, to tell one network from another (see
  [how it tells networks apart](features.md#a-total-per-connection)). This is why it
  needs no Location permission: it never reads your Wi-Fi network's name.
- **The installed apps' update settings**, only when you switch on
  [Hotspot mode](hotspot-mode.md), to know what it can pause and to put it back.

`nettop` runs with `-n`, so it never looks up host names. Looking them up would itself
send traffic.

## What it sends

Nothing, with one exception you start yourself: the **speed test**. It runs
`networkQuality`, the tool Apple ships with every Mac, against Apple's own test
servers. There is no analytics, no telemetry, no crash reporting, no update check and
no account.

Other speed test services were considered and turned down. One of them publishes
every result, with the tester's IP address, as open data.

## What it stores, and where

Everything stays on your Mac:

| What | Where |
|---|---|
| Totals for each network you've joined | `~/Library/Application Support/NetworkMonitor/usage.json` |
| Usage History, by hour, app and network | `~/Library/Application Support/NetworkMonitor/history.sqlite` |
| How to undo what Hotspot mode changed | `~/Library/Application Support/NetworkMonitor/suppression.json` |
| The helper's own undo records (only with the helper) | `/Library/Application Support/NetworkMonitor/` |
| Your settings | the app's preferences (`com.kevinabouhanna.NetworkMonitor`) |

The speed test works in a temporary folder that is deleted as soon as the result is
read. The last result is kept in memory only, and dropped when you change network.

**Clear History** in Settings › History deletes Usage History.
[Uninstalling](installing.md#uninstall) deletes all of it.

## Permissions

- **None asked for, normally.** No Location, no Accessibility, no Full Disk Access, no
  network extension.
- **Your password, once, if you choose it.** Switching on Hotspot mode offers to
  install a small helper, and macOS asks for your password to allow it. The helper can
  do a fixed handful of things and nothing else; see
  [Hotspot mode](hotspot-mode.md#the-helper). Cancel, and everything except the parts
  that need it keeps working.

## Why it isn't in the App Store

App Store apps must be sandboxed, and a sandboxed app can't run `nettop`, which is the
only way macOS offers to see network use per app.
