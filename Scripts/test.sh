#!/bin/bash
#
# The test suite, as `make test`, the pre-push hook and local CI run it.
#
# While the screen is locked, macOS serves no window's accessibility tree, so
# the tests that read windows can't run here (#675, #626, #647). The runner
# then leaves them out, says so, and this runs them in a throwaway VM
# (Scripts/window-tests-vm.sh), whose screen is never locked. Unlocked, or on
# GitHub's runners, it's the whole suite here, as before.

set -euo pipefail
cd "$(dirname "$0")/.."

marker="$(mktemp "${TMPDIR:-/tmp}/nm-window-tests.XXXXXX")"
trap 'rm -f "$marker"' EXIT
rm -f "$marker"

status=0
NETMON_WINDOWS_SKIPPED="$marker" ./Scripts/swiftpm.sh run NetworkMonitorTests || status=$?

# Left out because the screen is locked, not because someone asked.
if [ -s "$marker" ] && [ -z "${NETMON_WINDOWS:-}" ]; then
  if command -v mac-vm >/dev/null 2>&1 && [ -z "${GITHUB_ACTIONS:-}" ]; then
    ./Scripts/window-tests-vm.sh "$(./Scripts/swiftpm.sh build --show-bin-path 2>/dev/null)/NetworkMonitorTests" \
      || status=1
  else
    echo "note: the tests that read windows weren't run (the screen is locked, and mac-vm isn't here to run them):" \
      "they run once it's unlocked"
  fi
fi
exit "$status"
