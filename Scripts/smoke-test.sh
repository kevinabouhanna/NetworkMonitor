#!/bin/bash
#
# Launches the assembled bundle and checks it is still alive a few seconds later.
#
# Deliberately shallow: it cannot see the menu bar, so it proves only that the
# app starts, builds its status item and does not crash. That is the failure the
# rest of the pipeline is blind to — everything else checks that the app
# compiles and is packaged, not that it runs.
#
# Usage:  ./Scripts/smoke-test.sh [seconds]
#
# Every running copy is quit first, the installed one too, since they share
# settings; the installed copy is opened again afterwards if it was running,
# however the test ends (#508).

set -euo pipefail
cd "$(dirname "$0")/.."

# Uses the Mac as a whole, so it waits its turn in the Mac lane (#342).
. Scripts/mac-lane.sh
MAC_LANE=networkmonitor MAC_LANE_WHAT="smoke-test.sh $*" mac_lane_enter

. Scripts/quit-and-open.sh

APP="build/NetworkMonitor.app"
SETTLE="${1:-5}"

if [ ! -d "$APP" ]; then
  echo "error: $APP not built — run 'make app' first" >&2
  exit 1
fi

WAS_RUNNING=false
if nm_was_running; then WAS_RUNNING=true; fi

# Quit gracefully and wait for launchd to let go of the launch job before the
# installed copy is opened again, or `open` can fail with error 37 (#508).
cleanup() {
  local status=$?
  nm_quit
  if $WAS_RUNNING; then
    echo "==> Opening the installed copy again"
    nm_open "$NM_INSTALLED" || status=1
  fi
  exit "$status"
}
trap cleanup EXIT

nm_quit

echo "==> Launching $APP"
# Run the binary directly rather than via `open`: no LaunchServices round trip,
# and the exit status and stderr come straight back here.
"${APP}/Contents/MacOS/NetworkMonitor" >/tmp/smoke-test.log 2>&1 &
PID=$!

echo "==> Waiting ${SETTLE}s to see whether it stays up"
sleep "$SETTLE"

if ! kill -0 "$PID" 2>/dev/null; then
  echo
  echo "✗ The app exited within ${SETTLE}s. Output:"
  sed 's/^/    /' /tmp/smoke-test.log
  exit 1
fi

echo "✓ Still running after ${SETTLE}s (pid ${PID})"

# Anything on stderr is worth surfacing even when the app survives — a status
# item that failed to build would show up here first.
if [ -s /tmp/smoke-test.log ]; then
  echo "  Output during launch:"
  sed 's/^/    /' /tmp/smoke-test.log
fi
