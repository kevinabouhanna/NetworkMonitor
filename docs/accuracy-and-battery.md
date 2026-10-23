# Accuracy and battery

## The total is the one to trust

**Your speed and connection total come straight from the kernel's own byte counters,**
and run all the time. Checked against the kernel across three independent transfers:

| Transfer | Recorded vs the kernel's own count |
|---|---|
| 10 MB download | 100.2% |
| 50 MB download | 100.0% |
| 6.5 MB, sustained over 15 seconds, to look for lost samples | 99.6% |

The kernel's figure is a little above the payload because it includes TCP, TLS and HTTP
overhead, which is real traffic you pay for. The live rate tracks to within 0.4%.

**Per-app rows won't quite add up to the total, and shouldn't.** The kernel counts
everything on the wire, including overhead that belongs to no app; `nettop` counts what each
app's sockets moved. In the 50 MB test, `curl` was credited with 94.8% of the kernel's
figure, and the rest was wire overhead. The final second before you quit is never
completed either. So the big total is the one to trust; the rows tell you where it went.

## Internet, not your own network

Mirroring your screen to an Apple TV, Time Machine to a NAS, a Plex stream from your own
server: they cross your Wi-Fi but cost no internet data, so they're left out. AirPlay through
a router alone can move 4 to 13 GB an hour, which would otherwise swamp the day.

Every connection's other end is checked: private addresses (`10/8`, `172.16/12`,
`192.168/16`, link-local) are your own network; everything else, and anything that can't be
read, is internet. Under-reporting is the one error the app can't afford, so ambiguity counts
as internet. [Architecture](architecture.md#internet-not-your-own-network) has the details,
including why multicast is never subtracted and why the total is clamped between the app
rows and the kernel's count.

## Why it won't match Activity Monitor

Activity Monitor's Network tab counts bytes since each process **started**, often days ago.
NetworkMonitor reports what it saw on the connection you're on, since you joined it, or
since midnight. Neither is wrong; they answer different questions.

## Battery

NetworkMonitor samples less often when it can, and never counts less. Both sources report
the bytes moved **between** samples, so sampling less often changes how fresh the figures
are, not how complete. There's nothing to configure, and **Settings › General › Sampling**
says which mode is in force.

| | Readout updates | App list updates | While nobody can see the menu bar |
|---|---|---|---|
| **Plugged in** | every 0.5 s | every 1 s | counters every 5 s |
| **On battery** | every 1 s | every 3 s | counters every 10 s |
| **Low Power Mode**, plugged in or not | every 2 s | every 10 s | counters every 15 s |

"Nobody can see the menu bar" means the display is asleep, the screen is locked, or another
user's session is in front. Then the readout isn't drawn at all, and it catches up the moment
someone can see it.

Measured on an M1 MacBook Air with its own everyday background traffic, two minutes each,
the app and its `nettop` together:

| | Share of one CPU core |
|---|---|
| Plugged in | 2.68% |
| On battery | **1.19%** |
| Low Power Mode | **0.53%** |
| On battery, with nobody watching | **0.47%** |

Most of the app's own share is drawing the menu bar readout. Over a day, Activity Monitor's
12-hour power figure puts it alongside other menu bar utilities that run all the time.

### The drain that was a bug

Early versions cost about **1.4 CPU cores**, and switched per-app tracking off on battery
because of it. The cost turned out to be a bug, not a price. `nettop`, the tool macOS
provides for per-app numbers, polls its input for keystrokes. It was given an input that's
always "ready" (`/dev/null`), so it spun on an empty loop forever. Given an input that waits
properly, the same data cost **0.55% of a core**, 256 times less, and arrived just as fast.

The fix also showed that switching tracking off on battery was backwards: it turned
attribution off exactly where it matters, on a phone's hotspot. One hotspot session showed
25.4 MB on the interface against 1.1 MB attributed to apps. So per-app tracking now always
runs, on every network and on battery.

[Development](development.md#measuring-power) shows how to measure a profile without
unplugging.
