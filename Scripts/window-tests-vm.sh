#!/bin/bash
#
# Runs the tests that read windows in a throwaway macOS VM (`mac-vm`, the
# shared-mac plugin), for when they can't run here (#675): macOS serves no
# window's accessibility tree while the screen is locked, so on a locked Mac
# every VoiceOver and keyboard check fails, whatever the code.
#
# The VM has a screen of its own, never locked, and shows nothing on Kevin's.
# It runs the test runner already built here, with NETMON_WINDOWS=only: just
# the window suites. What they read from the checkout (the app's code, for the
# SF Symbols it names, and every language's table) goes in with it
# (NETMON_REPO_ROOT).
#
# Usage:  ./Scripts/window-tests-vm.sh [test runner]   (default .build/debug/NetworkMonitorTests)
# Exits 0 when they pass, 1 when they fail, 3 when the VM couldn't run them.

set -euo pipefail
cd "$(dirname "$0")/.."

RUNNER="${1:-.build/debug/NetworkMonitorTests}"
if [ ! -x "$RUNNER" ]; then
  echo "error: $RUNNER isn't built: run 'make test' or './Scripts/swiftpm.sh build --product NetworkMonitorTests'" >&2
  exit 3
fi
if ! command -v mac-vm >/dev/null 2>&1; then
  echo "error: mac-vm isn't on PATH (the shared-mac plugin)" >&2
  exit 3
fi

share="$(mktemp -d "${TMPDIR:-/tmp}/nm-window-tests.XXXXXX")"
trap 'rm -rf "$share"' EXIT
mkdir -p "$share/runner/repo/Sources" "$share/runner/repo/Resources"
cp "$RUNNER" "$share/runner/NetworkMonitorTests"
# It finds Sparkle beside itself (@loader_path).
ditto "$(dirname "$RUNNER")/Sparkle.framework" "$share/runner/Sparkle.framework"
ditto Sources/NetworkMonitorCore "$share/runner/repo/Sources/NetworkMonitorCore"
ditto Resources/Localization "$share/runner/repo/Resources/Localization"
# Zipped: through the shared folder, a framework's symlinks come out as loops.
ditto -c -k --keepParent "$share/runner" "$share/runner.zip"
rm -rf "$share/runner"
inside="/Volumes/My Shared Files/$(basename "$share")"

echo "==> Running the window tests in a throwaway VM (mac-vm)"
# The VM boots in under a minute and the tests take two or three (20 min at most).
# The runner's own status goes in a file, to tell its failures from the VM's.
# A screen of 1600×1000 points: on the clone's usual 960×720, the main window
# shrinks to 960 points, search drops out of its toolbar, and the keyboard
# suite's ⌘F has nothing to open (#678).
MAC_VM_TIMEOUT="${MAC_VM_TIMEOUT:-1200}" mac-vm run --display 3200x2000 --share "$share" -- bash -c "
  d=\$(mktemp -d /tmp/nm-window-tests.XXXXXX)
  ditto -x -k '$inside/runner.zip' \"\$d\" || exit 1
  cd \"\$d/runner\"
  NETMON_WINDOWS=only NETMON_REPO_ROOT=\"\$d/runner/repo\" ./NetworkMonitorTests
  echo \$? > '$inside/status'" || true

if [ ! -s "$share/status" ]; then
  echo "note: the VM couldn't run the window tests (mac-vm's output above says why)" >&2
  exit 3
fi
[ "$(cat "$share/status")" = 0 ]
