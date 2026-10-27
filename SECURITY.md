# Security policy

## Supported versions

Only the [latest release](https://github.com/kevinabouhanna/NetworkMonitor/releases/latest)
gets security fixes. There are no backports: to get a fix, download the new version and
replace the old one (see [Updating](docs/installing.md#update)).

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

- **The root helper.** That covers the binary at
  `/Library/PrivilegedHelperTools/com.kevinabouhanna.NetworkMonitor.helper`, its sudoers
  rule at `/etc/sudoers.d/networkmonitor`, its LaunchDaemon and its records in
  `/Library/Application Support/NetworkMonitor/`. In scope is anything that gets more out
  of it than its fixed verbs, changes what those verbs act on, or tampers with its
  records. How it's meant to work is in [Hotspot mode](docs/hotspot-mode.md#the-helper).
- **Installing and removing it**: `helper-setup.sh`, `Scripts/install.sh`,
  `Scripts/uninstall.sh` and the in-app Uninstall…, including anything they leave behind.
- **The app sending data off your Mac.** The only traffic it should start is the speed
  test you run yourself (see [Privacy](docs/privacy.md)).
- **The download.** A `NetworkMonitor.dmg` on the Releases page that isn't what the
  tagged source builds.

## Known, and by design

These are documented choices, not vulnerabilities:

- **No Developer ID.** The app is ad-hoc signed and not notarized, so macOS asks you to
  approve it with Open Anyway, after every update too
  ([why](docs/installing.md#why-macos-asks-you-to-approve-it)).
- **The helper's verbs run without a password**, for the account that installed it. That
  is what the sudoers rule is for. Each verb takes no arguments, and every setting, domain
  and host it touches is compiled in.
- **Hotspot mode edits `/etc/hosts`**, to block Google's, Canva's and Figma's update
  servers while you're on a hotspot. It puts the file back when you leave.
- **Hotspot mode writes managed policy files** while you're on a hotspot: for Claude and
  Slack in `/Library/Managed Preferences`, and for Claude Code in
  `/Library/Application Support/ClaudeCode/managed-settings.d`. It removes them when you
  leave.
- **Attacks that already need root or an administrator's password.**

## Checking a download

Every release is built and published by the repo's
[Release workflow](.github/workflows/release.yml) from its tag, not on anyone's Mac.
The release page lists the SHA-256 of `NetworkMonitor.dmg`. To compare:

```sh
shasum -a 256 ~/Downloads/NetworkMonitor.dmg
```

Download it only from the [Releases page](https://github.com/kevinabouhanna/NetworkMonitor/releases)
or the [website](https://kevinabouhanna.github.io/NetworkMonitor/), which links there.
