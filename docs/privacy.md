# Privacy

NetworkMonitor measures how much data moves, never what it is. Nothing it learns
leaves your Mac.

## What it reads

- **Byte counters per network interface**, from the kernel (`sysctl`), for the live
  speed and the connection total.
- **Bytes per process and connection**, from macOS's own `nettop` tool, for the app
  list. It sees which process moved how many bytes, and the address of the other end:
  whether it was on the internet or on your own network, and which server it was. It
  never sees the contents of any traffic.
- **The default gateway's hardware address**, to tell one network from another (see
  [how it tells networks apart](features.md#a-total-per-connection)). It comes from
  macOS's own network configuration, which needs no permission.
- **The Wi-Fi network's name**, to show it in Usage History instead of *Wi-Fi · 3f2a*.
  macOS shares it only with Location permission, so NetworkMonitor asks for that. It
  uses it for the name and nothing else: it never asks where you are.
- **The installed apps' update settings**, only when you switch on
  [Hotspot mode](hotspot-mode.md), to know what it can pause and to put it back.

`nettop` runs with `-n`, so it never looks up host names. Looking them up would itself
send traffic.

## What it sends

Three things, and nothing else:

- **The speed test, when you start it.** It runs `networkQuality`, the tool Apple ships
  with every Mac, against Apple's own test servers.
- **Once a month, the country and network data** (#121). DB-IP publishes a new month at
  the start of each, and the app downloads it from this repository's `geodata` release on
  GitHub: a signed manifest and two compressed tables, about 5.5 MB. It's the same file
  for everyone, so it says nothing about which servers your Mac talks to; GitHub sees
  your IP address and that this Mac runs NetworkMonitor.
  - It checks at most once a day, and only while its data is from an earlier month.
  - Never on a hotspot, a metered connection or in Low Data Mode.
  - It's used only if the manifest's signature checks out against the key built into the
    app, and each table's size and SHA-256 match. Anything less keeps the copy already
    there.
  - On by default. Switch it off in Settings › Connections › **Update them monthly**.

- **Once a day, whether there's a newer version** (#132). Sparkle, the updater many Mac
  apps use, fetches the newest release's appcast from GitHub, a small file listing that
  version. GitHub sees your IP address and which version of NetworkMonitor asked. Never
  on a hotspot or metered connection, unless you choose **Check for Updates…**. An update
  downloads and installs only when you say so, and only if its disk image is signed with
  the key built into the app. Switch the daily check off in Settings › About.

There is no analytics, no telemetry, no crash reporting and no account.

Other speed test services were considered and turned down. One of them publishes
every result, with the tester's IP address, as open data.

## What it stores, and where

Everything stays on your Mac:

| What | Where |
|---|---|
| Totals for each network you've joined | `~/Library/Application Support/NetworkMonitor/usage.json` |
| Usage History, by hour, app and network, including the address of each server an app talked to | `~/Library/Application Support/NetworkMonitor/history.sqlite` |
| How to undo what Hotspot mode changed | `~/Library/Application Support/NetworkMonitor/suppression.json` |
| The country and network data downloaded since the app's own (#121) | `~/Library/Application Support/NetworkMonitor/Geo/` |
| The content filter's copy of your rules and of that data | its own container, which macOS removes with it |
| The helper's own undo records (only with the helper) | `/Library/Application Support/NetworkMonitor/` |
| Your settings | the app's preferences (`com.kevinabouhanna.NetworkMonitor`) |

The speed test works in a temporary folder that is deleted as soon as the result is
read. The last result is kept in memory only, and dropped when you change network.

**Clear History** in Settings › History deletes Usage History, servers included, and the
**Keep history for** setting applies to them too.
[Uninstalling](installing.md#uninstall) deletes all of it.

## Naming servers without asking anyone

A server's address says nothing to a person, so NetworkMonitor names it: the country it's
in, and the company whose network it belongs to. The answers come from DB-IP's free
databases, shipped inside the app and refreshed once a month (see
[What it sends](#what-it-sends)). Nothing is looked up online: asking a service about each address would tell
it every server your Mac talks to. The data is
[IP geolocation by DB-IP](https://db-ip.com), under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

## Permissions

- **Location, to read the Wi-Fi network's name.** Offered in the welcome window when the
  app first opens, and in Settings › General after that (#134). Leave it off and
  everything works, with networks named like *Wi-Fi · 3f2a*.
  Updates keep the answer: every release is signed with the same Developer ID.
  Updating from 1.13 or earlier asks once more, because that signature is new (#119).
- **A content filter, only if you allow it** (#128), in the welcome window or
  Settings › Connections. It's the part of macOS made for apps like this one: it sees
  each connection as it opens, the process that opened it and the server's address and
  name, and tells NetworkMonitor, which keeps the name with that server in Usage History.
  It blocks only what you block (#114), never sees the contents of any traffic, and sends
  nothing anywhere. macOS asks you twice to allow it; System Settings › Network › Filters
  switches it off, and Uninstall removes it.
- **Nothing else, normally.** No Local Network, no Accessibility, no Full Disk Access.
- **A helper, once, if you choose it.** Switching on Hotspot mode offers a small helper,
  which macOS lists under NetworkMonitor in System Settings › General › Login Items &
  Extensions for you to switch on (#131), which macOS may confirm with your password or
  Touch ID. It answers only NetworkMonitor, checked by its
  developer's signature, and can do a fixed handful of things and nothing else; see
  [Hotspot mode](hotspot-mode.md#the-helper). Leave it off, and everything except the parts
  that need it keeps working. A build from source, without a Developer ID, asks for your
  password instead.

## Why it isn't in the App Store

App Store apps must be sandboxed, and a sandboxed app can't run `nettop`, which is the
only way macOS offers to see network use per app.
