#!/bin/bash
#
# Removes NetworkMonitor: the launch agent, the app bundle, and optionally the
# stored usage history.
#
# Usage:
#   ./Scripts/uninstall.sh            # remove app + login item, keep history
#   ./Scripts/uninstall.sh --purge    # also delete usage history and settings

set -euo pipefail
# install.sh does this too. Without it the `build/…` fallback below is resolved
# against wherever the caller happened to be, so running this script by absolute
# path from another directory silently skipped the revert.
cd "$(dirname "$0")/.."

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

# Quit the app *before* reverting, and that ordering is load-bearing.
#
# `--revert-metering` runs in a second process against the same journal. With the
# app still alive, a network change in the meantime — joining a hotspot, or a
# dropout — makes the live instance re-apply and write fresh journal records,
# which the unconditional `rm` of suppression.json further down then deletes.
# The result is suppressions left applied with no record of how to undo them,
# which is the one outcome this script exists to prevent.
echo "==> Quitting the app"
# SIGTERM is trapped by the app, so this shuts down cleanly and takes the
# nettop child process with it.
pkill -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
sleep 1
# The pattern must match what NettopStream actually spawns. It used to read
# `nettop -P -x -d -L 0`, which never matched anything: `-P` was dropped when
# per-connection rows became necessary for the LAN/internet split (§3.7), and
# the real command line starts `nettop -n -x -d -L 0`. For however long that
# went unnoticed, every orphaned nettop survived uninstall — and an orphan
# spins at over a core. Matching on the stable prefix rather than the whole
# line so a future flag change cannot silently break it again.
pkill -f "nettop -n -x -d" 2>/dev/null || true

# Restore before deleting. Hotspot metering changes things this app does not
# own — other applications' update preferences, LaunchAgents — and the only
# record of how to put them back is suppression.json, which is about to be
# removed along with the bundle that can read it. Deleting first would leave the
# Mac modified with no trace of what changed: worse than a leftover file,
# because there would be nothing left to point at.
echo "==> Restoring anything hotspot metering switched off"
if [ -x "${DEST}/Contents/MacOS/${APP_NAME}" ]; then
  "${DEST}/Contents/MacOS/${APP_NAME}" --revert-metering 2>/dev/null || true
elif [ -x "build/${APP_NAME}.app/Contents/MacOS/${APP_NAME}" ]; then
  # Uninstalling from a clone whose app was never copied to /Applications.
  "build/${APP_NAME}.app/Contents/MacOS/${APP_NAME}" --revert-metering 2>/dev/null || true
fi

# The privileged helper, if hotspot metering was ever set up. It restores the
# system settings it changed before removing itself — see install-helper.sh.
# Only reached when it is actually installed, so an ordinary uninstall still
# never asks for a password.
HELPER="/Library/PrivilegedHelperTools/com.kevinabouhanna.NetworkMonitor.helper"
if [ -e "$HELPER" ] || [ -e /etc/sudoers.d/networkmonitor ]; then
  echo "==> Removing the privileged helper (needs your password)"
  if [ -x "$(dirname "$0")/install-helper.sh" ]; then
    "$(dirname "$0")/install-helper.sh" --uninstall
  else
    sudo "$HELPER" uninstall 2>/dev/null || true
    sudo launchctl bootout system/com.kevinabouhanna.NetworkMonitor.helper 2>/dev/null || true
    sudo rm -f "$HELPER" /etc/sudoers.d/networkmonitor \
      /Library/LaunchDaemons/com.kevinabouhanna.NetworkMonitor.helper.plist
  fi
fi

echo "==> Removing the login item"
# Only the app can withdraw its own SMAppService registration, and it must do
# so while the bundle still exists — hence before the delete below.
if [ -x "${DEST}/Contents/MacOS/${APP_NAME}" ]; then
  "${DEST}/Contents/MacOS/${APP_NAME}" --unregister-login-item 2>/dev/null || true
fi
# Older installs registered a LaunchAgent instead.
launchctl bootout "gui/$(id -u)/${BUNDLE_ID}" 2>/dev/null || true
rm -f "$AGENT"

echo "==> Removing ${DEST}"
if [ -e "$DEST" ]; then
  if [ -w /Applications ]; then rm -rf "$DEST"; else sudo rm -rf "$DEST"; fi
fi

# The journal goes unconditionally. It is this app's own bookkeeping, not the
# user's data, and by this point it has been acted on and is empty — keeping it
# would only leave something behind for no reason.
rm -f "${STATE}/suppression.json"

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
