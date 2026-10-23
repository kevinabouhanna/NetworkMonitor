# Roadmap and known limits

## Distribution: what a Developer ID would change

NetworkMonitor is ad-hoc signed today. That's why macOS asks you to approve it with **Open
Anyway**, the first time and after every update (see [installing](installing.md)). Two
separate things would fix that, and neither replaces the other:

| | What it proves | What it unlocks |
|---|---|---|
| **Apple Developer ID**, plus notarization | who built the app | no Gatekeeper warning; a proper XPC helper; the helper grouped under the app in Login Items |
| **Sparkle signing key** (free) | that an update came from the same place and wasn't tampered with | a built-in, safe updater |

The plan, in order:

1. **Sign with a Developer ID.** `Scripts/bundle.sh` is ready for it: set `SIGN_IDENTITY`
   and it signs with the hardened runtime and a timestamp. Running `nettop` needs no
   hardened-runtime exception.
2. **Notarize in the release workflow** (`notarytool submit --wait`, then `stapler
   staple`), check that a fresh Mac opens it without a warning, and drop the **Open Anyway**
   steps from the README, the website and the release notes. This is the milestone that
   makes the app easy to install for everyone.
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

**Usage History**

- It starts when you install 1.4.0 or later.
- The Day/Week/Month/Year choice isn't remembered across launches.

**Speed test**

- A run uses 50–500 MB, more on a very fast line.
- If the app is force-quit mid-test, its temporary folder stays in `$TMPDIR` until macOS
  clears it.
