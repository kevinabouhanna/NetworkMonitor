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

set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/NetworkMonitor.app"
PATTERN="NetworkMonitor.app/Contents/MacOS"
SETTLE="${1:-5}"

if [ ! -d "$APP" ]; then
  echo "error: $APP not built — run 'make app' first" >&2
  exit 1
fi

cleanup() { pkill -f "$PATTERN" 2>/dev/null || true; }
trap cleanup EXIT

cleanup
sleep 1

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
