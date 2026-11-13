# Roadmap and known limits

## Distribution: the Developer ID plan, done

Every step of this is done, as of 1.15.0. [Building and releasing](development.md) and
[Architecture](architecture.md) describe how it works now. Two separate things finish the
job, and neither replaces the other:

| | What it proves | What it unlocks |
|---|---|---|
| **Apple Developer ID**, plus notarization | who built the app | no Gatekeeper warning; a proper XPC helper; the helper grouped under the app in Login Items |
| **Sparkle signing key** (free) | that an update came from the same place and wasn't tampered with | a built-in, safe updater |

The plan, in order:

1. ~~**Sign with a Developer ID**~~, with the hardened runtime and the Location
   entitlement Wi-Fi names need (#119). Done. The change of certificate made it a new app
   to macOS once, so Location is asked for one more time.
2. ~~**Notarize in the release workflow**~~ and drop **Open Anyway** from the README, the
   website and the release notes (#119). Done.
3. ~~**Move the helper to `SMAppService.daemon` with XPC**~~, now that clients can be checked
   by team (#131). Done: allowing it is a switch in System Settings instead of a password,
   it's listed under NetworkMonitor in Login Items, an update brings its helper with it,
   and only NetworkMonitor can ask it anything.
4. ~~**Only then, add Sparkle 2**~~ (#132). Done: an EdDSA key whose private half is never
   committed, a "Check for Updates…" menu item, an automatic-check setting, and an appcast
   published with each release. Releasing stays "push a tag". NetworkMonitor pauses its own
   updates on a hotspot first.

The App Store isn't on the list: App Store apps must be sandboxed, and a sandboxed app
can't run `nettop`.

## Ideas

What comes next, in order, is [the plan](PLAN.md) (#605). The ideas that were listed here
are in it or done: widgets (#108) and a Terminal command (#77) are in its phase 8, the
Homebrew cask shipped as a tap (#203) and moves into Homebrew's own repository with the launch
(#529), and the Dock icon shipped in 1.29 (#69). Two ideas have no issue yet:

- **A monthly data cap, with a warning as it nears.** History has every figure it would
  need; nothing sets a cap or warns yet.
- **Move the tests to a real test target** once Xcode isn't a constraint. The harness
  mirrors XCTest's names so it's a rename.

## Known limits

**Measurement**

- Per-app rows add up to a little less than the total: wire overhead belongs to no app,
  and the last second before quitting is never completed.
- Nothing from before the app started is counted, by design.
- Through a proxy or a VPN, an app's traffic is counted for the app once the proxy is
  recognised (#356): a proxy NetworkMonitor doesn't know by name, and isn't a Network
  Extension, still shows as carrying everything. The total is capped at the kernel's count,
  so it stays right either way.

**Hotspot mode**

- Updaters compiled into an app's own binary (Tauri apps, for example) can't be found.
- Most Electron apps ignore Low Data Mode.
- Dragging the app to the Trash leaves the changes made without the helper in place, since
  their record goes with the app; uninstall from the app. The helper's own changes are put
  back by its hourly self-heal job.

**Connections**

- An app's servers can add up to a little less than its total: a socket that opened and
  closed between two samples leaves no connection row. About 95% in a short capture.
- An app keeps at most 500 servers by address in an hour. Past that, the rest are added
  up as one, which only peer-to-peer apps and large calls reach.
- With a VPN, the VPN's server appears as one server carrying everything, alongside the
  servers each app reached through it.
- Microsoft's and Google's networks also carry other companies' services (Azure, and
  Google's front ends for Google Cloud), which show as Microsoft or Google.
- Server names need the content filter (#128), which is optional (#134). Without it, a
  server is its address, and a network that hosts other companies, such as Amazon's or
  Cloudflare's, says so rather than naming the company behind the traffic.
- With it, an address keeps the latest name an app reached it by. An address shared by
  many sites, as CDNs' are, can show a different site's name from one moment to the next.
- Apps that connect by address are named from the connection's handshake (#196), on port
  443 only. A site using Encrypted Client Hello shows its provider's public name, such as
  `cloudflare-ech.com`.
- A country is where DB-IP places a server's address, not where the company is based or
  where data ends up. For networks that answer one address from many places at once
  (Cloudflare, Fastly, Google's public DNS), the server that answered is usually much
  nearer than that: on the development Mac in Lebanon, Cloudflare's addresses read as
  Canada.

**Usage History**

- It starts when you install 1.4.0 or later.
- The Day/Week/Month/Year choice isn't remembered across launches.

**Speed test**

- A run uses 50–500 MB, more on a very fast line.
