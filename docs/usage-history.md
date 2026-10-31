# Usage History

The popover's total starts over when you join a different network, and at midnight.
Usage History is where those totals go: every hour, per app and per network, for as
long as you choose.

Open it from the popover's **chart icon**, from **Usage History…** (⌘Y) in the
right-click menu, or from **Settings › History**. It's the History pane of Settings,
not a window of its own, so nothing exists twice.

## Using it

- **Day, Week, Month or Year**, with **‹ Today ›** beside it (⌘← and ⌘→ step too), as
  the Connections window has them in its toolbar. Periods are
  calendar periods, not rolling windows, so "October" means the same bytes every time
  you look, the way Screen Time and carriers count. A day shows hours, a week or month
  shows days, a year shows months. Click a bar to open it.
- **Stacked by network type**: Wi-Fi, Hotspot, Ethernet and Other. Each type keeps its
  colour whatever else is in the period. The legend under the chart gives each type's
  total, so no figure is readable only by hovering.
- **All, Wi-Fi or Hotspot**, at the end of the same row, narrows everything to that
  kind of network: the chart, the totals and the lists. It opens on **Hotspot** while
  you're on one, and on **All** otherwise. Ethernet and Other are under All, and on the
  Networks list.
- **Each app's bar is split by network type**, in the chart's colours, so an app that
  used both Wi-Fi and a hotspot shows how much went over each. Splits too small to see
  are left out; the Networks list has the exact figures.
- **The heading** names the period, then gives what was used, with what went over
  metered connections and the daily average as one quieter line. The daily average
  divides by the days elapsed so far, not by the length of the month. Metered is shown
  under All, and only when something went over a metered connection.
- **Apps, Networks and Sessions.** Apps are grouped exactly as in the popover. A
  session is one visit to a network.
