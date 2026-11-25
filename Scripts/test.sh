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

./Scripts/swiftpm.sh build --product NetworkMonitorTests
bin="$(./Scripts/swiftpm.sh build --show-bin-path 2>/dev/null)"

# The suite runs from a copy of the runner (#739). A build meanwhile replaces the
# runner's file (a session's quick check, as its turn ends), and macOS then no
# longer knows the running one for the program that made its tests' keys: it
# asked Kevin for a keychain password. The copy keeps its name, which is its
# settings' name too, and finds Sparkle beside itself.
for old in "$bin"/running-*; do
  # Left by a run that was killed.
  if [ -d "$old" ] && ! kill -0 "${old##*-}" 2>/dev/null; then rm -rf "$old"; fi
done
running="$bin/running-$$"
marker="$(mktemp "${TMPDIR:-/tmp}/nm-window-tests.XXXXXX")"
trap 'rm -rf "$marker" "$running"' EXIT
trap 'exit 130' INT TERM HUP
rm -f "$marker"
mkdir -p "$running"
cp "$bin/NetworkMonitorTests" "$running/"
ln -s ../Sparkle.framework "$running/Sparkle.framework"

status=0
NETMON_WINDOWS_SKIPPED="$marker" "$running/NetworkMonitorTests" || status=$?

# Left out because the screen is locked, not because someone asked.
if [ -s "$marker" ] && [ -z "${NETMON_WINDOWS:-}" ]; then
  if command -v mac-vm >/dev/null 2>&1 && [ -z "${GITHUB_ACTIONS:-}" ]; then
    vm=0
    ./Scripts/window-tests-vm.sh "$bin/NetworkMonitorTests" || vm=$?
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
