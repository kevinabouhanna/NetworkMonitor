#!/bin/bash
#
# The test suite, as `make test`, the pre-push hook and local CI run it.
#
# While the screen is locked, macOS serves no window's accessibility tree, so
# the tests that read windows can't run here (#675, #626, #647). The runner
# then leaves them out and says so, and this runs them in a throwaway VM
# (Scripts/window-tests-vm.sh), whose screen is never locked. Unlocked, or on
# GitHub's runners, it's the whole suite here, as before.
#
# NETMON_WINDOWS=all|skip|only picks the window tests by hand, and then no VM.

set -euo pipefail
cd "$(dirname "$0")/.."

case "${NETMON_WINDOWS:-}" in
  ""|all|skip|only) ;;
  *) echo "error: NETMON_WINDOWS=$NETMON_WINDOWS: it's all, skip or only" >&2; exit 2 ;;
esac

bin="$(./Scripts/swiftpm.sh build --show-bin-path 2>/dev/null)"
mkdir -p "$bin"

# The suite runs from a copy of the runner (#739). A build meanwhile replaces the
# runner's file (a session's quick check, as its turn ends), and macOS then no
# longer knows the running one for the program that made its tests' keys: it
# asked Kevin for a keychain password. The copy keeps its name, which is its
# settings' name too, and finds Sparkle beside itself. Its folder is the same
# each run, so the installed app counts it as one program: the first whose
# runner, or script until that starts, isn't alive.
running="" runner=""
for n in 1 2 3 4; do
  running="$bin/running-$n"
  if ! kill -0 "$(cat "$running.pid" 2>/dev/null || echo 0)" 2>/dev/null ||
     [ "$(cat "$running.pid" 2>/dev/null || echo 0)" = 0 ]; then
    rm -f "$running.pid"
    if (set -o noclobber; echo $$ >"$running.pid") 2>/dev/null; then break; fi
  fi
  running=""
done
[ -n "$running" ] || { echo "error: four runs of the tests are going in $bin" >&2; exit 1; }
marker="$(mktemp "${TMPDIR:-/tmp}/nm-window-tests.XXXXXX")"
trap 'rm -rf "$marker" "$running" "$running.pid"' EXIT
# The runner is waited for in the background, so a signal stops it and this at once.
stop() { if [ -n "$runner" ]; then kill "$runner" 2>/dev/null || true; wait "$runner" 2>/dev/null || true; fi; exit "$1"; }
trap 'stop 129' HUP
trap 'stop 130' INT
trap 'stop 143' TERM
rm -f "$marker"

# Copied as soon as it's built. A build that began meanwhile may have been
# writing it: then the copy's signature is bad, and it's built again.
for try in 1 2 3; do
  ./Scripts/swiftpm.sh build --product NetworkMonitorTests
  rm -rf "$running"
  mkdir -p "$running"
  if cp "$bin/NetworkMonitorTests" "$running/" 2>/dev/null &&
     codesign --verify "$running/NetworkMonitorTests" 2>/dev/null; then break; fi
  [ "$try" -lt 3 ] || { echo "error: no good copy of the test runner: something keeps building it" >&2; exit 1; }
  sleep 2
done
ln -s ../Sparkle.framework "$running/Sparkle.framework"

status=0
NETMON_WINDOWS_SKIPPED="$marker" "$running/NetworkMonitorTests" &
runner=$!
echo "$runner" >"$running.pid"
wait "$runner" || status=$?
runner=""
echo $$ >"$running.pid"

# Left out because the screen is locked, not because someone asked.
if [ -s "$marker" ] && [ -z "${NETMON_WINDOWS:-}" ]; then
  if command -v mac-vm >/dev/null 2>&1 && [ -z "${GITHUB_ACTIONS:-}" ]; then
    vm=0
    ./Scripts/window-tests-vm.sh "$running/NetworkMonitorTests" || vm=$?
    case "$vm" in
      0) ;;
      3) echo "note: the tests that read windows weren't run (the screen is locked, and the VM couldn't run" \
           "them): they run once it's unlocked" ;;
      *) status=1 ;;
    esac
  else
    echo "note: the tests that read windows weren't run (the screen is locked, and mac-vm isn't here to run" \
      "them): they run once it's unlocked"
  fi
fi
exit "$status"
