#!/bin/bash
#
# Builds NetworkMonitor, installs it to /Applications, and optionally sets it to
# start at login.
#
# No Apple Developer account is required. The app is signed with the Developer
# ID, NetworkMonitor's own certificate, or ad-hoc, whichever this Mac has (see
# signing.sh), and any of them is enough for macOS to run it locally. The login
# item is registered by the app through SMAppService, which accepts an ad-hoc
# signature (verified: registration reports .enabled and the item is recorded
# as an app, with the bundle's own name and icon).
#
# A Developer ID build carries the content filter, and macOS runs only a
# notarized one: installed without notarization, the filter already running
# stays, and the new one never replaces it. So a Developer ID build is
# notarized first, when this Mac has the notary credentials (notarize.sh).
#
# Usage:
#   ./Scripts/install.sh                # install + enable launch at login
#   ./Scripts/install.sh --no-login     # install only
#   ./Scripts/install.sh --uninstall    # remove everything

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="NetworkMonitor"
BUNDLE_ID="com.kevinabouhanna.NetworkMonitor"
DEST="/Applications/${APP_NAME}.app"
ENABLE_LOGIN=1

for arg in "$@"; do
  case "$arg" in
    --no-login)  ENABLE_LOGIN=0 ;;
    --uninstall) exec "$(dirname "$0")/uninstall.sh" ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

echo "==> Building"
./Scripts/bundle.sh >/dev/null

# Without the signing keys this build is ad-hoc. Put over a Developer ID copy,
# it drops the helper daemon, the content filter and the update feed, and
# macOS sees the app change developer: the daemon stops starting, Hotspot mode
# asks again and falls back to a password and a second Login Items row (#238).
# Install the release's disk image instead, or let Sparkle update it.
team_of() { codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'; }
installed_team=$(team_of "$DEST" 2>/dev/null || true)
built_team=$(team_of "build/${APP_NAME}.app")
if [ -n "$installed_team" ] && [ "$installed_team" != "not set" ] \
   && [ "$built_team" != "$installed_team" ] && [ "${ALLOW_UNSIGNED:-0}" != 1 ]; then
  case "$built_team" in ""|"not set") built_team="no team (ad-hoc)" ;; *) built_team="team ${built_team}" ;; esac
  echo "    The copy in /Applications is signed by team ${installed_team}; this build by" >&2
  echo "    ${built_team}. Installing it would replace the notarized app." >&2
  echo "    The signing keys go in ~/.config/networkmonitor-signing/. Otherwise install the" >&2
  echo "    release's NetworkMonitor.dmg, or run with ALLOW_UNSIGNED=1 to do it anyway." >&2
  exit 1
fi

if [ -d "build/${APP_NAME}.app/Contents/Library/SystemExtensions" ]; then
  echo "==> Notarizing, so macOS will run its content filter"
  if ! ./Scripts/notarize.sh "build/${APP_NAME}.app" | sed 's/^/    /'; then
    echo "    Not notarized: installing anyway. The content filter already running stays" >&2
    echo "    until a notarized build replaces it. Is the login keychain locked?" >&2
  fi
fi

# Building and notarizing happen above, in this worktree, while the installed
# app keeps running. From here on this uses the Mac as a whole, so it waits its
# turn in the Mac lane (#342).
. Scripts/mac-lane.sh
MAC_LANE=networkmonitor MAC_LANE_WHAT="install.sh $*" mac_lane_enter

echo "==> Stopping any running copy"
# Older installs used a LaunchAgent; boot it out first so launchd does not
# restart the app mid-install. The plist is left in place deliberately — the
# app reads it on next launch to carry the user's existing "start at login"
# choice over to SMAppService, then deletes it.
launchctl bootout "gui/$(id -u)/${BUNDLE_ID}" 2>/dev/null || true
pkill -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
sleep 1

echo "==> Installing to ${DEST}"
if [ ! -w /Applications ]; then
  echo "    /Applications is not writable; using sudo"
  sudo rm -rf "$DEST"
  sudo cp -R "build/${APP_NAME}.app" /Applications/
else
  rm -rf "$DEST"
  cp -R "build/${APP_NAME}.app" /Applications/
fi

# A locally built app is never quarantined, but a copy that has been zipped and
# shared will be, and Gatekeeper would then refuse to open it.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# Launch at login is registered by the app itself, through SMAppService: only
# the app can register its own bundle, and registering the bundle (rather than
# writing a LaunchAgent that runs the bare executable) is what makes the Login
# Items row show the app's name and icon.
if [ "$ENABLE_LOGIN" -eq 0 ]; then
  echo "==> Skipping launch at login (--no-login)"
  # The app enables it on first launch unless it has already been configured;
  # setting the flag ahead of time is how the script opts out.
  defaults write "$BUNDLE_ID" hasConfiguredLoginItem -bool true
else
  echo "==> Launch at login will be registered by the app on first launch"
fi

echo "==> Starting ${APP_NAME}"
open -g "$DEST"

echo
echo "==> Done."
echo "    Look for  ↓ 0 B/s  ↑ 0 B/s  in your menu bar."
echo "    Right-click the menu bar item for settings and Quit."
echo
echo "    Uninstall with: ./Scripts/uninstall.sh"
