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

A few seconds in, it asks to use your location. Click **Allow** to see networks by
their Wi-Fi name: macOS shares the name only with Location permission, and it's used
for nothing else. Refuse, and networks are named like *Wi-Fi · 3f2a*.

## Update

NetworkMonitor never connects to the internet by itself, so it has no update
check and can't tell you a new version exists. To hear about releases, click
**Watch › Custom › Releases** on the repository page.

To update:

1. Download the new `NetworkMonitor.dmg`.
2. Drag NetworkMonitor into Applications and choose **Replace**.
3. Open it.

Updating from 1.13 or earlier, macOS asks for Location once more: the app is now
signed with a Developer ID instead of its own certificate, so macOS sees it as new
this one time.

Your settings, totals and Usage History stay where they are, outside the app.

If you use [Hotspot mode](hotspot-mode.md) and the new version needs a newer
helper, it asks for your password once, the first time it opens.

From a source checkout, `make update` pulls, runs the tests, rebuilds and
reinstalls, with the tests first so a bad pull can't replace a working copy.

## Uninstall

Right-click the menu bar readout and choose **Uninstall NetworkMonitor…**, or open
**Settings › About** and click **Uninstall…**. In order, it:

1. removes the content filter, if you turned on website names: its settings at once, and
   the extension itself, which macOS may finish at the next restart;
2. puts back every setting Hotspot mode changed, before removing anything;
3. removes the helper, if it was installed (macOS asks for your password);
4. removes the login item and your usage history;
5. moves the app to the Trash.

**Dragging the app to the Trash is not the same.** The helper notices within an
hour that the app is gone, puts back the changes it made (system update settings,
managed policies, Low Data Mode) and removes itself. But the update settings that
needed no password stay switched off, because the record of how to undo them
belongs to the app, and nothing is left running to read it. If you've already
trashed it, drag it back, open it, and uninstall from the menu.

From a source checkout, `Scripts/uninstall.sh` does the same.

## What the helper looks like to macOS

If you switch Hotspot mode on and approve the password prompt, a small helper is
installed. It shows up as an extra row in **System Settings › General › Login
Items & Extensions**. macOS groups a background job under its app only when the app
registers it itself, which is the next step on [the roadmap](roadmap.md). See
[Hotspot mode](hotspot-mode.md#the-helper) for exactly what it can do.

## What the Developer ID makes possible next

It already removed the **Open Anyway** step. Next it lets the helper be registered by
the app itself, which drops the password prompt and the extra Login Items row, makes a
built-in updater worthwhile, and allows the content filter that real blocking in
[Connections](connections.md) needs. [The roadmap](roadmap.md) has the plan.
