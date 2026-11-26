# Phase 1: Everyday polish

**Milestone:** Phase 1: Everyday polish · **Status:** Next

**Goal:** what people touch every day feels finished: the popover never jumps, the main
window's three lists behave the same, and the VoiceOver and keyboard work of 1.29 is checked.

## The plans

- **Does the app count a virtual machine's data, connections and ads?** (#738), Next, research:
  Kevin asked what the menu bar and the main window show for what a VM does online. First signs
  (25 Nov 2026): the total probably has it, the app rows may not, and Connections and ad blocking
  are unchecked. It's measured in a VM, then decided: the docs only, a row for it, or a fix. After
  the update settings (#710), before the Chrome extension (#257), which is weeks of work.
- **Safari's Private Relay traffic has no row** (#754), Later, research: reported by defragekb.
  Not by capturing internet packets (#749), which costs too much CPU and privacy: whether the
  content filter's own byte counts cover it is what's to find out.

Done on 26 Nov 2026, on `main`, for the next release:

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
