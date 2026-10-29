# Roadmap and known limits

## Distribution: what the Developer ID changes

NetworkMonitor is signed with a Developer ID and notarized (#119), so macOS opens it
without **Open Anyway**. Two separate things finish the job, and neither replaces the
other:

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
3. **Move the helper to `SMAppService.daemon` with XPC**, now that clients can be checked by
   team. That removes the password prompt and the extra Login Items row, and gives the
   helper proper caller authentication.
4. **Only then, add Sparkle 2**: an EdDSA key whose private half is never committed, a
   "Check for Updates…" menu item, an automatic-check setting, and an appcast published with
   each release. Releasing stays "push a tag". NetworkMonitor will pause its own updates on
   a hotspot first.

The App Store isn't on the list: App Store apps must be sandboxed, and a sandboxed app
can't run `nettop`.

## Ideas

- **A content filter for Hotspot mode**, for Electron apps that have no update setting and
  ignore Low Data Mode. It would plug in as one more `UpdateSuppressor`, and needs a
  Developer ID.
- **Mark a network as metered by hand.** The storage and logic exist
  (`MeteringController.setOverride`); the control doesn't yet.
- **Move the tests to a real test target** once Xcode isn't a constraint. The harness
  mirrors XCTest's names so it's a rename.

## Known limits

**Measurement**

- Per-app rows add up to a little less than the total: wire overhead belongs to no app,
  and the last second before quitting is never completed.
- Nothing from before the app started is counted, by design.
- With a VPN, an app's traffic and the VPN's own encrypted connection can both appear as
  rows, so rows may add up to more than the total. The total itself is capped at the
  kernel's count, so it stays right.

**Hotspot mode**

- Updaters compiled into an app's own binary (Tauri apps, for example) can't be found.
- Most Electron apps ignore Low Data Mode.
- Dragging the app to the Trash leaves the password-free changes in place; uninstall from
  the app.

**Connections**

- An app's servers can add up to a little less than its total: a socket that opened and
  closed between two samples leaves no connection row. About 95% in a short capture.
- An app keeps at most 500 servers by address in an hour. Past that, the rest are added
  up as one, which only peer-to-peer apps and large calls reach.
- With a VPN, the VPN's server appears as one server carrying everything, alongside the
  servers each app reached through it.
- Microsoft's and Google's networks also carry other companies' services (Azure, and
  Google's front ends for Google Cloud), which show as Microsoft or Google.
- Server names need the content filter (#128) turned on. Without it, a server is its
  address, and a network that hosts other companies, such as Amazon's or Cloudflare's,
  says so rather than naming the company behind the traffic.
- With it, an address keeps the latest name an app reached it by. An address shared by
  many sites, as CDNs' and public DNS resolvers' are, can show a different site's name
  from one moment to the next. Apps that connect to a bare address have no name to give.
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
