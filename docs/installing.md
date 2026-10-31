# Installing, updating and removing

NetworkMonitor runs on macOS 13 or later, on Apple silicon and Intel. It comes as
one universal disk image, `NetworkMonitor.dmg`, attached to every
[GitHub release](https://github.com/kevinabouhanna/NetworkMonitor/releases).

## Signed and notarized

NetworkMonitor is signed with an Apple **Developer ID**, Kevin Abou Hanna's (team
`GRQKG7M8CL`), and **notarized**: Apple has checked it for malicious software and
issued a ticket that travels with the app. So macOS knows who made it and opens it
without a warning. Version 1.13 and earlier weren't, and asked you to approve them
with **Open Anyway** in System Settings.

If you'd rather not take a binary on trust, the code is all in this repository, and
[building it yourself](development.md) needs only Apple's free Command Line Tools.

## Install

1. [Download NetworkMonitor.dmg](https://github.com/kevinabouhanna/NetworkMonitor/releases/latest/download/NetworkMonitor.dmg),
   open it, and drag **NetworkMonitor** into **Applications**.
2. Open NetworkMonitor from Applications.

The ↓ ↑ readout appears in the menu bar. NetworkMonitor has no Dock icon and no
window of its own; everything starts from the readout. It registers itself to
start at login, which you can turn off in **Settings › General**.

The first time, a welcome window offers two things, both optional (#134):

- **See which websites your apps visit**: a content filter that names the servers in
  [Connections](connections.md#website-names), and makes blocking possible.
- **Know your Wi-Fi networks by name**: macOS shares the name only with Location
  permission, and it's used for nothing else. Without it, networks are named like
  *Wi-Fi · 3f2a*.

Neither is asked for again on its own. Skip either, and it has a **Turn On…** where it's
used: website names in Settings › Connections, Wi-Fi names in Settings › General.

## Update

From 1.15 on, NetworkMonitor updates itself with Sparkle (#132). Once a day it asks
GitHub whether there's a newer version, never on a hotspot, and offers it: what's new,
and **Install Update** when you're ready. **Check for Updates…** in its menu asks at
once, and Settings › About switches the daily check off. An update installs only if its
disk image is signed with the key built into the app.

Before 1.15, or to do it by hand:

1. Download the new `NetworkMonitor.dmg`.
2. Drag NetworkMonitor into Applications and choose **Replace**.
3. Open it.

Updating from 1.13 or earlier, macOS asks for Location once more: the app is now
signed with a Developer ID instead of its own certificate, so macOS sees it as new
this one time.

Your settings, totals and Usage History stay where they are, outside the app.

If you use [Hotspot mode](hotspot-mode.md), its helper comes with the new version and asks
nothing. Coming from a version whose helper asked for your password, NetworkMonitor offers
the new one once: switch it on in System Settings, and the old one's sudoers rule is removed.

From a source checkout, `make update` pulls, runs the tests, rebuilds and
reinstalls, with the tests first so a bad pull can't replace a working copy.

## Uninstall

Right-click the menu bar readout and choose **Uninstall NetworkMonitor…**, or open
**Settings › About** and click **Uninstall…**. In order, it:

1. removes the content filter, if you turned on website names: its settings at once, and
   the extension itself, which macOS may finish at the next restart;
2. removes the helper, if it was installed, which first puts back what it changed (a
   helper from a build without a Developer ID asks for your password). If that fails or
   you cancel, nothing else is touched;
3. puts back the settings Hotspot mode changed without the helper;
4. removes the login item, your usage history and your settings;
5. moves the app to the Trash.

**Dragging the app to the Trash is not the same.** The helper notices within an
hour that the app is gone, puts back the changes it made (system update settings,
managed policies, Low Data Mode) and removes itself. But the update settings that
needed no password stay switched off, because the record of how to undo them
belongs to the app, and nothing is left running to read it. If you've already
trashed it, drag it back, open it, and uninstall from the menu.

From a source checkout, `Scripts/uninstall.sh` does the same.

## What the helper looks like to macOS

If you switch Hotspot mode on, the app registers a small helper, and macOS lists it under
NetworkMonitor in **System Settings › General › Login Items & Extensions**, under **Allow
in the Background**, for you to switch on (#131). Its hourly self-heal job is listed under
NetworkMonitor too. See [Hotspot mode](hotspot-mode.md#the-helper) for exactly what it can
do.
