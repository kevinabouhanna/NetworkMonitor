#!/bin/bash
#
# Removes NetworkMonitor: the launch agent, the app bundle, and optionally the
# stored usage history.
#
# Usage:
#   ./Scripts/uninstall.sh            # remove app + login item, keep history
#   ./Scripts/uninstall.sh --purge    # also delete usage history and settings

set -euo pipefail

APP_NAME="NetworkMonitor"
BUNDLE_ID="com.kevinabouhanna.NetworkMonitor"
DEST="/Applications/${APP_NAME}.app"
AGENT="${HOME}/Library/LaunchAgents/${BUNDLE_ID}.plist"
STATE="${HOME}/Library/Application Support/${APP_NAME}"
PURGE=0

for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

echo "==> Removing the login item"
# Only the app can withdraw its own SMAppService registration, and it must do
# so while the bundle still exists — hence before the delete below.
if [ -x "${DEST}/Contents/MacOS/${APP_NAME}" ]; then
  "${DEST}/Contents/MacOS/${APP_NAME}" --unregister-login-item 2>/dev/null || true
fi
# Older installs registered a LaunchAgent instead.
launchctl bootout "gui/$(id -u)/${BUNDLE_ID}" 2>/dev/null || true
rm -f "$AGENT"

echo "==> Quitting the app"
# SIGTERM is trapped by the app, so this shuts down cleanly and takes the
# nettop child process with it.
pkill -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
sleep 1
pkill -f "nettop -P -x -d -L 0" 2>/dev/null || true

echo "==> Removing ${DEST}"
if [ -e "$DEST" ]; then
  if [ -w /Applications ]; then rm -rf "$DEST"; else sudo rm -rf "$DEST"; fi
fi

if [ "$PURGE" -eq 1 ]; then
  echo "==> Purging usage history and settings"
  rm -rf "$STATE"
  defaults delete "$BUNDLE_ID" 2>/dev/null || true
else
  echo "==> Keeping usage history at:"
  echo "    ${STATE}"
  echo "    (use --purge to delete it)"
fi

echo
echo "==> Uninstalled."
