#!/bin/bash
#
# Runs the tests that read windows in a throwaway macOS VM (`mac-vm`, the
# shared-mac plugin), for when they can't run here (#675): macOS serves no
# window's accessibility tree while the screen is locked, so on a locked Mac
# every VoiceOver and keyboard check fails, whatever the code.
#
# The VM has a screen of its own, never locked, and shows nothing on Kevin's.
# It runs the test runner already built here, with NETMON_WINDOWS=only: just
# the window tests, which need nothing from the repository.
#
# Usage:  ./Scripts/window-tests-vm.sh [test runner]   (default .build/debug/NetworkMonitorTests)

set -euo pipefail
cd "$(dirname "$0")/.."

RUNNER="${1:-.build/debug/NetworkMonitorTests}"
if [ ! -x "$RUNNER" ]; then
  echo "error: $RUNNER isn't built: run 'make test' or './Scripts/swiftpm.sh build --product NetworkMonitorTests'" >&2
  exit 1
fi
if ! command -v mac-vm >/dev/null 2>&1; then
  echo "error: mac-vm isn't on PATH (the shared-mac plugin): the window tests can't run while the screen is locked without it" >&2
  exit 1
fi

share="$(mktemp -d "${TMPDIR:-/tmp}/nm-window-tests.XXXXXX")"
trap 'rm -rf "$share"' EXIT
mkdir "$share/runner"
cp "$RUNNER" "$share/runner/NetworkMonitorTests"
# It finds Sparkle beside itself (@loader_path).
ditto "$(dirname "$RUNNER")/Sparkle.framework" "$share/runner/Sparkle.framework"
# Zipped: through the shared folder, a framework's symlinks come out as loops.
ditto -c -k --keepParent "$share/runner" "$share/runner.zip"
rm -rf "$share/runner"
inside="/Volumes/My Shared Files/$(basename "$share")"

echo "==> Running the window tests in a throwaway VM (mac-vm)"
# The VM boots in under a minute and the tests take two or three (20 min at most).
MAC_VM_TIMEOUT="${MAC_VM_TIMEOUT:-1200}" mac-vm run --share "$share" -- bash -c "
  set -e
  d=\$(mktemp -d /tmp/nm-window-tests.XXXXXX)
  ditto -x -k '$inside/runner.zip' \"\$d\"
  cd \"\$d/runner\"
  NETMON_WINDOWS=only ./NetworkMonitorTests"
