#!/bin/bash
#
# The Mac lane: whatever uses this Mac as a whole runs one at a time, across
# every worktree, session and project (#342).
#
# Worktrees keep files apart, but not the one app in /Applications, its content
# filter and helper daemon, its settings, the pointer and the screen, or a
# `pkill` by name that stops every copy of the app. Whatever touches those goes
# through the lane. A second caller waits and is told who holds it and since
# when. The lock is the kernel's (lockf), so it goes when its holder dies and
# never goes stale.
#
# Usage:
#   Scripts/mac-lane.sh <command> [args…]   run a command in the lane
#   Scripts/mac-lane.sh status              "free", or who holds it
#   . Scripts/mac-lane.sh; mac_lane_enter   in a script: hold it from here on,
#                                           until the script exits
#
# Inside the lane MAC_LANE_HELD is set, so nested scripts and make calls run
# straight through rather than waiting on themselves. MAC_LANE_TIMEOUT (seconds)
# gives up with exit status 75 instead of waiting for as long as it takes.
#
# The lock is held on file descriptor 9, which child processes inherit: a
# process started with `&` that outlives the script keeps the lane busy. Start
# anything long-lived with `open`, which hands it to launchd.

MAC_LANE_DIR="${MAC_LANE_DIR:-$HOME/Library/Caches/mac-lane}"

mac_lane_holder() { cat "$MAC_LANE_DIR/holder" 2>/dev/null || echo "unknown"; }

mac_lane_free() {
  mkdir -p "$MAC_LANE_DIR"
  lockf -s -k -t 0 "$MAC_LANE_DIR/lock" true
}

mac_lane_enter() {
  if [ -n "${MAC_LANE_HELD:-}" ]; then return 0; fi
  mkdir -p "$MAC_LANE_DIR"
  exec 9>>"$MAC_LANE_DIR/lock"
  if ! lockf -s -k -t 0 9; then
    echo "==> Mac lane busy: $(mac_lane_holder)" >&2
    echo "    Waiting for it…" >&2
    if ! lockf -s -k ${MAC_LANE_TIMEOUT:+-t "$MAC_LANE_TIMEOUT"} 9; then
      echo "==> Gave up after ${MAC_LANE_TIMEOUT:-?}s. Still busy: $(mac_lane_holder)" >&2
      exit 75
    fi
  fi
  printf '%s, from %s, since %s (pid %s)\n' \
    "${MAC_LANE_WHAT:-$0}" "$PWD" "$(date '+%H:%M:%S')" "$$" > "$MAC_LANE_DIR/holder"
  export MAC_LANE_HELD=1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  case "${1:-}" in
    status)
      if [ -n "${MAC_LANE_HELD:-}" ]; then echo "held by this process tree"
      elif mac_lane_free; then echo "free"
      else echo "busy: $(mac_lane_holder)"; fi
      ;;
    ""|-h|--help)
      sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
      exit 2
      ;;
    *)
      MAC_LANE_WHAT="$*"
      mac_lane_enter
      exec "$@"
      ;;
  esac
fi
