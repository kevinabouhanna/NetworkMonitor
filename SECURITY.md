# Security policy

## Supported versions

Only the [latest release](https://github.com/kevinabouhanna/NetworkMonitor/releases/latest)
gets security fixes. There are no backports. From 1.15 on, NetworkMonitor offers each new
version itself; before that, download the new version and replace the old one (see
[Updating](docs/installing.md#update)).

## Reporting a vulnerability

Please report it privately, through
[GitHub's private vulnerability reporting](https://github.com/kevinabouhanna/NetworkMonitor/security/advisories/new).
Don't open a public issue or pull request for it.

Include:

- the NetworkMonitor version (Settings › About) and the macOS version;
- what an attacker can do, and what they need first (a local account, admin rights,
  being on the same network);
- the steps to reproduce it.

You'll get a reply within 7 days. Once it's confirmed, the fix ships in a release, and
the advisory and release notes credit you unless you'd rather they didn't.

## What's in scope

Most important first:

- **The root helper.** In a release, that's the launch daemon inside the app, which
  answers over XPC only to NetworkMonitor signed by its team, its copy at
  `/Library/PrivilegedHelperTools/com.kevinabouhanna.NetworkMonitor.helper`, its hourly
  self-heal job and its records in `/Library/Application Support/NetworkMonitor/`. A build
  without a Developer ID runs the same binary through a sudoers rule at
  `/etc/sudoers.d/networkmonitor` instead. In scope is anything that gets more out of it
  than its fixed verbs, reaches it from anything but NetworkMonitor, changes what those
  verbs act on, or tampers with its records. How it's meant to work is in
  [Hotspot mode](docs/hotspot-mode.md#the-helper).
- **The content filter**, the system extension that names each connection and applies
  your rules ([Connections](docs/connections.md#website-names)). In scope is anything that
  makes it block or allow what your rules don't say, report what it shouldn't, or answer
  anything but NetworkMonitor. If it stops, nothing should be cut off.
- **Installing and removing them**: `helper-setup.sh`, `Scripts/install.sh`,
  `Scripts/uninstall.sh` and the in-app Uninstall…, including anything they leave behind.
- **The app sending data off your Mac.** The only traffic it should start is the speed
  test you run yourself, the daily update check and the monthly country and network data
  (see [Privacy](docs/privacy.md#what-it-sends)).
- **What it accepts from GitHub.** An update installs only if its disk image is signed with
  the key built into the app, and the monthly data is used only if its signed manifest and
  each table's SHA-256 check out. Anything that gets past either is in scope.
- **The download.** A `NetworkMonitor.dmg` on the Releases page that isn't what the
  tagged source builds.

## Known, and by design

These are documented choices, not vulnerabilities:

- **The helper's verbs run without a password** once you've allowed it: in a release, with
  its switch in System Settings › General › Login Items & Extensions; in a build without a
  Developer ID, through the sudoers rule, for the account that installed it. Each verb
  takes no arguments, and every setting, domain and host it touches is compiled in.
- **Hotspot mode edits `/etc/hosts`**, to block Google's, Canva's and Figma's update
  servers while you're on a hotspot. It puts the file back when you leave.
- **Hotspot mode writes managed policy files** while you're on a hotspot: for Claude and
  Slack in `/Library/Managed Preferences`, and for Claude Code in
  `/Library/Application Support/ClaudeCode/managed-settings.d`. It removes them when you
  leave.
- **The content filter blocks the connections your rules say to**, and with Hotspot mode
  on, apps' updaters while you're on a hotspot. Under **Ask Me** it holds a new connection
  while it asks, and lets it go ahead after 30 seconds unanswered.
- **Attacks that already need root or an administrator's password.**

## Checking a download

Every release is built and published by the repo's
[Release workflow](.github/workflows/release.yml) from its tag, not on anyone's Mac.
The release page lists the SHA-256 of `NetworkMonitor.dmg`. To compare:

```sh
shasum -a 256 ~/Downloads/NetworkMonitor.dmg
```

Releases are signed with the Developer ID of Kevin Abou Hanna (team `GRQKG7M8CL`) and
notarized by Apple. To check an installed copy:

```sh
spctl -a -vv /Applications/NetworkMonitor.app
# accepted, source=Notarized Developer ID, origin=Developer ID Application: Kevin Abou Hanna (GRQKG7M8CL)
```

Download it only from the [Releases page](https://github.com/kevinabouhanna/NetworkMonitor/releases)
or the [website](https://kevinabouhanna.github.io/NetworkMonitor/), which links there.
