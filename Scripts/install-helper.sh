#!/bin/bash
#
# Installs the privileged helper from a source checkout. For developers only.
#
# Nobody using the app needs this: NetworkMonitor installs its own helper from
# Settings, through macOS's administrator dialog, the first time hotspot
# metering is switched on. This script builds the helper and hands it to the
# same installer the app uses, Scripts/helper-setup.sh, so the two paths cannot
# disagree about what gets installed. See that file for what it puts where.
#
# Usage:
#   ./Scripts/install-helper.sh              # install, with hourly self-heal
#   ./Scripts/install-helper.sh --no-daemon  # install without the self-heal daemon
#   ./Scripts/install-helper.sh --uninstall  # restore everything and remove

set -euo pipefail
cd "$(dirname "$0")/.."

REAL_USER="${SUDO_USER:-$(id -un)}"
DAEMON="--daemon"
UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --no-daemon) DAEMON="--no-daemon" ;;
    --uninstall) UNINSTALL=1 ;;
    *) echo "unknown option: $arg" >&2
       echo "usage: $0 [--no-daemon] [--uninstall]" >&2; exit 2 ;;
  esac
done

if [ "$UNINSTALL" -eq 1 ]; then
  echo "==> Restoring anything the helper switched off, then removing it"
  sudo /bin/bash Scripts/helper-setup.sh uninstall
  exit 0
fi

echo "==> Building the helper (release)"
./Scripts/swiftpm.sh build -c release --product NetworkMonitorHelper >/dev/null
BUILT=".build/release/NetworkMonitorHelper"
[ -x "$BUILT" ] || { echo "helper did not build" >&2; exit 1; }

echo "==> Installing (asks for your password)"
sudo /bin/bash Scripts/helper-setup.sh install "$BUILT" "$REAL_USER" "$DAEMON"

if sudo -n /Library/PrivilegedHelperTools/com.kevinabouhanna.NetworkMonitor.helper status \
     >/dev/null 2>&1; then
  echo "    the app can invoke the helper without a password — good"
else
  echo "    WARNING: sudo -n could not invoke the helper." >&2
  exit 1
fi
