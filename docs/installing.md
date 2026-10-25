# Installing, updating and removing

NetworkMonitor runs on macOS 13 or later, on Apple silicon and Intel. It comes as
one universal disk image, `NetworkMonitor.dmg`, attached to every
[GitHub release](https://github.com/kevinabouhanna/NetworkMonitor/releases).

## Why macOS asks you to approve it

Apps from outside the App Store are normally signed with a paid **Apple Developer
ID** and **notarized**, which lets macOS confirm who made them. NetworkMonitor isn't
yet. Its signature is *ad hoc*: it proves the app hasn't been altered since it was
built, but not who built it.

So the first time you open it, macOS stops it and says it can't check it for
malicious software. That's Gatekeeper doing its job, not a sign that anything is
wrong. You approve it once in System Settings, and from then on it opens like any
other app. On current macOS, right-click › Open no longer skips the check; the
approval in System Settings is the only way.

If you'd rather not take a stranger's binary on trust, the code is all in this
repository, and [building it yourself](development.md) needs only Apple's free
Command Line Tools.

## Install

1. [Download NetworkMonitor.dmg](https://github.com/kevinabouhanna/NetworkMonitor/releases/latest/download/NetworkMonitor.dmg),
   open it, and drag **NetworkMonitor** into **Applications**.
2. Open NetworkMonitor from Applications. macOS says it can't check it for
   malicious software. Click **Done**.
3. Open **System Settings › Privacy & Security**, scroll down to **Security**, and
   click **Open Anyway** next to NetworkMonitor. Confirm with your password.

The ↓ ↑ readout appears in the menu bar. NetworkMonitor has no Dock icon and no
window of its own; everything starts from the readout. It registers itself to
start at login, which you can turn off in **Settings › General**.

A few seconds in, it asks to use your location. Click **Allow** to see networks by
their Wi-Fi name: macOS shares the name only with Location permission, and it's used
for nothing else. Refuse, and networks are named like *Wi-Fi · 3f2a*.

On macOS 13 or 14 there's a shortcut for steps 2 and 3: Control-click the app in
Applications, choose **Open**, then **Open** again.

## Update

NetworkMonitor never connects to the internet by itself, so it has no update
check and can't tell you a new version exists. To hear about releases, click
**Watch › Custom › Releases** on the repository page.

To update:

1. Download the new `NetworkMonitor.dmg`.
2. Drag NetworkMonitor into Applications and choose **Replace**.
3. Open it, and approve it with **Open Anyway** again. macOS checks each new
   version afresh, because each one is a new, unsigned download.

Your settings, totals and Usage History stay where they are, outside the app.

If you use [Hotspot mode](hotspot-mode.md) and the new version needs a newer
helper, it asks for your password once, the first time it opens.

From a source checkout, `make update` pulls, runs the tests, rebuilds and
reinstalls, with the tests first so a bad pull can't replace a working copy.

## Uninstall

Right-click the menu bar readout and choose **Uninstall NetworkMonitor…**, or open
**Settings › About** and click **Uninstall…**. In order, it:

1. puts back every setting Hotspot mode changed, before removing anything;
2. removes the helper, if it was installed (macOS asks for your password);
3. removes the login item and your usage history;
4. moves the app to the Trash.

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
Items & Extensions**. macOS lists every background job on its own and can only
group it under its app when the app is signed with a Developer ID. See
[Hotspot mode](hotspot-mode.md#the-helper) for exactly what it can do.

## What would change with a Developer ID

Signing with a Developer ID and notarizing would remove the **Open Anyway** step,
for the first install and for every update, and would let macOS group the helper
under the app in Login Items. It would also make a built-in updater worthwhile.
[The roadmap](roadmap.md) has the plan.
