# Connections

Which companies your apps send data to, from which apps, in which countries, and to which
servers. Click the 🌐 in the popover, or choose **Connections…** (⌘K) from the right-click
menu.

It runs quietly: nothing pops up and nothing is blocked. NetworkMonitor records the servers
each app talks to as it already counts their data, and the window shows them whenever you
look.

## Reading the window

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
- **Day, Week, Month, Year** and the arrows move through time, as in Usage History, and
  **All / Wi-Fi / Hotspot** narrows it to one kind of network.
- **Under each app is who made it**, read from its code signature, and the companies it
  talks to besides its maker. Hosts aren't counted: an app on Amazon's network isn't
  talking to Amazon.

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