- **The lists are the filters.** Click a row to see only that app, network or session,
  and the chart and totals follow; click it again, or its chip at the end of the lists'
  row (#192), to undo. Filters combine, with each other and with the switch.
- **Name a network** by right-clicking it under Networks. The name is used in History
  and in exports, for every past visit too.
- **Keep history for** a month, three months, a year, or forever (the default).
  Shortening it asks first if it would delete anything.
- **Export CSV…** saves the period on screen, with its filter, hour by hour and app by
  app, in bytes.
- **Clear History…** deletes it all. The menu bar totals aren't affected.

While the pane is open on a period that includes now, it refreshes every 30 seconds.

## What counts

History counts the same **internet-only** figure as the popover. Mirroring a screen,
Time Machine to a NAS or a Plex stream from your own server is never part of it. See
[accuracy](accuracy-and-battery.md#internet-not-your-own-network) for how that figure
is worked out.

It starts the moment you install a version that has it (1.4.0 or later). Nothing from
before can be recovered: the old totals have no hours in them, and spreading a lump
over a day would be inventing data.

## Sessions

A session is one visit to a network: from joining it until you leave for another, or
until the Mac has been silent for **30 minutes**, as it is after a sleep.

- **Going offline isn't a place.** A Wi-Fi blip and a rejoin continue the same visit.
- **A session ends at its last traffic**, not when the next network appears. A lid
  closed at the office ends the office visit when it closed.
- **Waking up.** The first packets after a wake arrive before macOS has settled which
  network you're on (the app waits 2 seconds for it to settle). A session opened then
  stays provisional for 30 seconds and adopts the network that's named in that time,
  so it doesn't leave a few-kilobyte visit on the network you closed the lid on.
- **Relaunching** on the same network within 30 minutes continues the visit.
- **Each session keeps its own metered verdict**, read again as it closes, so a
  hotspot visit stays metered after you've moved on to home Wi-Fi.
- **Updates that got through stay with their visit** (#96). A hotspot visit where one
  did says *2 updates got through* under its name, and choosing it lists them: the app,
  the version once known, and the data used, or *up to* when only the most it could be
  is known. Hotspot mode's *Got through* list only holds the last metered connection;
  History keeps them under the same retention and Clear History as everything else.
  Each is kept once, with the visit it was first seen on, even when one connection runs
  across several visits.

## Networks

A network is identified by its router's hardware address, not its name. Two routers with
the same Wi-Fi name stay apart, and roaming between access points of one network stays
one network. The same router over Wi-Fi and over Ethernet is one network, which is what
a data cap cares about.

**What it's called:**
- **Its Wi-Fi name**, once Location is allowed (macOS shares the name only then). Past
  visits take the name too.
- **Both names for a router whose bands are named apart**, such as *Home / Home-5G*.
  2.4 and 5 GHz on one router are one network.
- **Otherwise its type and the last four characters of the router's address**, such as
  *Wi-Fi · 3f2a*: Ethernet, USB tethering, or Location refused.
- **Networks not told apart**, for traffic the app couldn't place on a network, such as
  everything on macOS 27 before 1.9.7.
- **A name you give it** under Networks wins over all of these.

## CSV format

```
Hour,Network,Network Type,Metered,App,Downloaded (bytes),Uploaded (bytes),Update That Got Through
```

- One line per app, per hour, per visit. That's everything History holds; a
  spreadsheet can total it any way it likes, but couldn't split a daily figure apart.
- `Hour` is `yyyy-MM-dd HH:mm` in your time zone.
- Without an app filter, each hour also has a *Not attributed to an app* line for the
  rest of the internet total, so the file adds up to what the window shows.
- `Update That Got Through` is filled on the app's line in the hour an update was first
  seen, such as *Slack updated to 4.41, 120 MB* (#96). When the app has no line in that
  hour, the update gets a line of its own with no bytes, so the columns still add up.
- Fields are quoted only when they need it (RFC 4180). The file is UTF-8.

## How it's built

**Storage.** `~/Library/Application Support/NetworkMonitor/history.sqlite`, through the
system's own SQLite library, with no third-party dependency. History only grows, and
every view is a range query and a sum, which is the wrong shape for a JSON file.
`WAL` journaling with `synchronous = NORMAL`: a write is an append rather than an
`fsync`, and a crash can lose the last moments but never corrupt the file. A file
that can't be opened is moved aside as `history.unreadable-<time>.sqlite`, never
deleted, and a new one started.

**Schema** (`UsageHistory.swift`). One row per hour per session, and one per hour per
session per app. An hour is the finest grain any view needs, and keeps a year to
roughly a hundred thousand rows. The servers each app talked to, for
[Connections](connections.md), are kept the same way.

| Table | Holds | Key |
|---|---|---|
| `sessions` | network id, type, default label, start, end (last traffic), metered | `id` |
| `apps` | app key, name, bundle path, whether it's System, parent app | `key` |
| `traffic` | per hour and session: interface bytes, LAN bytes, attributed app bytes, each way | `(hour, session_id)` |
| `app_traffic` | per hour, session and app: bytes in and out | `(hour, session_id, app_key)` |
| `servers` | a server's address, and the name an app last reached it by (#128) | `id` |
| `app_servers` | each app and server pair, once, with when it was first seen (#111) | `id` |
| `server_traffic` | per hour, session and app and server: bytes in and out, and connections blocked (#114) | `(hour, session_id, app_server_id)` |
| `updates` | each update that got through: the app, its version, the data it used, and the session it was first seen on (#96) | `(report, source, name)` |

The raw figures are stored and the internet figure is derived when reading, with the
same clamp the popover uses, so the formula lives in one place:
`MIN(interface, MAX(interface − LAN, apps))` per direction, per hour and session.

**Feeding.** `UsageStore` forwards every byte and every network change to
`UsageHistory`, so History and the popover can never disagree about which network a
byte used. Reset Now and midnight clear the popover's counter, never History.

**Writing.** Batched in memory and written when the usage file is saved (about every
15 seconds, on a network change, on sleep and on quit), in one transaction of upserts
that add to existing rows. Synchronous, because quit calls it, and well under a
millisecond. It's also flushed before every read, so the current hour is never
missing. A failed batch is dropped, not retried, because a database that refuses one
write will refuse the next; the popover's totals are unaffected.

**Reading** happens on its own serial queue, so stepping through a year never stalls
the menu bar. Measured on a generated 400-day database (5.5 MB): a year's per-app
totals in 32 ms, hourly totals in 2 ms.

**Retention** (`historyRetention` in preferences) prunes whole days, at most once a
day and straight away when the setting changes, then reclaims space with
`incremental_vacuum`.

**The chart** is Swift Charts, stacked by hand so segments get a 2-point gap and only
the top of a bar is rounded. The value axis uses round 1024-based steps chosen by the
app (Swift Charts' own steps printed "953.7 MB"). The four colours were checked for
colour-blind separation in light and dark mode; two of the light ones fall below 3:1
contrast against the window, which is why every figure is also given as text. Hover
dims other bars by mixing them toward the background rather than lowering opacity,
because the double-drawn top segment would show through.

**Tests** in `UsageHistoryTests.swift` cover the internet figure matching the popover,
LAN-only traffic never counting, every session rule above, filters, retention, Clear
History, the CSV adding up, DST days having 23 or 25 hourly bars, and the axis steps.
They use a temporary database and a UTC calendar.

## Known limits

- History begins when you install 1.4.0 or later.
- **On macOS 27 before 1.9.7**, every Wi-Fi network, iPhone hotspots included, was
  recorded as one network ([#70](https://github.com/kevinabouhanna/NetworkMonitor/issues/70)).
  Those visits can't be split after the fact: nothing recorded when the switches happened.
- The Day/Week/Month/Year choice is remembered while the app runs, not across launches.
- Which day a week starts on follows your Mac's region settings.
- The schema version (`user_version`) is still 1. The two columns added since, a server's
  name (#128) and blocked connections (#114), are added to an older file when it opens,
  if they're missing.
