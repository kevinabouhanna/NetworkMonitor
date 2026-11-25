# Installing, updating and removing

English · [简体中文](zh-Hans/installing.md)

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

Or install it with [Homebrew](https://brew.sh), from NetworkMonitor's own
[tap](https://github.com/kevinabouhanna/homebrew-tap):

```sh
brew install --cask kevinabouhanna/tap/networkmonitor
```

The ↓ ↑ readout appears in the menu bar. NetworkMonitor has no Dock icon until you
open its window; everything starts from the readout. To have it in the Dock
instead, or in both, choose in **Settings › Show NetworkMonitor in**. It
registers itself to start at login, which you can turn off in **Settings**.

The first time, a welcome window offers three things, all optional (#134):

- **See which websites your apps visit**: a content filter that names the servers in
  [Connections](connections.md#website-names), and makes blocking possible.
- **Know your Wi-Fi networks by name**: macOS shares the name only with Location
  permission, and it's used for nothing else. Without it, networks are named like
  *Wi-Fi · 3f2a*.
- **Install updates automatically**: new versions install by themselves
  ([below](#update)). Off, you're told about each one (#710).

None is asked for again on its own. Skip one, and it's where it's used: website names have a
**Turn On…** in Connections' settings, Wi-Fi names one in Settings, and the update switch is
in Settings.

## Update

From 1.15 on, NetworkMonitor updates itself with Sparkle (#132). **Settings › Updates** (#710)
shows your version and when it last looked for a newer one, and a sentence under its switches
says what they do as they are.

**Check for updates automatically**, on to begin with, asks GitHub once a day whether there's a
newer version, never on a hotspot, and offers it: what's new, and **Install Update** when
you're ready. Found while the main window is open, it waits on a card above **Settings** in
the sidebar, and in Settings, instead: **Install & Restart** downloads it and
relaunches into it, **What's New** shows the release notes, and the card's ✕ puts it away
until the next day's check. **Check Now**, or **Check for Updates…** in the menu, asks at once.

**Install updates automatically** (#710), off to begin with, lets new versions install by
themselves. One downloads in the background, and installs while NetworkMonitor's windows
are closed and no speed test is running; NetworkMonitor restarts, which takes a few seconds. If
its window is open, a card says the update is ready: close the window and it installs, or
choose **Restart Now**. The next time you open the window, a card says which version
installed. It needs the daily check, so it's dimmed while that's off. The update window's
**Automatically download and install updates in the future** is the same choice.

After restarting into an update, the window you had open comes back. An update installs only
if its disk image is signed with the key built into the app.

**Get beta versions** in Settings (#585), off by default, offers you new versions before
everyone else gets them, to try new things early. A beta may have problems: **Report a
problem with a beta**, under the switch, opens a new issue on GitHub. Switched off, you
keep the beta you have until the next version comes out, which then comes as usual. With
**Install updates automatically** on too, betas install by themselves as well.

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

Installed with Homebrew, it updates itself the same way, and `brew upgrade` leaves it to
that unless you ask with `--greedy`. The cask follows each release within a day.

From a source checkout, `make update` pulls, runs the tests, rebuilds and
reinstalls, with the tests first so a bad pull can't replace a working copy.

## Uninstall

Right-click the menu bar readout and choose **Uninstall NetworkMonitor…**, or click it at the bottom of Settings. In order, it:

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

Installed with Homebrew, uninstall from the menu first, then run
`brew uninstall --cask networkmonitor`, which only removes what's left.

From a source checkout, `Scripts/uninstall.sh` does the same.

## What the helper looks like to macOS

If you switch Hotspot mode on, the app registers a small helper, and macOS lists it under
NetworkMonitor in **System Settings › General › Login Items & Extensions**, under **Allow
in the Background**, for you to switch on (#131). Its hourly self-heal job is listed under
NetworkMonitor too. See [Hotspot mode](hotspot-mode.md#the-helper) for exactly what it can
do.
