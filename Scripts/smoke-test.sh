#!/bin/bash
#
# Launches the assembled bundle, checks it is still alive a few seconds later,
# then that it is idle once settled: under a CPU budget (#723).
#
# Deliberately shallow: it cannot see the menu bar, so it proves only that the
# app starts, builds its status item, does not crash and does not keep itself
# busy. Those are the failures the rest of the pipeline is blind to — everything
# else checks that the app compiles and is packaged, not that it runs (#719 kept
# a core busy and passed every other check).
#
# Usage:  ./Scripts/smoke-test.sh [seconds]
#   SMOKE_CPU_SETTLE  seconds to settle before measuring (20)
#   SMOKE_CPU_WINDOW  seconds measured (30)
#   SMOKE_CPU_BUDGET  most % of one core it may use, averaged (15)
#
# Where it runs (#528), SMOKE_WHERE:
#   vm    in a throwaway macOS VM (`mac-vm`, the shared-mac plugin): the default
#         wherever mac-vm is on PATH, outside GitHub Actions. It takes no Mac lane,
#         quits nothing (not the installed copy, not a review build) and shows
#         nothing on Kevin's screens, so it runs while he reviews a build.
#   here  on this machine: GitHub's runners, and inside the VM. Every running copy
#         is quit first, the installed one too, since they share settings, in the
#         `networkmonitor` Mac lane; the installed copy is opened again afterwards
#         if it was running, however the test ends (#508).

set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/NetworkMonitor.app"
SETTLE="${1:-5}"
# The idle check (#723), below.
CPU_SETTLE="${SMOKE_CPU_SETTLE:-20}"   # seconds after the alive check
CPU_WINDOW="${SMOKE_CPU_WINDOW:-30}"   # seconds measured
CPU_BUDGET="${SMOKE_CPU_BUDGET:-15}"   # % of one core, averaged over the window
for value in "$SETTLE" "$CPU_SETTLE" "$CPU_WINDOW" "$CPU_BUDGET"; do
  [[ "$value" =~ ^[0-9]+$ && "$value" -gt 0 ]] || { echo "error: '$value' isn't a whole number of seconds or percent" >&2; exit 2; }
done

if [ ! -d "$APP" ]; then
  echo "error: $APP not built — run 'make app' first" >&2
  exit 1
fi

WHERE="${SMOKE_WHERE:-}"
if [ -z "$WHERE" ]; then
  if [ -z "${GITHUB_ACTIONS:-}" ] && command -v mac-vm >/dev/null 2>&1; then WHERE=vm; else WHERE=here; fi
fi

if [ "$WHERE" = vm ]; then
  # The bundle goes in zipped: through the VM's shared folder, its symlinks
  # (Sparkle.framework's) come out as loops and the signature breaks.
  share="$(mktemp -d "${TMPDIR:-/tmp}/nm-smoke.XXXXXX")"
  trap 'rm -rf "$share"' EXIT
  mkdir "$share/Scripts"
  cp Scripts/smoke-test.sh Scripts/mac-lane.sh Scripts/quit-and-open.sh "$share/Scripts/"
  ditto -c -k --keepParent "$APP" "$share/app.zip"
  inside="/Volumes/My Shared Files/$(basename "$share")"
  echo "==> Running the smoke test in a throwaway VM (mac-vm)"
  # The VM boots in under a minute; the test itself takes about a minute, the
  # idle check's settle and window: 10 min of room, plus those.
  MAC_VM_TIMEOUT="${MAC_VM_TIMEOUT:-$((600 + SETTLE + CPU_SETTLE + CPU_WINDOW))}" \
  mac-vm run --share "$share" -- bash -c "
    set -e
    d=\$(mktemp -d /tmp/nm-smoke.XXXXXX)
    cp -R '$inside/Scripts' \"\$d/\"
    mkdir \"\$d/build\"
    ditto -x -k '$inside/app.zip' \"\$d/build\"
    SMOKE_WHERE=here SMOKE_CPU_SETTLE=$CPU_SETTLE SMOKE_CPU_WINDOW=$CPU_WINDOW \
      SMOKE_CPU_BUDGET=$CPU_BUDGET \"\$d/Scripts/smoke-test.sh\" $SETTLE"
  exit
