# Features

Everything NetworkMonitor does, and where to find it.

## The menu bar readout

Two lines, always visible: **↓ download** in green over **↑ upload**, in **MB/s** or
**Mbps** (**Settings › General › Show speeds in**). Mbps matches how your line is sold;
MB/s matches the data totals. Amounts of data are always in MB and GB, the way data plans
are sold.

The readout keeps a **fixed width**, so nothing beside it in the menu bar jumps around as
the numbers change. It updates up to twice a second, less often on battery and in Low Power
Mode (see [battery](accuracy-and-battery.md#battery)). While a speed test runs, the readout
shows it in cyan.

- **Click** it for the popover.
- **Right-click** (or Control-click) it for **Test Internet Speed**, the last result,
  **Usage History…** (⌘Y), **Settings…** (⌘,), **Uninstall NetworkMonitor…** and **Quit**.

## The popover

- **Total**: what this connection has used since you joined it, or since midnight, in one
  combined figure. An orange **METERED** badge appears beside it on a hotspot.
- **The apps behind it**, biggest first, each with a bar for its share. The list re-sorts
  live as apps overtake each other, and a dot marks apps moving data right now.
- **Helpers fold into their app**: Chrome's dozen helper processes are one *Google Chrome*
  row.
- **Commands break out beneath the app that started them.** Click iTerm2 or VS Code to see
  the `node`, `git` or `curl` it launched, each with its own figure. More than four become
  *Other (n)*.
- **System**: macOS's own daemons collapse into one row at the bottom. Open it when you're
  curious.
- **Got through**: on a hotspot with [Hotspot mode](hotspot-mode.md) on, one line under the
  total says if an update downloaded anyway.
- **Per-app figures paused**: if macOS's `nettop` can't be started, a grey line says so
  while NetworkMonitor keeps retrying. The total keeps counting regardless.
- **Header buttons**: the gauge runs a [speed test](speed-test.md), the chart opens
  [Usage History](usage-history.md), and the gear opens Settings.

The list holds eight rows and part of a ninth, so a cut-off row tells you there's more.
Esc or a click elsewhere closes it.

## A total per connection

Join a different Wi-Fi network or hotspot and the total starts from zero, so what you see
is what *this* connection has used. Open your hotspot somewhere new and you know exactly
what each app spent on it.

- **A dropout and a reconnect** to the same network picks up where it left off.
- **It resets at midnight** too, for a connection you never leave.
- **It survives restarts**, and a relaunch on the same network carries on.
- **Reset Now** (Settings › General) starts the current network's total over.
- **Counting since** (Settings › General) shows when the current total began.

Networks are told apart by their router's hardware address, not their Wi-Fi name, so no
Location permission is needed.

Totals from earlier networks and days go to [Usage History](usage-history.md).

## Internet only

Mirroring to an Apple TV, Time Machine to a NAS, a Plex stream from your own server: these
cross your Wi-Fi but cost no internet data, so they're never counted. An app that only
talked to your own network doesn't appear at all. See
[accuracy](accuracy-and-battery.md#internet-not-your-own-network).

## Usage History

Every hour, per app and per network, for as long as you choose. Look back by day, week,
month or year; see each visit to a network as a session; narrow everything to one app, one
network or every hotspot at once; export it as CSV. See [Usage History](usage-history.md).

## Speed test

One click runs a fresh test with the tool built into macOS: download, then upload, then
ping, jitter, and ping under load, in Mbps or MB/s. If another app was competing for the
line, the result names it. On a hotspot it asks first. See [Speed test](speed-test.md).

## Hotspot mode

One switch stops your apps updating while you're on a mobile hotspot, puts the connection in
Low Data Mode, and tells you which apps it can't stop. See [Hotspot mode](hotspot-mode.md).

## Settings

One window with a pane for each area. It's titled and sized after the pane, and reopens on
the pane you used last.

| Pane | What's in it |
|---|---|
| **General** | Start at login · Show speeds in MB/s or Mbps · Popover totals: Counting since, Sampling, Reset Now |
| **Speed Test** | Run a test right there · Show the test in the popover as a Card or Compact |
| **History** | [Usage History](usage-history.md) |
| **Hotspot** | Stop apps updating on hotspots · what it decided about the connection you're on · Apps paused, each with its own switch · Not covered · Low Data Mode · what got through |
| **About** | Version · website, release notes and source · Uninstall… |

While Settings is open, NetworkMonitor has a Dock icon and a menu, so ⌘W, ⌘, and ⌘Y work
and ⌘-Tab can find it. It goes back to living in the menu bar when you close it.

## Staying out of the way

- No Dock icon, no app switcher entry, no window to manage. Just the menu bar.
- **Starts at login** by default, once. Turn it off in Settings › General and it stays off.
- **Quit stays quit.** Quitting ends it for the session without turning off Start at
  login, and turning that off doesn't quit the running app.
- Works with the menu bar set to hide automatically: the popover stays open while the bar
  hides, and Settings stays in front.
