# Connections

Which companies your apps send data to, from which apps, in which countries, and to which
servers. Click the 🌐 in the popover, choose **Connections…** (⌘K) from the right-click
menu, or open **Settings › Connections**, which also shows today's top companies and sets
the layout the window opens with.

It runs quietly: nothing pops up and nothing is blocked. NetworkMonitor records the servers
each app talks to as it already counts their data, and the window shows them whenever you
look.

## Reading the window

The toolbar holds the view (**List | Both | Map**), the period (**Day, Week, Month, Year**),
**‹ Today ›**, and search. The row under it says what the list is grouped by and narrowed
to, and which networks it covers. Then the period's name, its total, and the counts.

- **Group by Companies, Apps or Countries.** Companies is the default, because that's the
  question: who gets your data.
- **Open a group** to see what's inside it. A company opens into the apps that talk to
  it, the countries its servers are in, and the servers themselves. An app opens into
  its companies, countries and servers. A country opens into its companies, apps and
  servers.
- **Click a row inside a group** to narrow the whole window to it. Choosing Teams inside
  Microsoft reads *Microsoft › Teams*, and each chip's ✕ undoes its part.
- **Drag across the timeline**, or click a bar, to see one part of the day: what your
  apps contacted in the hour after a call, say. Click the same bar again, or the chip's
  ✕, for the whole period.
- **Search** finds a company, a network's registered name, an app, a country or an
  address.
- **Day, Week, Month, Year**, the arrows and ⌘← ⌘→ move through time, as in Usage
  History, and **Networks: All / Wi-Fi / Hotspot** narrows it to one kind of network.
- **Under each app is who made it**, read from its code signature, and the companies it
  talks to besides its maker. Hosts aren't counted: an app on Amazon's network isn't
  talking to Amazon.

## The map

The window shows the list, the map, or both side by side (**List | Both | Map**). Both is
the default, and whichever you choose is remembered. Too narrow for both, the window shows
the list until you widen it.

- **Countries are shaded by how much data went there**, on a logarithmic scale, so a
  country with a few kilobytes still shows beside one with gigabytes.
- **Hover a country** for a card with its top companies. **Click it** to narrow the whole
  window to it.
- **Narrow to a company, app or server**, and lines run from your country to where its
  data went. Your country comes from the Mac's Region setting, never from Location.
- **Live** makes lines pulse to the countries your apps reach right now. The map redraws
  on its own only while Live is on, and Live switches off when the window closes.
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
online. See [privacy](privacy.md#naming-servers-without-asking-anyone).

- **A company** is the owner of the network the server is on. That's right for
  companies that run their own networks: Google, Microsoft, Meta, Apple and many more.
- **Hosted on Amazon** (or Cloudflare, Akamai, Fastly, Google Cloud and others), marked
  **HOST**, means the server is on a network that carries thousands of companies'
  traffic. The data can't tell which one, so the window doesn't guess.
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
  no? **Turn On…** is in Settings › Connections, and above the list in the Connections
  window until you close it there (#134).
- **macOS asks twice:** once in System Settings (General › Login Items & Extensions ›
  Network Extensions ⓘ), then once in a dialog. The row shows each step while it waits.
- **It runs in the background** from then on, with nothing to manage.
- **It blocks only what you block** (see below).
- **It fails open:** if the filter stops, nothing is cut off.
- **Turn Off** in Settings › Connections switches it off, as does System Settings › Network
  › Filters, and Uninstall removes it.
- **A name is only known when the app connected by one.** A program that connects to a
  bare address still reads by its network's owner.

## Blocking

Right-click a company, app, country or server in the Connections window and choose
**Block**, **Block on Hotspots** or **Always Allow** (#114). The row says so beside its name,
and Settings › Connections lists every rule, each with a button to take it back.

- **The narrowest rule wins:** a server, then an app, then a company, then a country. So
  *Block Meta* with *Always Allow WhatsApp* lets WhatsApp through, and *Block United States*
  with *Always Allow Apple* lets Apple's servers there through.
- **On Hotspots** means while the Mac is on a hotspot, as the popover judges it.
- **Never blocked:** the local network, looking up names (DNS), the clock, and getting an
  address. Without them nothing else works.
- **An app is the app and the programs it starts**, as Connections lists them: a rule on
  iTerm covers the `curl` you run in it, unless `curl` has a rule of its own. Safari's pages
  load through a WebKit process, and a rule on either catches them.
- **From the next connection:** a connection already open carries on until it closes.
- **The filter keeps its own copy of the rules**, so they apply with the app quit and after
  a restart, before the app is back.
- **Blocking needs website names on.** Choosing Block while they're off starts turning
  them on, with the steps above the list.

## What it costs

Nothing you'd notice. Recording uses rows `nettop` already reports, and measured no extra
CPU. The record is kept as long as Usage History (**Keep history for** in Settings ›
History) and cleared with it. The data that names servers adds about 4 MB to the download.
