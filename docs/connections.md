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

Server names, and so the real company behind hosted traffic, come with the content filter
(#115).

## What it costs

Nothing you'd notice. Recording uses rows `nettop` already reports, and measured no extra
CPU. The record is kept as long as Usage History (**Keep history for** in Settings ›
History) and cleared with it. The data that names servers adds about 4 MB to the download.
