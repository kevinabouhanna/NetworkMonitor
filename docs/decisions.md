# Decisions

Why NetworkMonitor works the way it does. Read this before changing something that looks
odd: most odd-looking things were the second or third attempt.

## Principles

- **Under-reporting is the one error it can't afford.** Anything ambiguous counts as
  internet traffic. A total that's slightly high is an annoyance; one that hides real usage
  defeats the app.
- **Few permission prompts, and each one optional.** Networks are identified without any
  permission. The welcome window offers the two that add something, Wi-Fi names (Location,
  #85) and website names (the content filter, #128), each said as what you get (#134). The
  only password ever asked for is optional, for Hotspot mode's helper.
- **No network access of its own.** The only traffic it causes is a speed test you start.
- **Nothing to configure where the app can decide.** Sampling rates follow the power source;
  Hotspot mode is one switch with no list to maintain. A switch that needs configuring to
  work has failed.
- **Never lose a byte to save power.** Sample less often, never count less.
- **Say what it decided.** Settings states the sampling mode, why a connection counts as a
  hotspot, what was paused, what wasn't, and what got through anyway.
- **Real numbers.** Measurements are measured, screenshots are real captures, and limits
  are stated rather than hidden.

## Decision log

Newest last. Links go to the commit or pull request.

| Date | Decision | Why |
|---|---|---|
| 2026-07-31 | Kernel counters via `sysctl(NET_RT_IFLIST2)` ([8f5823a](https://github.com/kevinabouhanna/NetworkMonitor/commit/8f5823a)) | `getifaddrs()` counters are 32-bit and had already wrapped: 1.23 GB shown for a true 5.52 GB |
| 2026-07-31 | `nettop` in delta mode, on a pseudo-terminal ([8f5823a](https://github.com/kevinabouhanna/NetworkMonitor/commit/8f5823a)) | Cumulative totals fall when sockets close; through a pipe it block-buffers and delivers nothing for ~30 s |
| 2026-07-31 | Networks identified by the gateway's hardware address ([8f5823a](https://github.com/kevinabouhanna/NetworkMonitor/commit/8f5823a)) | The Wi-Fi name needs Location permission; the gateway address separates routers sharing a name and survives roaming |
| 2026-07-31 | Apps identified by the outermost `.app` in a process's path ([8f5823a](https://github.com/kevinabouhanna/NetworkMonitor/commit/8f5823a)) | Collapses helper processes into their app; process names are truncated to 15 characters |
| 2026-07-31 | The test suite is a plain executable ([8f5823a](https://github.com/kevinabouhanna/NetworkMonitor/commit/8f5823a)) | XCTest and swift-testing ship only with Xcode |
| 2026-07-31 | The readout is two lines drawn into an image at 8.5 pt, at a fixed width ([792641a](https://github.com/kevinabouhanna/NetworkMonitor/commit/792641a)) | `NSButton` clipped multi-line titles at every size; nothing beside it should move |
| 2026-07-31 | Start at login through `SMAppService.mainApp`, after briefly using a LaunchAgent ([c2e08e1](https://github.com/kevinabouhanna/NetworkMonitor/commit/c2e08e1)) | The LaunchAgent showed as a generic "exec" tile; `SMAppService` was proven to work with an ad-hoc signature |
| 2026-07-31 | One instance only; no `KeepAlive` ([390c646](https://github.com/kevinabouhanna/NetworkMonitor/commit/390c646)) | Two copies double-count every byte; `KeepAlive` would make Quit a no-op |
| 2026-07-31 | Versions stamped from git; releases built from tags; a smoke test in CI ([859c607](https://github.com/kevinabouhanna/NetworkMonitor/commit/859c607)) | A hardcoded build number would block every future update; a crash on launch is the worst bug an updater can ship |
| 2026-08-01 | **`nettop`'s stdin is a pipe nobody writes to**, and per-app tracking always runs ([4c4eb9c](https://github.com/kevinabouhanna/NetworkMonitor/commit/4c4eb9c)) | With `/dev/null` it spun at ~140% of a core; with a pipe, 0.55%. The battery modes existed only because of that cost, and switched attribution off on hotspots, where it matters most |
| 2026-08-01 | **A total per connection**: joining a different network starts over; offline is a gap, not a switch ([4c4eb9c](https://github.com/kevinabouhanna/NetworkMonitor/commit/4c4eb9c)) | The question is what *this* connection cost; a flaky link mustn't wipe the count |
| 2026-08-01 | Sampling rates follow the power source, with no setting ([4c4eb9c](https://github.com/kevinabouhanna/NetworkMonitor/commit/4c4eb9c)) | Deltas lose no bytes, only freshness |
| 2026-08-01 | The readout is published only when its text changes ([54506ce](https://github.com/kevinabouhanna/NetworkMonitor/commit/54506ce)) | Every publish re-laid out the hidden popover twice a second |
| 2026-08-01 | **Internet only**: classify each connection's remote address, subtract LAN unicast, clamp ([4e64478](https://github.com/kevinabouhanna/NetworkMonitor/commit/4e64478)) | AirPlay, Time Machine and SMB counted as internet; `-n` avoids the monitor making DNS traffic |
| 2026-08-01 | Multicast is never subtracted ([30a8d3c](https://github.com/kevinabouhanna/NetworkMonitor/commit/30a8d3c)) | `nettop`'s multicast figure exceeded what the interface could physically carry by 12.6× or more |
| 2026-08-01 | Processes outside an app are adopted by the app that launched them ([a4c5a4b](https://github.com/kevinabouhanna/NetworkMonitor/commit/a4c5a4b)) | Tools started from editors and terminals were the top consumer, hidden under System |
| 2026-08-01 | The popover's height is computed from its rows; it's anchored to an invisible window ([09f627e](https://github.com/kevinabouhanna/NetworkMonitor/commit/09f627e)) | Measured heights start at zero; with an auto-hidden menu bar the popover jumped to the screen's left edge |
| 2026-08-04 | **Hotspot mode**: six ranked signals; per-app settings, a config-file edit, and a root helper for the rest ([be754a8](https://github.com/kevinabouhanna/NetworkMonitor/commit/be754a8)) | Each app exposes a different mechanism; blocking update hosts would break VS Code Remote-SSH and take Claude offline |
| 2026-08-04 | Every change is journalled before it's made ([be754a8](https://github.com/kevinabouhanna/NetworkMonitor/commit/be754a8)) | The failure to prevent is a Mac that silently stopped updating months ago |
| 2026-08-04 | The helper is a sudoers-gated root binary with fixed verbs, not an XPC daemon ([be754a8](https://github.com/kevinabouhanna/NetworkMonitor/commit/be754a8)) | XPC client checks need a Developer ID team; a tiny argument-free vocabulary limits what root can be asked |
| 2026-09-08 | The app list re-sorts live ([f740eb7](https://github.com/kevinabouhanna/NetworkMonitor/commit/f740eb7)) | Freezing the order hid a large download under tiny apps; samples now close after 120 ms of quiet |
| 2026-09-29 | Builds with Command Line Tools 27: no `@State`, native build system, per-architecture builds joined with `lipo` ([4eb8f8c](https://github.com/kevinabouhanna/NetworkMonitor/commit/4eb8f8c)) | `@State` is an Xcode-only macro; `swiftbuild` fails; `--arch` twice needs Xcode |
| 2026-09-29 | A drag-to-Applications disk image with a versionless name ([d91ca04](https://github.com/kevinabouhanna/NetworkMonitor/commit/d91ca04)) | A stable "latest download" link for the website |
| 2026-10-20 | **Speed test** with macOS's `networkQuality`, sequential, plus a ping-only pass; no RPM ([6993190](https://github.com/kevinabouhanna/NetworkMonitor/commit/6993190)) | Nothing to install or maintain; sequential like other tests; one batch of idle pings is too noisy |
| 2026-10-22 | Popover semi-transient; Settings makes the app regular while open ([7d44ecd](https://github.com/kevinabouhanna/NetworkMonitor/commit/7d44ecd), [76bfdb5](https://github.com/kevinabouhanna/NetworkMonitor/commit/76bfdb5)) | Revealing an auto-hidden menu bar activated another app, closed the popover and buried Settings (#6) |
| 2026-10-22 | **Low Data Mode through interface flags** ([e2415b9](https://github.com/kevinabouhanna/NetworkMonitor/commit/e2415b9)) | One mechanism for Wi-Fi and tethers, nothing on disk, cleared by a restart |
| 2026-10-22 | "Not covered" found by updater shape; "got through" watched ([e2415b9](https://github.com/kevinabouhanna/NetworkMonitor/commit/e2415b9)) | A list of names can't reach every Mac; the gaps should be visible |
| 2026-10-22 | No Terminal: the helper is installed from the app through the administrator dialog ([e2415b9](https://github.com/kevinabouhanna/NetworkMonitor/commit/e2415b9)) | The dialog needs no Developer ID, and users shouldn't need Terminal |
| 2026-10-22 | The release workflow publishes the disk image ([fbcd80c](https://github.com/kevinabouhanna/NetworkMonitor/commit/fbcd80c)) | Older release notes sent people to clone, build and clear quarantine by hand |
| 2026-10-23 | **Usage History** in SQLite, hourly per app per visit, never reset by Reset Now or midnight ([ddd2423](https://github.com/kevinabouhanna/NetworkMonitor/commit/ddd2423), #3) | Yesterday's usage was lost by design; about 5 MB a year, a year's query in ~30 ms |
| 2026-10-23 | One "Show speeds in" choice for the menu bar and the speed test; bytes by default ([ebde6c7](https://github.com/kevinabouhanna/NetworkMonitor/commit/ebde6c7), #4) | Two places disagreed; upgrading mustn't change the menu bar |
| 2026-10-23 | The speed test as a Card or a Compact strip; the menu bar always shows a running test ([e6cef5e](https://github.com/kevinabouhanna/NetworkMonitor/commit/e6cef5e)) | The popover's tallest size never changes; the old switch changed nothing visible |
| 2026-10-23 | Every change goes issue → pull request → release (#9) | A written workflow every contributor follows |
| 2026-10-23 | **Settings as toolbar panes**, following Apple's guidelines; Usage History moves in (#11) | One long, cramped column; features hidden behind unlabelled icons |
| 2026-10-23 | **Battery**: nothing drawn while nobody can see the menu bar; a Low Power Mode profile (#22, #1) | What remained after the `nettop` fix was drawing the readout: 1.19% of a core on battery, now 0.47% with the screen off and 0.53% in Low Power Mode |
| 2026-10-23 | Hotspot lists say how each app is paused, or why it can't be, in plain words (#40) | "Apps paused" read as happening already, and "electron-updater" or "Sparkle, sandboxed" explained nothing to someone new |
| 2026-10-24 | Settings is never taller than the screen; a taller pane scrolls (#46) | With both Hotspot lists open, the window ran off the bottom of the screen |
| 2026-10-24 | Settings' toolbar takes clicks while a pane is still changing (#55), and the window keeps its centre when it does (#57) | `NSTabViewController` ignored those clicks: a tab clicked within about 0.3 s of the last did nothing. Allowing them let Auto Layout resize the window first, from its left edge, walking it 60 pt left per switch around History |
| 2026-10-25 | Settings › Hotspot loads in the background, marks only changes that are really waiting for an app to quit, and gives a pane a scroll bar only while it scrolls (#65) | Opening it asked the helper twice on the main thread (about 260 ms) and rescanned the apps; *quit it to apply* showed whenever the app was open, on any network; a scroll bar that came and went left a wrapped line's height behind |
| 2026-10-25 | Settings is one width, 720 pt, for every pane, and changes panes at once, with no crossfade (#61) | The crossfade ran about 0.7 s per switch and let a scroll bar flash on the way out of a taller pane; History at 768 pt and the rest at 648 pt made the window change width |
| 2026-10-24 | **Menu bar colors** can be changed; a speed test's colours follow, kept clear of them (#45) | Colour is the only thing that tells a test's figures from the live rates, so a live colour that matched the test's would hide which is which |
| 2026-10-25 | **The gateway's address is read from configd**, then `arp` (issue #70) | macOS 27 hides the ARP table from apps without Local Network permission, so every Wi-Fi network had become one. configd needs no permission, and asking for it would mean a prompt after every ad-hoc-signed update |
| 2026-10-25 | **History's All / Wi-Fi / Hotspot switch** replaces Metered only, opens on Hotspot while you're on one, and app bars are split by network type (issue #70) | A day on Wi-Fi and a hotspot should read as two parts, everywhere in the pane. Hotspot is a kind of network, so it filters by kind and matches the chart's colours; Metered only was nearly the same set under another name |
| 2026-10-25 | **Wi-Fi names, with Location, always on** (issue #85) | "Wi-Fi · 9493" told people nothing. macOS 27 shares the name only with Location, so the app asks a few seconds after launch, with no setting. The name is only a label: the router's address stays the identity, and a router's two band names are both kept |
| 2026-10-25 | **Every build signed with one self-signed certificate** (issue #86) | Ad-hoc signatures made each update a new app to macOS, which asked for Location again. A fixed certificate gives every build the same designated requirement; checked, an update with it wasn't asked. The key stays out of the repo: in `~/.config/networkmonitor-signing/` and two repository secrets |
| 2026-10-29 | **Connections keeps each app's servers**: `nettop`'s internet connection rows, by address, hourly, per visit (#111) | The rows were already parsed for the LAN split and thrown away. Keeping them needs no new permission and no new process. Each app and server pair is stored once, so an hourly row holds a small number rather than an app's path |
| 2026-10-29 | **Servers are named from DB-IP Lite, shipped in the app** (#111) | No lookups online: asking a service about each address would tell it every server the Mac talks to. DB-IP's free data is CC BY 4.0. Converted to sorted range starts with the narrowest label width that fits, and IPv6 keyed on its first 64 bits, it's 13 MB, from 60 MB of CSV |
| 2026-10-29 | The converted data is committed, not downloaded at build time (#111) | DB-IP removes each month's files once the next is out (a 2025 month already returns 404), so a pinned download would break, and an old tag could never be rebuilt |
| 2026-10-29 | Networks that host other companies are marked as hosts (#111) | Until server names arrive, the owner of a network is the only clue. That's right for Google or Microsoft, and wrong for anything on Amazon's or Cloudflare's network, which would otherwise all be blamed on them |
| 2026-10-29 | **Connections is a window of its own**, opened from the popover's globe and ⌘K (#112) | It's read beside other work and wants room: resizable, which Settings' fixed 720 pt can't be, and wider again once the map sits beside the list (#113) |
| 2026-10-29 | **Grouped by company first**; a company opens into its apps, countries and servers (#112) | Which companies get your data is the question. Apps and Countries are the same hierarchy turned around |
| 2026-10-29 | Hosted traffic reads *Hosted on Amazon*, marked HOST, and never counts as talking to Amazon (#112) | The network's owner is the only clue until server names arrive; for clouds and CDNs it names the landlord, not the tenant |
| 2026-10-29 | Each app shows its maker from its code signature (#112) | Reading a signature's certificates is quick, offline and needs no permission, and "by Microsoft, also talks to Google" is the line worth reading |
| 2026-10-29 | **Signed with the Developer ID and notarized**; the app first, stapled, then the disk image (#119) | Ends Open Anyway. Stapling both means the first open works offline. The self-signed certificate stays as the fallback for builds without the Developer ID, so contributors can still build |
| 2026-10-30 | **The map is drawn by the app** from Natural Earth's outlines, projected with Equal Earth and simplified at build time to 99 KB (#113) | No map tiles, so no map service learns where you look, and nothing to download. Equal Earth keeps areas true, so a big shaded country is big |
| 2026-10-30 | Anycast networks (Cloudflare, Fastly and others) are listed beside the map, not painted (#113) | DB-IP files their addresses under one country, but the answer came from the nearest data centre: on a Mac in Lebanon, Cloudflare read as Canada |
| 2026-10-30 | The map redraws on its own only while Live is on, and Live switches off when the window closes (#113) | A still map costs nothing; animation is opted into, and never runs where nobody can see it |
| 2026-10-30 | **Connections' controls are a window toolbar** plus one labelled row, as Calendar and Finder lay theirs out (#123) | Six controls in four sizes across three rows read as all over the place. The view, the period and search are the window's; what the list is grouped by and narrowed to belongs to the list |
| 2026-10-30 | **Usage History reads as Connections does**: the period and ‹ Today › side by side with All / Wi-Fi / Hotspot in one row, then the heading, with the chips beside it (#125) | The same controls were scattered there too. The parts are shared (`PeriodControls.swift`), so the two windows can't drift apart |
| 2026-10-30 | **Settings › Connections**, a pane like every other feature's (#126) | People look for a feature in Settings. It says what Connections is, opens it, shows today's top companies, sets the layout it opens with, and says where the names come from |
| 2026-10-30 | **The content filter is a system extension** that allows everything and reports each flow's name over XPC, turned on only from Settings › Connections (#128) | Server names turn *Hosted on Amazon* into the company behind it, and it's the base the firewall's rules are enforced through. It fails open, and both ends check the other's signature by team |
| 2026-10-30 | Companies come from a server's name before its network's owner (#128) | The owner names the landlord; the name names the tenant. A host's own domains (cloudfront.net, akamaiedge.net) still defer to the owner |
| 2026-10-30 | **Permissions are set up in a welcome window**, each as what you get, not a switch in Settings that says how it works (#134) | "Server names" and "a content filter" didn't tell anyone why to turn it on. On first launch the welcome window offers website names and Wi-Fi names, both optional, with the steps macOS needs shown while it waits. Said no, each has a **Turn On…** where it's used. Location is no longer asked for by itself at launch, and **Stop Filtering** left the menu: it blocked nothing |
| 2026-10-30 | **Blocking by rules made in Connections**, enforced by the content filter (#114) | One rule per company, app, country or server: Block, Block on Hotspots or Always Allow, the narrowest winning. "Monitor" and "Custom" were the same once your rules always win, so the modes are one choice, Anywhere or Only where I allow, the second coming with blocked attempts in the window. The filter keys connections as Connections does, so a rule means the row it was made on |
| 2026-10-30 | **Hotspot mode stops every app's updater at the network** (#98) | The settings and hosts it changed reached only apps someone had researched. With the content filter, any program inside an app named like an updater, Sparkle's downloader, or an updater of its own is blocked on a hotspot, and so are the helper's update-only servers, from one list in `HostsFile`. Apple's code is left to the system setting, so an update started by hand goes, and your rules win |

## Approaches turned down

| Approach | Why not |
|---|---|
| `getifaddrs()` counters | 32-bit, wrap every 4 GiB |
| `nettop` cumulative mode | totals fall when sockets close, under-counting browsers |
| A pipe for `nettop`'s output | block-buffered: data arrives in ~30-second bursts |
| `/dev/null` or an inherited stdin for `nettop` | it spins at ~140% of a core |
| `FileHandle.availableData` on the PTY | raises an Objective-C exception Swift can't catch |
| `nettop -P` | one row per process, losing the remote address needed for the LAN split |
| Switching per-app tracking off on battery | the cost was a bug; it switched attribution off on hotspots |
| Subtracting multicast from the total | made the total smaller than its own rows |
| The Wi-Fi name (SSID) as identity | many networks share a name, and one router can have two; it's a label instead (#85) |
| The access point's address (BSSID) as identity | changes on every roam |
| Resetting on every path change | path changes fire several times per event; would wipe hotspot totals |
| A rolling 24-hour reset | drifts to arbitrary hours; midnight matches how carriers count |
| A digits-only monospaced font in the menu bar | width wandered between 97 and 126 points |
| A two-line `NSButton` title | clipped the top line at every size |
| A template image for the readout | recoloured to monochrome, losing the green |
| A LaunchAgent for start at login | generic "exec" tile in Login Items without a Team ID |
| Freezing the app list's order while open | big downloads sat under tiny apps |
| A variable-height popover | re-anchored many times per animation and jumped |
| A Network Extension content filter for Hotspot mode | blocking traffic is the wrong tool for stopping updates, and it needs a Developer ID |
| Unloading updaters' LaunchAgents | puts the app in the business of managing background items; churns Login Items |
| Blocking update hosts for every Electron app | breaks VS Code Remote-SSH and the Claude app |
| Pausing (`SIGSTOP`) an update already downloading | the download belongs to a system daemon; servers time out; a stopped process gets stranded |
| Writing settings while the app is running | the app writes its own settings back on quit |
| A built-in list of updater names | rots, and describes one machine |
| A per-app list or allowlist for Hotspot mode | a switch that needs configuring has failed |
| Telling security updates from feature updates | not reliably possible |
| `launchctl disable` | persists across reboots and outlives the app |
| System Settings' stored Low Data Mode setting | reaches wired connections only |
| Ookla's CLI, M-Lab NDT, our own speed test engine | licence; publishing users' IPs; worse than the one on every Mac |
| `networkQuality` in parallel mode | upload and download compete and both read low |
| A time limit (`-M`) on the speed test | a capped run drops figures that hadn't converged |
| Showing RPM / responsiveness | Apple's own unit, blending latency inside saturated connections with what other apps feel |
| JSON for Usage History | wrong shape for range queries and sums |
| Importing usage from before History existed | it has no hours; spreading it out would invent data |
| Four pop-up menus to filter History | the lists themselves are the filters |
| `@testable import` | compiled in debug but broke release builds |
| Reverse DNS to name servers | Sends a query for every address, so the monitor would make traffic, and the answers are often meaningless (`1e100.net`) |
| A geolocation service online | Tells a third party every server the Mac talks to |
| Downloading DB-IP's data at build time | Old months are removed, so builds would break and old tags couldn't be rebuilt |
| Map tiles from Apple Maps or OpenStreetMap | Every pan and zoom would tell a map service where you're looking; outlines drawn locally need nothing |
