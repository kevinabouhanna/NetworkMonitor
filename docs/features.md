# Features

English · [简体中文](zh-Hans/features.md)

Everything NetworkMonitor does, and where to find it.

## The menu bar readout

The menu bar shows two lines, with **↓ download** in green over **↑ upload** in light grey by default, in
**MB/s** or **Mbps** (**Settings › Show speeds in**). Mbps matches how your line
is sold; MB/s matches the data totals. Amounts of data are always in MB and GB, the way
data plans are sold. Pick other colours under **Settings › Speed colors**: six ready-made
pairs (Green, the default, Teal, Blue, Gold, Pink and Violet), each made to read on a dark
and a light menu bar, or **Custom…** for your own. **Speed on top** in that
section puts Download or Upload on the upper line, in the menu bar and on the Dock icon,
including when a speed test is shown.

The readout **follows the menu bar**: on a light one, as over a light wallpaper, each colour is
drawn darker in the same hue so it stays readable, and it switches by itself when the
wallpaper changes. On a dark menu bar the colours are drawn as picked.

The readout keeps a **fixed width**, so nothing beside it in the menu bar jumps around as
the numbers change. It updates up to twice a second, less often on battery and in Low Power
Mode (see [battery](accuracy-and-battery.md#battery)). While a speed test runs, the readout
shows it in cyan, or in another pair of colours if yours come close to cyan, so a test never
looks like the live rates.

VoiceOver reads it in the order shown. With the default order,
it says *NetworkMonitor, Download 1.2 megabytes per
second, upload 30 kilobytes per second*, or *Speed test: download …* while a test shows (#497).

- **Click** it for the popover.
- **Right-click** (or Control-click) it for **Test Internet Speed**, the last result,
  **Block Everything** (#198), **Pause Ad Blocking** for an hour, until tomorrow or whenever
  on this network, or **Resume Ad Blocking** while it's paused (#600), **Usage History…** (⌘Y), **Connections…** (⌘K), **Ads and
  Trackers…** (⌘B), **Network…**, **Settings…** (⌘,), **About NetworkMonitor**, **Check for
  Updates…**, **Uninstall NetworkMonitor…** and **Quit**.

## In the Dock instead

**Settings › Show NetworkMonitor in** chooses where the app lives (#69). It takes effect
at once.

- **Menu bar**, the default: the readout above, and a Dock icon only while a window is open.
- **Dock**: nothing in the menu bar. A **Dock icon** choice appears under it (#523):
  - **Speeds**, Dock's default: the whole Dock icon shows the live speeds, download over upload by default,
    drawn like the app's icon: its shape and lighting, near black in dark mode and near
    white in light, following the Mac as it switches. Each speed is the icon's arrow and
    its figure to three significant figures (12.3), as large as fits, with its unit under
    it, in the speed colors (on light, drawn darker so they read). It updates as the
    readout would, at most once a second, in the order **Speed on top** sets.
  - **App icon**: NetworkMonitor's own icon, with no speeds.

  Click the icon for the main window, on the section it was last on. Its menu has what the
  readout's right-click menu has, the Dock's own Quit included; with Speeds it starts with
  the speeds in words, which is how VoiceOver reads them there. There's no popover in this
  mode: a speed test that needs your OK on a hotspot asks on the **Live** page.
- **Both**: the readout in the menu bar, and a Dock icon all the time. The same **Dock
  icon** choice appears under it, with **App icon** to begin with, so the Dock icon is the
  app's until you choose **Speeds**. Dock and Both each keep their own choice.

There's no choice of neither: there'd be no way back to the app.

## The popover

- **Live**, at the top beside the four squares and the gear, shows the download and upload
  speeds right now, in your speed colors, with a small graph of the last minute while
  another view is open (#802, #812). Click it for the Live view, where the popover opens.
- **Four buttons**: **Data**, **Connections**, **Ads blocked** and **Network**, each with
  its figure. Click one to see its view underneath. The colours are the same everywhere in
  the app: data blue, connections teal, blocked red, hotspots orange.
- **Today | Week | Month**, at the top of Data, Connections and Ads blocked, sets their
  period: today, this week or this month so far, on every network, read from Usage History.
  It sets what their buttons count too, and the popover opens on the period you chose last.
  Live and Network are about now, so they don't have it (#812).
- **Live** graphs download and upload together over **1 min**, **5 min** or **15 min**,
  lists the apps using the network now with their download and upload speeds, fastest
  first, and has the [speed test](speed-test.md): the last result and **Test Speed**.
- **Data** lists the **Apps** or the **Networks** that used it, biggest first, each with a
  bar for its share. The apps re-sort live as they overtake each other, and a dot marks
  apps moving data right now.
  - **Helpers fold into their app**: Chrome's dozen helper processes are one *Google
    Chrome* row, and the pages Safari, Mail or another app loads through macOS's WebKit are
    that app's (#761).
  - **Copies of one app are one row**: a build of an app you have installed counts as
    that app when its maker signed it; every other copy of it is one row of its own,
    *Home Control (other copies)*. An iPhone or iPad app in Xcode's Simulator is one row,
    *Home Control (Simulator)*, however often it's reinstalled.
  - **Commands break out beneath the app that started them.** Open iTerm2 or VS Code to
    see the `node`, `git` or `curl` it launched, each with its own figure. More than four
    become *Other (n)*.
  - **System**: macOS's own daemons collapse into one row at the bottom. Open it when
    you're curious.
- **Connections** groups who your apps talked to by **Companies**, **Countries** or
  **Apps**. Each app talking to a server counts once. A company or country opens into its
  apps, an app into its companies.
- **Ads blocked** opens on a bar that says whether ad blocking is on now, with **Pause**:
  **For 1 Hour**, **Until Tomorrow** or **Whenever on** *this network*, as in the window. While
  it's paused the bar says until when, with **Resume**; while it's off on this network,
  **Turn On Here** (#600). Under it, the **Sites** or the **Apps**, busiest first. A site
  opens into the apps that tried it, an app into the sites it tried. While ad blocking is
  off, it offers **Turn On**.
- **Network** shows the connection the Mac is on; its addresses: **This Mac** on the
  network, and **Internet**, the address websites see, with where it is (country and
  provider), each with a copy button (#803); and a **This is a hotspot** switch, on every
  network because some phones aren't recognised. While Live is hidden, the speed test is
  here. The internet address is asked of an outside service, so it's off until you click
  **Show** and say yes, or turn on **Look up the internet address** in Network's settings
  ([privacy](privacy.md#what-it-sends)).
- **Which views show, and the buttons' order**, are yours to choose in **Settings ›
  Popover**.
- **Open …**, at the bottom of each view, opens that section of the main window on the same
  period: **Open Usage History** (⌘Y), **Open Connections** (⌘K), **Open Ads and Trackers**
  (⌘B) or **Open Network**. The **four squares** beside the gear do the same, and open the
  **Live** page (⌘L) from Live. The **gear** opens Settings.
- **Lines under the buttons** say what needs saying:
  - a hotspot you've joined that the Mac isn't using, with how to switch behind an ⓘ;
  - on a hotspot with [Hotspot mode](hotspot-mode.md) on, an update that downloaded anyway;
  - **Everything is blocked**, with **Turn Off**, while Block Everything is on;
  - ad blocking paused, or off on this network: click it for Ads blocked and its
    **Resume**;
  - **Per-app figures paused**, in grey, if macOS's `nettop` can't be started.
    NetworkMonitor keeps retrying, and the total keeps counting regardless.

A list holds six rows and part of a seventh, so a cut-off row tells you there's more. It
keeps one height whichever grouping you choose. Esc or a click elsewhere closes it.

## A total per connection

The popover counts every network. The **Network** page counts the one you're on: join a
different Wi-Fi network or hotspot and its total starts from zero, so what you see is what
*this* connection has used. Open your hotspot somewhere new and you know exactly what it
cost. To compare networks over a period, choose **Networks** under Data in the popover.

- **A dropout and a reconnect** to the same network picks up where it left off.
- **It resets at midnight** too, for a connection you never leave.
- **It survives restarts**, and a relaunch on the same network carries on.
- **Reset Now** (Settings › Popover totals) starts the current network's total over.
- **Counting since** (Settings › Popover totals) shows when the current total began.

Networks are told apart by their router's hardware address, which needs no permission,
and named after their Wi-Fi network. macOS shares the name only with Location
permission, which the app asks for once; refused, a network is named like
*Wi-Fi · 3f2a*.

Every hour of every network goes to [Usage History](usage-history.md).

## Internet only

Mirroring to an Apple TV, Time Machine to a NAS, a Plex stream from your own server: these
cross your Wi-Fi but cost no internet data, so they're never counted. An app that only
talked to your own network doesn't appear at all. See
[accuracy](accuracy-and-battery.md#internet-not-your-own-network).

## Usage History

Every hour, per app and per network, for as long as you choose. Look back by day, week,
month or year; see each visit to a network as a session; narrow everything to one app, one
network or every hotspot at once; export it as CSV. See [Usage History](usage-history.md).

## Connections

Which companies your apps send data to, from which apps, in which countries, and to which
servers: grouped by company, app or country, narrowed by clicking, searched, read hour by
hour on a chart, and shaded on a world map that pulses to where your apps reach right now. Nothing is looked up
online. Block a company, app, country, site or server, or have it ask the first time an app
connects; **Rules**, beside Traffic and Blocked, lists every rule with what it did. See
[Connections](connections.md).

## Ads and Trackers

One switch blocks ads, trackers and malware sites in every app. **Overview** shows what was
blocked in the period, on a chart and by site and app, both used as Usage History's are:
hover or click a bar, choose or open a row (#536); **Log** shows each connection live,
as the filter decides it; **Rules** lists your own, as Connections lists its (#592). The
lists are in its settings, with **Enhanced ad blocking**, which also removes the ads inside
pages and videos in your browsers (#685). See [Ads and Trackers](connections.md#ads-and-trackers).

## Speed test

One click runs a fresh test with the tool built into macOS: download, then upload, then
ping, jitter, and ping under load, in Mbps or MB/s. If another app was competing for the
line, the result names it. On a hotspot it asks first. See [Speed test](speed-test.md).

## Hotspot mode

One switch, on the Network page, stops your apps updating while you're on a mobile hotspot,
puts the connection in Low Data Mode, and tells you which apps it can't stop. See
[Hotspot mode](hotspot-mode.md).

## The main window

One window with a sidebar: **Live**, **Usage History**, **Connections**, **Ads and Trackers**
and **Network**, in the popover's order, with **Settings** pinned at the bottom. Hide the sidebar
with its button or **View › Hide Sidebar** (⌃⌘S). When a new version is out, a card above
**Settings** offers it, or says it's about to install, or that it did
([Update](installing.md#update)).

Each section's toolbar starts with the view: **List, Both or Chart** in Usage History and
Ads and Trackers, **List, Both or Map** in Connections (#524); Both is always the list on
the left and the chart or the map on the right (#534). It has the period (**Day,
Week, Month, Year**) in the middle, then
**‹ Today ›**, a search button that opens into a field (⌘F), and a **gear**. The gear shows
that section's own settings in place, with a back button. Live and Network are about now,
so Network has only the gear, and Live its graph's **1 min | 5 min | 15 min** on the page.

Every section uses the window's whole width (#825). On a wide window, Live puts the apps
under the graph on the left, filling the window's height and scrolling inside themselves,
and the speed test in a column of its own on the right, with your last result. On a
narrower window the test is under the apps, whose list keeps the height of eight rows, so
the test stays in the same place however many apps come and go. Settings and Network run
each row from edge to edge, its control at the right.

| Section | What's in it | Behind its gear |
|---|---|---|
| **Live** | The download and upload speeds now, and the fastest in the graph · a graph of both over 1, 5 or 15 minutes · every app using the network now, with its speeds · the speed test (#812) | Show the test in the popover as Card or Compact |
| **Usage History** | The period's use by network type, then its apps, networks or sessions · Export CSV… | Keep history for · Clear History… |
| **Connections** | Who your apps talked to, on a list and a map, or what was blocked · Rules: every rule you've made, with what each did | Website names, Turn On… while they're off · Let apps connect · Your rules: Show Rules…, Import… and Export… · Encrypt lookups · Opens with List, Both or Map · Where the names come from, and Update them monthly |
| **Ads and Trackers** | Overview: the period, a chart, sites or apps · Log: each connection as the filter decides it · Rules: your own, with what each did | Block ads and trackers · Update the lists weekly · Your rules: Show Rules…, Import… and Export… · Lists |
| **Network** | The connection you're on · This is a hotspot, and what it's detected as Right now · Traffic through a proxy or VPN, counted for each app ([how](accuracy-and-battery.md#through-a-proxy-or-a-vpn)) · Stop apps updating on hotspots, what's paused and what can't be paused | Look up the internet address |

## Settings

**Settings** (⌘,), at the bottom of the sidebar, holds what applies to the whole app.
What a row means is behind an ⓘ beside it, which appears when you point at the row (#185,
#189).

- **Language**: the Mac's, or one chosen for the app
- **Start at login**
- **Show NetworkMonitor in** the Menu bar, the Dock or Both, and with the Dock or Both, **Dock icon**: Speeds or App icon
- **Updates** ([how it updates](installing.md#update)): your version, when it last checked and Check Now, **Check for updates automatically**, **Install updates automatically** and **Get beta versions**
- **Show speeds in** MB/s or Mbps
- **Wi-Fi names**, until they're on
- **Speed colors** (the readout's and the Dock icon's): six ready-made pairs, Custom… for your own Download and Upload, the speed test's colours, and **Speed on top**
- **Popover**: a tick to show or hide each of Live, Data, Connections, Ads blocked and
  Network, and the buttons' order: drag a row, or use its ↑ and ↓. Live stays on top, one
  view always shows, and so does Live or Network, which hold the speed test. The popover
  opens on Live, or on the first view shown while Live is hidden. **Show All, in the
  Original Order** puts them back (#802).
- **Popover totals**: Counting since, Sampling, Reset Now
- **Sections**: a row to each section's settings, the same pages its gear shows

**About NetworkMonitor**, in the right-click menu and the app menu, is the standard About
window: the version, links to the website, what's new and the source code, and the licence.

While the main window is open, NetworkMonitor has a Dock icon and a menu, so ⌘W, ⌘,, ⌘Y,
⌘K, ⌘B and ⌘F work and ⌘-Tab can find it. It goes back to living in the menu bar when you
close it, unless it's set to show in the Dock or both.

With the main window open behind another app, a click on the menu bar item shows only the
popover, and the window stays behind. ⌘-Tab or the Dock icon shows the window on its own.

## Staying out of the way

- No Dock icon, no app switcher entry, no window to manage. Just the menu bar, unless you
  choose the Dock or both.
- **Starts at login** by default, once. Turn it off in Settings and it stays off.
- **Quit stays quit.** Quitting ends it for the session without turning off Start at
  login, and turning that off doesn't quit the running app.
- Works with the menu bar set to hide automatically: the popover stays open while the bar
  hides, and the main window stays in front.
