#!/bin/bash
#
# Quitting NetworkMonitor and opening it again, for the scripts that do (#508).
# Sourced: `. Scripts/quit-and-open.sh`, inside the `networkmonitor` Mac lane.
#
#   nm_quit            quits every running copy (installed or a build: they share
#                      settings) gracefully, as the Quit menu item does, then waits
#                      until launchd has let go of its launch job
#   nm_open <app> [args…]
#                      opens <app> in the background and waits until it runs
#   nm_was_running     true if the installed copy is running (note it before nm_quit)
#
# Why the wait: opened again while runningboardd is still tearing down the last
# launch's job (`application.com.kevinabouhanna.NetworkMonitor.<n>.<n>` in
# `launchctl list`), `open` fails with OSLaunchdErrorDomain 37, "Operation already
# in progress", and the job can stay behind with no process. If that happens
# anyway, nm_open removes that dead job and tries once more, saying so.
#
#   Scripts/quit-and-open.sh cycle [n]   quits and reopens the installed copy n
#                                        times (5), in the lane: a test of this

NM_BUNDLE_ID="com.kevinabouhanna.NetworkMonitor"
NM_INSTALLED="/Applications/NetworkMonitor.app"

# The app's launch jobs: "<pid or -> <label>", one a line.
nm_jobs() {
  launchctl list 2>/dev/null | awk -v p="application.$NM_BUNDLE_ID." 'index($3, p) == 1 { print $1, $3 }'
}

nm_running() { pgrep -xq NetworkMonitor; }

nm_was_running() { pgrep -qf "^$NM_INSTALLED/Contents/MacOS/NetworkMonitor"; }

nm_quit() {
  local i
  if nm_running; then
    # Every copy, through AppKit's own quit: no SIGTERM, which the app doesn't catch.
    osascript -l JavaScript -e "ObjC.import('AppKit');
      var a = \$.NSRunningApplication.runningApplicationsWithBundleIdentifier('$NM_BUNDLE_ID');
      for (var i = 0; i < a.count; i++) a.objectAtIndex(i).terminate;" >/dev/null 2>&1 || true
    for i in $(seq 1 80); do nm_running || break; sleep 0.25; done
    if nm_running; then
      echo "==> NetworkMonitor didn't quit within 20 s: stopping it" >&2
      pkill -x NetworkMonitor 2>/dev/null || true
      for i in $(seq 1 20); do nm_running || break; sleep 0.25; done
      pkill -9 -x NetworkMonitor 2>/dev/null || true
    fi
  fi
  # A job with a process is one still running or going; one without, once all
  # copies have quit, is the dead job open trips over. Give launchd 15 s for both.
  for i in $(seq 1 60); do [ -z "$(nm_jobs)" ] && break; sleep 0.25; done
  if [ -n "$(nm_jobs)" ]; then
    echo "==> launchd still lists NetworkMonitor's launch job: $(nm_jobs | tr '\n' ' ')" >&2
  fi
}

nm_open() { # <app> [args…]
  local app="$1"; shift
  local out attempt removed="" pid label i
  local cmd=(open -g "$app")
  if [ $# -gt 0 ]; then cmd+=(--args "$@"); fi
  for attempt in 1 2 3; do
    if out="$("${cmd[@]}" 2>&1)"; then
      for i in $(seq 1 40); do nm_running && return 0; sleep 0.25; done
      out="it didn't start within 10 s"
    elif [ -z "$removed" ] && [[ "$out" == *"Code=37"* ]]; then
      removed=1
      while read -r pid label; do
        [ "$pid" = - ] || continue
        if launchctl remove "$label" 2>/dev/null; then
          echo "==> launchd still had $label from the last launch, with no process (#508): removed it" >&2
        else
          echo "==> launchd still has $label, with no process, and won't remove it (#508)" >&2
        fi
      done < <(nm_jobs)
      echo "==> Opening $app again" >&2
      continue
    fi
    [ "$attempt" -lt 3 ] && sleep 2
  done
  echo "==> Couldn't open $app: $out" >&2
  return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  cd "$(dirname "$0")/.."
  case "${1:-}" in
    cycle)
      . Scripts/mac-lane.sh
      MAC_LANE=networkmonitor MAC_LANE_WHAT="quit-and-open.sh cycle" mac_lane_enter
      n="${2:-5}" failed=0
      for k in $(seq 1 "$n"); do
        nm_quit
        if nm_open "$NM_INSTALLED" && nm_was_running; then echo "cycle $k: running again"
        else echo "cycle $k: NOT running"; failed=$((failed + 1)); fi
      done
      echo "$((n - failed)) of $n cycles left it running"
      [ "$failed" -eq 0 ]
      ;;
    *) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 2 ;;
  esac
fi
