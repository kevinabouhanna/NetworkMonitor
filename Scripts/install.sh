#!/bin/bash
#
# Builds NetworkMonitor, installs it to /Applications, and optionally sets it to
# start at login.
#
# No Apple Developer account, no Developer ID and no notarization are required.
# The app is signed ad-hoc, which is enough for macOS to run it locally, and the
# login item is registered by the app through SMAppService, which accepts an
# ad-hoc signature (verified: registration reports .enabled and the item is
# recorded as an app, with the bundle's own name and icon).
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

echo "==> Stopping any running copy"
# Older installs used a LaunchAgent; boot it out first so launchd does not
# restart the app mid-install. The plist is left in place deliberately — the
# app reads it on next launch to carry the user's existing "start at login"
# choice over to SMAppService, then deletes it.
launchctl bootout "gui/$(id -u)/${BUNDLE_ID}" 2>/dev/null || true
pkill -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
sleep 1

echo "==> Building"
./Scripts/bundle.sh >/dev/null

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
open "$DEST"

echo
echo "==> Done."
echo "    Look for  ↓ 0 B/s  ↑ 0 B/s  in your menu bar."
echo "    Right-click the menu bar item for settings and Quit."
echo
echo "    Uninstall with: ./Scripts/uninstall.sh"
