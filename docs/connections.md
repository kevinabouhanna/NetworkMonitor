# Connections

English · [简体中文](zh-Hans/connections.md)

Which companies your apps send data to, from which apps, in which countries, and to which
servers. It's a section of the main window: open it from **Open Connections** under
Connections in the popover, the four squares beside the popover's gear, **Connections…**
(⌘K) in the right-click menu, or the sidebar. Its settings, behind the gear in its
toolbar, also set the layout it opens with.

It runs quietly: until you make a rule or choose **Ask Me** (see [Blocking](#blocking)),
nothing pops up and nothing is blocked. NetworkMonitor records the servers each app talks
to as it already counts their data, and Connections shows them whenever you look.

## Reading the window

The toolbar holds the view (**List | Both | Map**), the period (**Day, Week, Month, Year**)
in the middle, **‹ Today ›**, search (⌘F) and the gear. The row under it says what's shown
(**Traffic** or **Blocked**), what the list is grouped by and narrowed to, and which
networks it covers. Then the period's name, its total, and the counts.

- **Group by Companies, Apps or Countries.** Companies is the default, because that's the
  question: who gets your data.
- **Open a group** to see what's inside it. A company opens into the apps that talk to
  it, the countries its servers are in, and the servers themselves. An app opens into
  its companies, countries and servers. A country opens into its companies, apps and
  servers.
- **Click a row inside a group** to narrow everything to it. Choosing Teams inside
  Microsoft reads *Microsoft › Teams*, and each chip's ✕ undoes its part.
- **Drag across the timeline**, or click a bar, to see one part of the day: what your
  apps contacted in the hour after a call, say. Click the same bar again, or the chip's
  ✕, for the whole period.
- **Search**, the magnifying glass in the toolbar, finds a company, a network's
  registered name, an app, a country or an address.
- **Day, Week, Month, Year**, the arrows and ⌘← ⌘→ move through time, as in every
  section, and **Networks: All / Wi-Fi / Hotspot** narrows it to one kind of network.
- **Under each app is who made it**, read from its code signature, and the companies it
  talks to besides its maker. Hosts aren't counted: an app on Amazon's network isn't
  talking to Amazon.

## The map

Connections shows the list, the map, or both side by side (**List | Both | Map**). Both is
the default, and whichever you choose is remembered. Too narrow for both, it shows
the list until you widen the window.

- **Countries are shaded by how much data went there**, on a logarithmic scale, so a
  country with a few kilobytes still shows beside one with gigabytes.
- **Hover a country** for a card with its top companies. **Click it** to narrow
  everything to it.
- **Narrow to a company, app or server**, and lines run from your country to where its
  data went. Your country is the first of these that knows (#231): **Location**, when
  NetworkMonitor already has it for Wi-Fi names (it never asks for it just for this);
  your Mac's **own internet address**, when it holds one the internet sees, such as an
  IPv6 address; or your Mac's **Region setting**. Hover the ring where the lines start
  to see which: *Your Mac, in Lebanon (from Location)*. Nothing is looked up online:
  the place Location gives is turned into a country with the map's own outlines, and
  only the country is kept.
- **Lines pulse to the countries your apps reach right now** whenever the map shows
  traffic for a period that includes now, with no switch to turn on (#182). Only the
  pulses redraw on their own, and nothing runs while Connections isn't on screen
  (another section, or the window closed, minimised or covered), while it shows Blocked
  or a past period, or while nothing is answering.
- **Drag to move, pinch or use the buttons to zoom.** Places too small to see at the
  current zoom, and places drawn inside another country such as Réunion, show as a dot
  when something went there.
- **Cloudflare, Fastly and similar networks aren't placed.** They answer each address from
  whichever data centre is nearest, so no one country is where the data went. The corner
  of the map says how much went to them.

The outlines are Natural Earth's (public domain), drawn by the app. No map service is
used and nothing is downloaded.

## What the names mean

A server is an address. NetworkMonitor names it from data shipped inside the app: the
country DB-IP places the address in, and the network it belongs to. Nothing is looked up
online. The data is refreshed once a month, the same signed file for everyone, never on a
hotspot; **Update them monthly** in Connections' settings switches that off, and the
month in use is shown there (#121). See
[privacy](privacy.md#naming-servers-without-asking-anyone).

- **A company** is the owner of the network the server is on. That's right for
  companies that run their own networks: Google, Microsoft, Meta, Apple and many more.
- **Hosted on Amazon** (or Cloudflare, Akamai, Fastly, Google Cloud and others), marked
  **HOST**, means the server is on a network that carries thousands of companies'
  traffic. The data can't tell which one, so NetworkMonitor doesn't guess.
- **Unknown network** is an address the data doesn't list: a private, carrier or VPN
  address such as Tailscale's.
- **Other servers** is what an app talked to past 500 servers in one hour, added up as
  one. Only peer-to-peer apps and large calls get there.
- **A country** is where DB-IP places the address. It isn't where the company is, or
  where data ends up. For networks that answer one address from many places at once,
  such as Cloudflare's, the server that answered is usually much nearer.

## Website names

Without help, a server is only an address, and anything on a cloud's network reads as
*Hosted on Amazon*. With **See which websites your apps visit** turned on, a content filter,
the part of macOS made for apps like this one, tells NetworkMonitor the name each app
connected by. Then `wss-primary.slack.com` on Amazon's network reads as **Slack**, and the
Servers list shows names, with the address underneath.

- **Offered when you first open NetworkMonitor**, in the welcome window, and optional. Said
  no? **Turn On…** is in Connections' settings, and above the list in Connections until
  you close it there (#134).
- **macOS asks twice:** once in System Settings (General › Login Items & Extensions ›
  Network Extensions ⓘ), then once in a dialog. The row shows each step while it waits.
- **It runs in the background** from then on, with nothing to manage.
- **It blocks only what you block** (see below).
- **It fails open:** if the filter stops, nothing is cut off.
- **Once it's on, the settings say nothing about it** (#181). It's switched off in System
  Settings › Network › Filters, and then Connections' settings offer **Turn On…** again.
  Uninstall removes it.
- **Apps that connect by address are named from the handshake** (#196). Chrome, Figma
  and other Chromium apps look addresses up themselves, often over encrypted DNS, so the
  filter gets no name from them. For those connections to port 443 it reads the site's
  name from the opening handshake, TLS's or QUIC's, which is sent for the network to read.
  Only that name: nothing after it, and nothing of a connection that already has a name.
- **What still reads by its network's owner:** a connection on another port, one that
  doesn't use TLS or QUIC, and a site that hides its name with Encrypted Client Hello,
  which shows its provider's public name instead, such as `cloudflare-ech.com`.

## Blocking

Right-click a company, app, country or server in Connections and choose
**Block**, **Block on Hotspots** or **Always Allow** (#114). The row says so beside its name,
and Connections' settings list every rule, each with a button to take it back.

- **A server with a name is ruled by name** (#197), since a CDN moves a name from address to
  address. Each choice opens onto the name itself or its whole site: *stats.wp.com*, or
  *All of \*.wp.com*. A rule for a name covers every name under it too. A server without a
  name is ruled by its address, as before.
- **The narrowest rule wins:** a server's address, then a site (the longer name first), then
  an app, then a company, then a country. So *Block Meta* with *Always Allow WhatsApp* lets
  WhatsApp through, *Block United States* with *Always Allow Apple* lets Apple's servers there
  through, and *Block Google* with *Always Allow \*.youtube.com* lets YouTube through.
- **A connection that opens without a name is decided once its handshake names it** (#196,
  #197): Chrome's, for example. Its first bytes wait for that, and a name never found leaves
  it decided as it was without one.
- **On Hotspots** means while the Mac is on a hotspot, as the Network page judges it.
- **On "this network"** (#200): the menu also offers **Block "…" on "Office Wi-Fi"**, for the
  network the Mac is on. The rule applies only there, keyed by the router's identity as
  Usage History tells networks apart, never by the Wi-Fi name; elsewhere, the next rule
  decides. Its badge names the network, and a rule for everywhere replaces it.
- **With Hotspot mode on, every app's updater waits on a hotspot** (#98): a program inside an
  app named like an updater (`opera_autoupdate`, Raycast's `Updater`, Sparkle's), Sparkle's
  downloader, or an updater of its own (GoogleUpdater, Microsoft AutoUpdate, Squirrel's
  `ShipIt`), and the update-only servers Hotspot mode's helper blocks. Your rules come first,
  so Always Allow lets one through, and macOS and Apple's apps follow Hotspot mode's system
  setting instead. What it stopped shows under Blocked.
- **Never blocked:** the local network, looking up names (DNS), the clock, and getting an
  address. Without them nothing else works.
- **Export… and Import…** beside the rules in Connections' settings (#201) save every rule
  to a JSON file, for a backup or another Mac. Import adds the rules that aren't there yet,
  never replaces one that is, and says how many it added.
- **Block Everything,** in the menu bar item's right-click menu (#198), stops every app's
  new connections at once, Apple's included and whatever your rules allow, until you
  choose it again. Only the essentials above and NetworkMonitor itself go through. While
  it's on, the readout turns red and the popover says so, with **Turn Off**. It lasts
  across a relaunch and a restart. Connections already open carry on until they close.
- **A rule about an app follows its signature** (#202): it remembers the team that signed
  the app when it was made, and doesn't apply to a program at that path signed by anyone
  else, so swapping in another program doesn't inherit the app's rules. Under Ask Me, that
  program is asked about afresh. Apps with no team (Apple's own, ad-hoc or self-signed
  ones) are matched by path, as before. An update signed by the same team carries on.
- **An app is the app and the programs it starts**, as Connections lists them: a rule on
  iTerm covers the `curl` you run in it, unless `curl` has a rule of its own. Safari's pages
  load through a WebKit process, and a rule on either catches them.
- **From the next connection:** a connection already open carries on until it closes.
- **The filter keeps its own copy of the rules**, so they apply with the app quit and after
  a restart, before the app is back.
- **Blocking needs website names on.** Choosing Block while they're off starts turning
  them on, with the steps above the list.

## Ads and trackers

**Block ads and trackers** (#176) blocks, in every app, the sites on two lists. Ad blocking
is a section of its own in the main window, **Ads and Trackers**, and its settings, behind
the gear in its toolbar, hold the switch, **Update the lists weekly**, and **Lists** and
**Your Rules**.

| List | What it holds | From | Licence |
|---|---|---|---|
| **Ads and trackers** | about 77,000 ad, tracking and analytics servers | StevenBlack's unified hosts | MIT |
| **Malware and phishing** | about 1,900 servers spreading malware now | URLhaus, by malware-filter | CC0 |

- **Your rules come first.** Always Allow on a site or a server in Connections lets it
  through, and a rule that blocks still blocks. Always Allow on an app, a company or a
  country (Ask Me's answers too, and the apps you allow under Only Where I Allow) lets it
  connect, and the lists still apply to it (#316): allowing Google in Chrome doesn't let
  `doubleclick.net` through.
- **A listed name covers every name under it,** down to its site: listing
  `doubleclick.net` blocks `static.doubleclick.net`. A list can never block a whole suffix
  such as `com`, `gov.lb` or `myshopify.com`. A name's site comes from the Public Suffix
  List (#318), as browsers judge it: `moph.gov.lb` and `shop.myshopify.com` are sites of
  their own.
- **It works for apps that connect by address too,** such as Chrome, through the name in
  the connection's handshake (#196).
- **It sees through a site's own name for a tracker** (#255): `metrics.example.com` that is
  an alias of a listed tracker, as the answer to the Mac's lookup says, is blocked as that
  tracker. The answers are read, never changed, over UDP or TCP, and an alias is kept as
  long as its answer says, up to a day. Your rules meet an alias as they meet the name
  (#321): *always block* `omtrdc.net` stops `metrics.example.com` too, and *never block*
  for every app or one keeps an alias from counting for the ad lists. Lookups an app
  encrypts itself, such as Chrome's Secure DNS, can't be read.
- **Connections tags each listed server** ADS or MALWARE, whether the lists are on or
  not, so it shows what's tracking you either way. **Show: Blocked** lists what
  they stopped.
- **The popover's Ads blocked** button counts them for its period, by site or by app, in
  red; **Open Ads and Trackers** (⌘B) at the bottom of its view opens the section.
- **What it can't block:** ads served from a site's own servers, like YouTube's, since
  they can't be told apart from the site; empty boxes in a page where an ad would have
  been; and anything without a name (another port, or not TLS or QUIC). It's not an ad
  blocker for the browser.
- **The lists stay current by themselves.** A workflow rebuilds them every Monday, refuses
  a list that shrank (below a fixed floor, or to under half of last week's, #319) or that
  catches a site people use every day, and signs them; the app
  fetches them weekly while they're on, never on a hotspot (**Update them weekly**). It
  ships with a copy, so they work offline.

### The Ads and Trackers section

A section of the main window (#251, #436), from **Open Ads and Trackers** under Ads blocked
in the popover, the four squares beside the popover's gear, **Ads and Trackers…** in the
right-click menu, the sidebar, or ⌘B while a window is open. **Overview | Log** heads it,
and the toolbar's search (⌘F) covers both.

**Overview:**

- **How many were blocked** in the period (a day, week, month or year, with ‹ Today ›). The
  ⓘ beside the total says how it's counted, and what each list blocked, largest first
  (#402). A list switched off since keeps what it blocked while it was on, marked *off*.
  The period is in the toolbar on Overview only: the Log is the present, so it's hidden
  there (#311).
- **List, Both or Chart**, at the start of the toolbar, as Connections has List, Both or
  Map (#524): the list alone, the chart above it (the default), or the chart filling the
  window. Whichever you choose is remembered, and it's hidden on Log with the period.
- **A chart** of blocks over the period, by hour or by day.
- **Sites or Apps**, at the end of the row under the toolbar, where Connections and Usage
  History have All, Wi-Fi or Hotspot: **Sites**, by the part of the name a person would
  call the site (`doubleclick.net`), with the names under it that were blocked; or
  **Apps**, with the sites each tried most. One at a time, each list has the window's
  width (#524).
- **Pause:** for an hour or until tomorrow, in every app. The lists stay chosen, the filter
  is sent none until then, and the popover says it's paused. Kept across a relaunch.
  **Whenever on** *this network* (#253) turns ad blocking off on the network the Mac is on,
  by the router's identity as History knows it, every time it's there; Your Rules lists
  those networks, and **Turn On Here** undoes it.

**Log** (#252), beside Overview: every connection the filter decides, live,
newest first, with the time, the app, the site (or its address, marked **No Name** when
nothing named it), Blocked or Let through, and why in plain words (*On the ads and trackers
list*, *Your rule: never block example.com*, *Let through, though it's on a list*). Show
All, Blocked, On a List or No Name, and search. Right-click a row to never or always block
its name or its whole site, in every app or only that one, to stop filtering its app, or to
remove a rule you made. **Pause**
holds the list still, **Clear** empties it, and **Export…** saves what's shown as text. It
keeps the last 5,000 in memory only; lookups aren't listed. It fills once ad blocking or
a rule is on, and starts afresh each time NetworkMonitor opens.

**Lists** (#254), in Ads and Trackers' settings: which lists block, and what each blocked
today (#311).

- **Built in:** the two above, switched on and off here.
- **Recommended** (#314), on by default: **HaGeZi Normal** and **OISD Big**, chosen by the app
  so nobody has to weigh lists against broken sites. Between them they block most ads and
  trackers; OISD is made to block ads without breaking sites and HaGeZi Normal is HaGeZi's
  all-round tier, below Pro, and the pair is a common low-breakage setup. They overlap rather
  than conflict. One switch for the pair; in Recommended the lists in use follow
  `ListCatalogue.recommended`, so a later version can change it. Installs that had chosen lists
  before #314 keep their choice.
- **Advanced**, collapsed while Recommended is on: every list, and Add List. Switching a list
  here, or adding one, makes it your own choice, starting from the lists in use; switching
  Recommended back on keeps your choice for when you switch it off again.
- **More lists**, under Advanced, downloaded on the Mac from where their makers publish them, by topic:

  | Topic | Lists |
  |---|---|
  | More ad and tracker lists | HaGeZi Light, Normal and Pro; OISD Small and Big; AdGuard DNS filter; Peter Lowe's list |
  | Trackers | EasyPrivacy, as Firebog extracts it |
  | Pop-ups | HaGeZi Pop-up Ads |
  | Malware and phishing | HaGeZi Threat Intelligence |

  No list that blocks encrypted DNS is offered: it would stop Private Relay and browsers' own,
  and let the internet provider see the sites (#246, #287). Hover a list for who keeps it and
  its licence. They're downloaded rather than shipped, so
  the GPL ones are fine to offer; the signed `blocklists` release keeps only lists we may
  republish.
- **Add List** takes any list's `https://` address: a hosts file, a plain list of names, or
  Adblock rules about whole sites (`||site^`, with `$important`; `@@||site^` and `$badfilter`
  are exceptions). Rules about parts of pages are skipped; a list with nothing else is refused.
  It's named from its `Title:` line, or its site.
- **Each switched-on list is downloaded weekly** while ad blocking is on, never on a hotspot,
  a metered connection or in Low Data Mode, and the last good copy is kept. A row says how
  many sites it has and when it was updated, or why it isn't there. Right-click for **Update
  Now**, **Copy Address**, or **Remove** for one you added.
- **They block only alongside a built-in list**, after it: a site on StevenBlack's list counts
  as *Ads and trackers*. The Overview and the Log name the list that blocked each connection,
  so one that blocks too much can be found and switched off.
- **Import…** under Your Rules switches on the lists a uBlock Origin backup or AdGuard's
  settings had that are here (Peter Lowe's, EasyPrivacy, AdGuard DNS filter), and adds the
  ones they had by address.

**Your Rules** (#253), beside Lists in Ads and Trackers' settings: your own say over what the lists do.

- **Never block** a site, and every name under it: it goes through though a list has it.
- **Always block** a site that no list has.
- Either for **every app** or **one app**, from the menu beside the site. One app's rule
  follows its signature, as firewall rules do (#320): a program at that path signed by
  another team isn't the app, so it doesn't inherit *don't filter*.
- **Don't filter an app**: the ad and tracker lists leave all its connections alone, for an
  app that breaks.
- **Malware lists still apply** (#317): *never block* and *don't filter* change what the ad,
  tracker and pop-up lists do, and the built-in malware list and the downloaded ones in
  *Malware and phishing* block whatever they say. To let such a site through anyway, Always
  Allow it in Connections. The Overview doesn't offer *Never Block* for a site only they
  blocked.
- Type a site, or paste an address or a rule (`https://ads.example.com/x`, `*.example.com`,
  `||example.com^`): the name is read out of it. Return makes it *never block*.
- Right-click a site in the Overview to never block it, or an app to stop filtering it.
- **Import…** brings rules over from **uBlock Origin** (its backup file: trusted sites, My
  filters, and the lists it had on), **AdGuard** (its exported settings: the allowlist, user
  rules and its filters), or rules in Adblock syntax, chosen as a file or pasted. A summary
  comes first, and nothing changes until you accept it:
  - `||site^` is *always block*, `@@||site^` *never block*, `$app=` (a bundle ID, an app's name
    or path) makes it one app's, and `@@*$app=…` is *don't filter*. Hosts-file lines and bare
    names are *always block*.
  - Trusted sites and the allowlist become *never block*. There they mean "block nothing on this
    site's pages"; here, connections to the site itself go through, since the filter can't tell
    which page asked.
  - The lists it had on switch on the ones NetworkMonitor has (ads and trackers, malware, and
    those under Lists), lists it had added by address are added the same way (#254), and
    the rest are named as not offered yet.
  - Rules that hide parts of a page (`##`, scriptlets) are counted as waiting for the browser
    extension (#257); rules about part of a site (a path, `$third-party`, `$domain=`) as waiting
    for Enhanced ad blocking (#256); anything else is listed with why it can't be used.
- **Export…** saves your rules in the same syntax, which uBlock Origin's My filters and
  AdGuard's user rules take, and Import reads back.

They change only what the lists do, and only while ad blocking is on: a firewall rule in
Connections still comes first, and *never block* lets nothing through that your rules or
mode would stop. Decided in this order: one app's *never block*, one app's *always block*,
every app's *never block*, every app's *always block*, then the lists, with the longer name
first within each. What *always block* stops counts with the lists, as **Your Rules**.

The overview reads `list_blocks` in History (#250), so it starts from when that was added, is kept as
long as History, and Clear History clears it.

**Show: Blocked**, beside *Group by*, lists what was blocked instead of what was sent: the same
period, grouping, search and map, counting connections rather than bytes. Right-click one to
allow it.

**Let apps connect**, in Connections' settings, is one of three:

- **Anywhere**, the default: everything connects except what you block.
- **Ask Me** (#129): the first time an app connects to a company, it waits while a small
  panel at the top right asks. On a host's network, such as Amazon's or Cloudflare's, where
  the owner says nothing, it asks about the site instead (#199).
  - **The panel names the site** (#199): *Figma wants to connect to api.segment.io*, then
    whose it is, the country and the port. For an app that connects by address, such as
    Chrome, the name comes from the connection's handshake, read before asking.
  - **For:** the site (`segment.io` and every name under it) or the whole company.
  - **Allow:** **Once** lets it go and asks again in an hour; **Until It Quits** lasts until
    that app quits; **Always** makes a rule. **Block** makes a rule. Rules from answers are
    for that app only and listed in Connections' settings ("\*.segment.io · for Figma, until it quits").
    The Allow button's menu also offers the app anywhere.
  - Every connection between the same app and company or site waits on the one question,
    and with no answer in 30 seconds they go ahead, and the panel says so. Nothing is asked
    about macOS or Apple's apps, or while NetworkMonitor isn't running.
- **Only Where I Allow**: every app is blocked until you allow it, apart from macOS and
  Apple's own apps, which can always connect unless you block them. It asks first, since
  that includes your browser, and Connections then opens on Blocked, where you allow each app
  or company with a right-click.

A rule for one app comes before any rule for every app: *Amazon · for Slack* allowed with
*Hosted on Amazon* blocked lets Slack through and nothing else.

## Encrypted lookups

**Encrypt lookups**, under Lookups in Connections' settings (#291), off until switched on, sends the
Mac's DNS lookups encrypted, over DNS over HTTPS, to **Cloudflare** (1.1.1.1), **Quad9**
(9.9.9.9) or **Google** (8.8.8.8). Without it they travel unencrypted to the network's DNS
server, so the internet provider and anyone on the Wi-Fi can read every name looked up.

- **It needs the content filter**, whose system extension carries it as a DNS proxy. macOS asks
  once to allow it.
- **Answers come back unchanged**, and the filter still reads their aliases (#255).
- **Names only the network knows stay on it:** single names like `router`, `.local`, `.lan`,
  `.home`, `.home.arpa`, `.internal`, `.corp`, and reverse lookups of local addresses.
- **It fails towards working.** A lookup the resolver doesn't answer in 2.5 s goes to the
  network's DNS server, as it would have; after three in a row, every lookup does for a
  minute. Lookups over TCP, which are rare, go to the network's server unchanged.
- **It checks itself.** Switched on, or at launch with it on, the app looks up a name that
  exists nowhere: an answer, even *no such name*, means lookups work. If none comes in three
  tries while the router answers, it switches itself off again and says why under the switch.
- **Updates switch it off and on again** around replacing the extension, with the filter (#278).
- Apps that encrypt their own lookups, like Chrome with Secure DNS, aren't affected; ECH is never
  touched.

## What it costs

Nothing you'd notice. Recording uses rows `nettop` already reports, and measured no extra
CPU. The record is kept as long as Usage History (**Keep history for** in Usage History's
settings) and cleared with it. The data that names servers adds about 5.5 MB to the download.