fi

# Uses the Mac as a whole, so it waits its turn in the Mac lane (#342).
. Scripts/mac-lane.sh
MAC_LANE=networkmonitor MAC_LANE_WHAT="smoke-test.sh $*" mac_lane_enter

. Scripts/quit-and-open.sh

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

# Idle, it must stay idle (#723). 1.32.0-beta.1 redrew its menu bar readout in
# a loop, a core busy for good (#719), and every check passed: a busy app is
# still alive. So, once it has settled, the CPU it uses over a while, against a
# budget far from both: that loop used 100 % of a core; a healthy app, under
# 10 % in a VM. Over budget, a sample of what it was busy doing. The app and
# its children together (its `nettop`): work handed to a child drains the
# battery as well.

# The CPU seconds the app and its children have used; fails once it has gone.
# `ps -o time=` is [[H:]M]M:SS.ss.
cpu_seconds() {
  kill -0 "$1" 2>/dev/null || return 1
  local pids; pids="$(printf '%s\n' "$1" $(pgrep -P "$1" || true) | paste -sd, -)"
  ps -o time= -p "$pids" | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; t += s } END { print t + 0 }'
}

echo "==> Waiting ${CPU_SETTLE}s more, then measuring its CPU, its children's too, for ${CPU_WINDOW}s"
sleep "$CPU_SETTLE"
before="$(cpu_seconds "$PID")" || { echo "✗ The app exited while settling"; exit 1; }
sleep "$CPU_WINDOW"
after="$(cpu_seconds "$PID")" || { echo "✗ The app exited while being measured"; exit 1; }
percent="$(awk -v a="$before" -v b="$after" -v w="$CPU_WINDOW" 'BEGIN { printf "%.1f", (b - a) * 100 / w }')"
used="$(awk -v a="$before" -v b="$after" 'BEGIN { printf "%.2f", b - a }')"

if awk -v p="$percent" -v max="$CPU_BUDGET" 'BEGIN { exit !(p > max) }'; then
  echo
  echo "✗ Idle, the app used ${used}s of CPU in ${CPU_WINDOW}s: ${percent} % of a core, over the ${CPU_BUDGET} % budget."
  echo "  Something keeps it busy (a loop, a timer, a redraw): what it was doing, by its own functions,"
  echo "  in samples over 3 s (each about 1 ms):"
  sample_file="$(mktemp "${TMPDIR:-/tmp}/nm-smoke-sample.XXXXXX")"
  if sample "$PID" 3 -file "$sample_file" >/dev/null 2>&1; then
    # Each function's samples, added up across the call tree; the run loop's
    # own frames, always at the top, left out. A report with nothing to show
    # still ends with its last line, so no `grep` may stop the script here.
    { grep -E '\(in NetworkMonitor\)' "$sample_file" \
        | sed -E 's/^[ +!:|]*//; s/ +\(in NetworkMonitor\).*//' \
        | awk '{ n = $1; $1 = ""; total[$0] += n } END { for (f in total) print total[f] "\t" f }' \
        | grep -v 'NetworkMonitor_main' | sort -rn | head -12 | sed 's/^/    /'; } || true
    echo "  And AppKit's busiest work in it:"
    { grep -oE '[0-9]+ [-+]\[NS[A-Za-z]+ [A-Za-z_:]+\]' "$sample_file" \
        | awk '{ n = $1; $1 = ""; total[$0] += n } END { for (f in total) print total[f] "\t" f }' \
        | grep -v 'NSApplication run' | sort -rn | head -5 | sed 's/^/    /'; } || true
  else
    echo "    (sample couldn't read the app; its children may be the busy ones: \`pgrep -P $PID\`)"
  fi
  rm -f "$sample_file"
  echo "  docs/development.md#the-idle-check says what to do."
  exit 1
fi

echo "✓ Idle, it used ${used}s of CPU in ${CPU_WINDOW}s: ${percent} % of a core (budget ${CPU_BUDGET} %)"
