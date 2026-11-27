# Phase 1: Everyday polish

**Milestone:** Phase 1: Everyday polish · **Status:** Now

**Goal:** what people touch every day feels finished: the popover never jumps, the main
window's three lists behave the same, and the VoiceOver and keyboard work of 1.29 is checked.

## The plans

- **Does the app count a virtual machine's data, connections and ads?** (#738), Next, research:
  Kevin asked what the menu bar and the main window show for what a VM does online. First signs
  (25 Nov 2026): the total probably has it, the app rows may not, and Connections and ad blocking
  are unchecked. It's measured in a VM, then decided: the docs only, a row for it, or a fix. After
  the update settings (#710), before the Chrome extension (#257), which is weeks of work.
- **The menu bar stays shown while the popover is open** (#795), Now, a bug Kevin found with
  the menu bar on auto-hide: macOS holds the bar for its own menus, but not for an
  `NSPopover`, so the popover is left under an empty strip.
- **Safari's downloads over Private Relay count for everyone with the content filter on**
  (#821), Now: with Relay on, nettop sees none of Safari's traffic (#754, reported by
  defragekb). The content filter's received-byte counts fill the gap: per app and hour, only
  what it counted beyond nettop, out of the bytes nobody claimed, so the total never changes.
  Downloads only; sent bytes stay as they are. The trial is in 1.35.0 beta 5 behind a hidden
  switch; it's on for everyone once defragekb's signed run and the CPU cost bear it out, with
  the docs saying what's left out.
- **A finished macOS upgrade counts for Software Update** (#809), Now, a bug reported by
  defragekb: 17.8 GB stayed under `nsurlsessiond` because the log names its client
  `softwareupdated`, not a bundle identifier, which the owner lookup of #767 doesn't read.
- **Light, Dark or System for the Dock's speeds** (#807), Now, asked for by defragekb: the
  Dock icon's look chosen apart from the Mac's, remembered across launches. Kevin chose in its
  design artifact (27 Nov 2026): an **Appearance** switch, System · Light · Dark, under Dock
  icon while it's Speeds, one choice for Dock and Both.
- **Settings' switches change with ← and →, as the toolbar's do** (#830), Next, found while
  building #807: the keyboard tour reaches each one, named, but its arrow keys don't change
  the choice. Checked with real keys in a VM first, then fixed or the tour taught, and held
  with a test for every Settings switch.
- **One refresh interval for the live speeds** (#808), Next, asked for by defragekb: Auto, or
  1–5 seconds, averaged over the interval, so the menu bar and the Dock agree.

Done on 27 Nov 2026, in 1.35.0 beta 2 (#792, as Kevin chose in its design artifact, from
defragekb's ask for what they open iStat Menus to see):

- **Live**, a line of the speeds now above the popover's buttons, and its view: a graph of
  download and upload over 1, 5 or 15 minutes, the apps using the network now with their
  speeds, and the speed test, moved from Network. The popover opens on it (#802).
- **Settings › Popover** shows or hides each view and orders the four buttons (#802).
- **Network** shows this Mac's address and, once you turn it on, the internet address with its
  country and provider: the first thing the app asks an outside service, so it asks first (#803).
- **Live, finished** (#812), from Kevin trying beta 3, as he chose in its design artifact:
  Today / Week / Month moved into Data, Connections and Ads blocked; the Live line beside ⊞
  and the gear, its small graph only while another view is open, in the speed colors chosen;
  and Live first in the main window's sidebar (⌘L), with the speed test moved there from
  Network. In 1.35.0 beta 4.
- **Safari with Private Relay, measured and decided** (#799): defragekb's signed runs on 1.35.0
  beta 1 showed the filter's received bytes hold over Relay (2,008,998 counted for a
  2,000,000-byte download nettop didn't see; to the byte on the direct path), Relay stays on
  with the filter, and the CPU cost is too small to measure in short runs. Its sent bytes
  don't hold: macOS adds a buffer's free space, not what's in it, and reading every sent packet
  (#816) costs too much, so uploads stay as they are. The build is #817.
- **The Private Relay download trial** (#817, #818): defragekb's #815, with review fixes, in
  1.35.0 beta 5, off unless switched on by hand. Turning it on for everyone is #821.
- **No "Live" caption under the popover's speeds** (#823), Kevin's ask from beta 4: the speeds
  say what they are, and the caption didn't line up with the graph beside them. In 1.35.0
  beta 6.
- **Live and Settings fill the window** (#825), as Kevin picked in its design artifact: Live's
  apps fill the left and scroll by themselves, the speed test has its own column on the right
  (under a list of eight rows on a narrow window), and Settings, Network and each section's
  settings run edge to edge. In 1.35.0 beta 7.
- **The Connections map's shades tell nearby amounts apart** (#797), as Kevin chose in its design
  artifact: six fixed steps with a key, under 1 MB up to 10 GB or more. In 1.35.0 beta 7.
- **Connections: no chart in List, Map | Chart in the corner, and "Showing only"** (#798), as
  Kevin chose in its design artifact, with **Show everything** in place of the filter chips in
  Connections, Ads and Trackers and Usage History alike. In 1.35.0 beta 7.

Done on 26 Nov 2026, released in 1.34.0 the same day (#778):

- Usage History left on **Today** moves on to the new day at midnight, and a period you chose
  stays (#770), reported and first written by defragekb (#771).
- **Speed on top** in Settings › Speed colors puts download or upload on top, in the menu bar
  and on the Dock icon (#772), asked for and first written by defragekb (#773, #783).
- Downloads an app hands to macOS count for that app in Usage History once they end (#767),
  reported and first written by defragekb (#768, #782): the owner comes from macOS's log after
  the close, since the content filter can't tell (a rule on the app didn't block its background
  download); checked on a signed build in a VM, where 44.1 MB of a test app's downloads moved
  to it. What doesn't match stays under the service.
- Connections and Ads and Trackers move on to the new day at midnight too (#776), found while
  reviewing #771: the three windows share one piece that follows the calendar.

Done on 25 Nov 2026, released in 1.33.0 on 26 Nov (#747):

- your own network's traffic on an unconnected UDP socket, as remote desktops use, no longer
  counts as internet (#753). Reported and first written by defragekb (#748), NetworkMonitor's
  first outside contributor; the helper counts it, looking only at packets between two addresses
  on your own network.
- what was seen on the network before isn't taken off the traffic of the one after (#759),
  reported and first written by defragekb (#760); and the helper's own-network counts hold in a
  signed, notarized build (#757): a test build (#704) in a VM.
- what Safari, Mail and other apps' web views load counts for the app, not System, and a rule on
  the app covers those pages (#761), reported and first written by defragekb (#762): macOS's
  responsible process, asked by the app and by the content filter alike; checked on a signed
  build in a VM, with a rule on Safari and one on WebKit.
- a late sample of a network keeps its own-network share on that network over an offline gap
  (#763), reported and first written by defragekb (#764): in 1.33.0.

Done on 25 Nov 2026, released in 1.32.0 (#722):

- the popover closes on a click in the app's own window, and stays still between its views
  (#728): the app listened only for clicks in other apps; and with a mouse connected, a long
  list's scroll bar made the popover's content 13 points wider than the popover, which slid the
  header 6 points left in Data and Connections. Reproduced and checked in a VM, and held by tests.

Done on 19 Nov 2026, on `main`, not released yet (releases are on hold until Kevin says):

- the menu bar readout reads on a light wallpaper too (#672): on a light bar every colour it
  takes is darkened to read, keeping its hue, and a speed test's are chosen clear of the live
  ones there; unchanged on a dark bar; it follows the wallpaper without a relaunch.
- ready-made speed colors (#688): six pairs (Green, Teal, Blue, Gold, Pink, Violet) that read
  on dark and light menu bars, and Custom… for your own.
- copies of one app are one row (#663): every iPhone Simulator install of an app is one row,
  *(Simulator)*; a build signed by the installed app's team is that app, and other builds of
  it are one row of their own, *(other copies)*. History already recorded is folded the same
  way, every byte kept.

Done on 17 Nov 2026, on `main`, not released yet (releases are on hold until Kevin says, #667):

- the popover's scroll bar keeps one size when the list scrolls past an opened entry (#660):
  its lists lay out every row rather than guessing the height of those off screen, checked in
  a VM in Today, Connections and Ads blocked, and held by a test.

Done on 13 Nov 2026, and shipped since:

- the popover keeps one height in all four views (#599);
- the main window's three lists expand, collapse and filter the same way (#593): a click
  anywhere on a row opens or closes it, the arrows stay, and filtering is the row's own
  **Filter** button (Kevin's revised option B, after he found "a click filters" misleading);
- the accessibility tests read the real main window, sidebar and all (#527);
- the sidebar's button and the search's glass read in the language shown (#621);
- the VoiceOver and keyboard checks after 1.29.0 (#525), which Kevin asked a session to do
  rather than him ("you do the test"): done in a VM, with View and Period now choosing with
  ← →.
