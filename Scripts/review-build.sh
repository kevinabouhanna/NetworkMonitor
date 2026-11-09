#!/bin/bash
#
# Runs this branch's build in the menu bar in place of the installed app, for
# a review before anything is released (#436). It quits the installed copy,
# opens build/NetworkMonitor.app with your own settings and history, waits
# until you quit it, then opens the installed copy again.
#
# A development build is signed ad hoc, so it has no content filter, helper
# daemon or updates: ad blocking and blocking show as not in this build. The
# installed copy's filter keeps running meanwhile, so nothing stops being
# blocked. Nothing is installed or replaced.
#
#   make review          builds it first
#   Scripts/review-build.sh

set -euo pipefail
cd "$(dirname "$0")/.."
. Scripts/mac-lane.sh
MAC_LANE=networkmonitor MAC_LANE_WHAT="review-build.sh (until the review build is quit)" mac_lane_enter

installed="/Applications/NetworkMonitor.app"
build="build/NetworkMonitor.app"
[ -d "$build" ] || { echo "no $build: run make app first" >&2; exit 1; }

# Two copies would both write the same history and settings.
if pgrep -xq NetworkMonitor; then
  osascript -e 'tell application id "com.kevinabouhanna.NetworkMonitor" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do pgrep -xq NetworkMonitor || break; sleep 0.2; done
  sleep 2
fi
if pgrep -xq NetworkMonitor; then
  echo "the installed NetworkMonitor didn't quit; quit it and run this again" >&2
  exit 1
fi

echo "review build running: quit it from its menu (right-click the menu bar item › Quit) when done"
open -W -n -g "$build"

# Back to the installed app, as it was.
if [ -d "$installed" ]; then
  sleep 2
  open -g "$installed"
  echo "the installed NetworkMonitor is back"
fi
