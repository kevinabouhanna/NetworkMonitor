#!/bin/bash
#
# Installs the privileged helper that hotspot metering needs for tiers D and E:
# macOS system updates, App Store updates, and the applications that download
# updates inside their own process.
#
# This is the only part of NetworkMonitor that needs root, and the only part
# that asks for a password. Everything else — the menu bar readout, per-app
# usage, and metering of Sparkle apps and updater LaunchAgents — works without
# it.
#
# What gets installed:
#
#   /Library/PrivilegedHelperTools/com.kevinabouhanna.NetworkMonitor.helper
#       root:wheel 755. Four verbs, no arguments, no shell. The hostnames it
#       blocks and the preference keys it writes are compiled into it and
#       cannot be supplied by a caller.
#
#   /etc/sudoers.d/networkmonitor
#       NOPASSWD for exactly three invocations of that binary, for the
#       installing user only. Validated with `visudo -c` before installation.
#
#   /Library/LaunchDaemons/com.kevinabouhanna.NetworkMonitor.helper.plist
#       Runs `self-heal` at boot and hourly. If the app has been dragged to the
#       Trash, the helper undoes everything and removes itself.
#
#       Skipped by --no-daemon, and that is the only part of this script with a
#       visible cost: a LaunchDaemon is a background item, so it earns its own
#       row in System Settings > General > Login Items & Extensions, separate
#       from NetworkMonitor's. Grouping it under the app's row would need
#       AssociatedBundleIdentifiers, which macOS only honours for a Developer ID
#       team — an ad-hoc signature has none (see LoginItem.swift). The helper
#       binary and the sudoers rule are invoked on demand and appear there
#       nowhere, so --no-daemon buys back the single row at the cost of the
#       self-heal safety net.
#
# Usage:
#   ./Scripts/install-helper.sh              # install, with hourly self-heal
#   ./Scripts/install-helper.sh --no-daemon  # install without the self-heal daemon
#   ./Scripts/install-helper.sh --uninstall  # restore everything and remove

set -euo pipefail
cd "$(dirname "$0")/.."

HELPER_NAME="com.kevinabouhanna.NetworkMonitor.helper"
HELPER_DEST="/Library/PrivilegedHelperTools/${HELPER_NAME}"
SUDOERS_DEST="/etc/sudoers.d/networkmonitor"
DAEMON_LABEL="com.kevinabouhanna.NetworkMonitor.helper"
DAEMON_DEST="/Library/LaunchDaemons/${DAEMON_LABEL}.plist"
STATE_DIR="/Library/Application Support/NetworkMonitor"
REAL_USER="${SUDO_USER:-$(id -un)}"

INSTALL_DAEMON=1
UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --no-daemon) INSTALL_DAEMON=0 ;;
    --uninstall) UNINSTALL=1 ;;
    *) echo "unknown option: $arg" >&2
       echo "usage: $0 [--no-daemon] [--uninstall]" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- uninstall

STATE_FILE="${STATE_DIR}/system-suppression.json"

if [ "$UNINSTALL" -eq 1 ]; then
  echo "==> Restoring anything the helper switched off, then removing it"
  # The helper undoes its own work first; that ordering is the whole point.
  #
  # `|| true` used to be here, and it was wrong in the one case that matters. If
  # `uninstall` fails, macOS updates and the managed policies are still switched
  # off — and the next two lines would then delete both the state file recording
  # how to undo them and the binary able to do it. Refusing to continue keeps the
  # only two things that can still fix it.
  if [ -x "$HELPER_DEST" ]; then
    if ! sudo "$HELPER_DEST" uninstall; then
      echo >&2
      echo "refusing to delete the helper: its own 'uninstall' failed." >&2
      echo "Updates are still suppressed, and ${STATE_FILE}" >&2
      echo "is the only record of how to put them back. Do not delete it." >&2
      echo "Fix the cause above and re-run this command." >&2
      exit 1
    fi
  fi
  # Belt and braces for what a successful `uninstall` already removed, and for a
  # half-installed state where the binary was gone before we started.
  sudo launchctl bootout "system/${DAEMON_LABEL}" 2>/dev/null || true
  sudo rm -f "$DAEMON_DEST" "$SUDOERS_DEST" "$HELPER_DEST"
  # Only after a verified restore is this file redundant.
  sudo rm -f "$STATE_FILE"
  sudo rmdir "$STATE_DIR" 2>/dev/null || true
  echo "==> Helper removed."
  exit 0
fi

# Removing a freshly-installed helper is only safe once anything already
# suppressed has been put back. `sudo cp` below overwrites the binary in place,
# so by the time a later check fails the previous version is already gone — and
# the state file it wrote is root-side and outlives it. Deleting the binary
# without restoring first is what strands a live suppression with nothing left
# able to undo it.
rollback_helper() {
  if [ -f "$STATE_FILE" ] && [ -x "$HELPER_DEST" ]; then
    echo "    a suppression is recorded — restoring before removing the helper" >&2
    if ! sudo "$HELPER_DEST" restore; then
      echo "    restore FAILED — leaving the helper installed so it can be retried" >&2
      echo "    (run: sudo $HELPER_DEST restore)" >&2
      return 1
    fi
  fi
  sudo rm -f "$HELPER_DEST"
}

# ------------------------------------------------------------------ install

echo "==> Building the helper (release)"
swift build -c release --product NetworkMonitorHelper >/dev/null
BUILT=".build/release/NetworkMonitorHelper"
[ -x "$BUILT" ] || { echo "helper did not build" >&2; exit 1; }

echo
echo "    This installs a root helper so NetworkMonitor can stop macOS"
echo "    downloading system updates over your hotspot. It can do three"
echo "    things and nothing else: suppress, restore, report status."
echo "    Remove it any time with: ./Scripts/install-helper.sh --uninstall"
echo

echo "==> Installing ${HELPER_DEST}"
sudo mkdir -p /Library/PrivilegedHelperTools
sudo cp "$BUILT" "$HELPER_DEST"
# Ownership is the security boundary, not a formality. A NOPASSWD sudoers rule
# pointing at a binary the invoking user can rewrite is a one-line root
# escalation, so this must be root-owned and not group- or world-writable.
sudo chown root:wheel "$HELPER_DEST"
sudo chmod 755 "$HELPER_DEST"

PERMS=$(stat -f "%Sp %Su:%Sg" "$HELPER_DEST")
case "$PERMS" in
  "-rwxr-xr-x root:wheel") ;;
  *) echo "refusing to continue: helper is ${PERMS}, expected -rwxr-xr-x root:wheel" >&2
     rollback_helper || true; exit 1 ;;
esac
echo "    ${PERMS} — verified"

echo "==> Installing the sudoers rule for ${REAL_USER}"
# Written to a temporary file and validated before it is allowed anywhere near
# /etc/sudoers.d. A malformed file there can break sudo for the whole machine,
# so `visudo -c` is not optional.
TMP_SUDOERS=$(mktemp)
cat > "$TMP_SUDOERS" <<EOF
# Installed by NetworkMonitor for hotspot metering.
# Grants exactly three invocations of one root-owned binary, no arguments.
# Remove with: ./Scripts/install-helper.sh --uninstall
${REAL_USER} ALL=(root) NOPASSWD: ${HELPER_DEST} status
${REAL_USER} ALL=(root) NOPASSWD: ${HELPER_DEST} suppress
${REAL_USER} ALL=(root) NOPASSWD: ${HELPER_DEST} restore
EOF

if ! sudo visudo -c -f "$TMP_SUDOERS" >/dev/null 2>&1; then
  echo "refusing to install: the generated sudoers rule did not validate" >&2
  sudo visudo -c -f "$TMP_SUDOERS" || true
  rm -f "$TMP_SUDOERS"
  rollback_helper || true
  exit 1
fi

sudo install -m 440 -o root -g wheel "$TMP_SUDOERS" "$SUDOERS_DEST"
rm -f "$TMP_SUDOERS"
echo "    validated with visudo -c and installed 440 root:wheel"

if [ "$INSTALL_DAEMON" -eq 1 ]; then
  echo "==> Installing the self-heal daemon"
  TMP_PLIST=$(mktemp)
  cat > "$TMP_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${DAEMON_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${HELPER_DEST}</string>
        <string>self-heal</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>StartInterval</key><integer>3600</integer>
</dict>
</plist>
EOF
  sudo install -m 644 -o root -g wheel "$TMP_PLIST" "$DAEMON_DEST"
  rm -f "$TMP_PLIST"
  sudo launchctl bootout "system/${DAEMON_LABEL}" 2>/dev/null || true
  sudo launchctl bootstrap system "$DAEMON_DEST"
else
  echo "==> Skipping the self-heal daemon (--no-daemon)"
  # A daemon from an earlier install has to go, or --no-daemon would report a
  # clean Login Items list while the previous run's row is still sitting there —
  # the exact thing the flag exists to prevent.
  if [ -e "$DAEMON_DEST" ]; then
    echo "    removing the one left by a previous install"
    sudo launchctl bootout "system/${DAEMON_LABEL}" 2>/dev/null || true
    sudo rm -f "$DAEMON_DEST"
  fi
  echo "    nothing of this helper will appear in Login Items."
  echo "    Self-heal is off: if you delete NetworkMonitor.app by dragging it to"
  echo "    the Trash, the managed preferences and the sudoers rule stay behind."
  echo "    Remove it with 'make uninstall' or ./Scripts/install-helper.sh --uninstall."
fi

echo
echo "==> Verifying"
if sudo -n "$HELPER_DEST" status >/dev/null 2>&1; then
  echo "    the app can invoke the helper without a password — good"
else
  echo "    WARNING: sudo -n could not invoke the helper." >&2
  echo "    Metering will fall back to the unprivileged tiers only." >&2
  exit 1
fi

# Report the background-item count from the filesystem rather than from the flag,
# so this states what is actually installed and not merely what was asked for.
if [ -e "$DAEMON_DEST" ]; then
  echo "    self-heal daemon present — expect a second Login Items row"
else
  echo "    no daemon installed — NetworkMonitor stays the only Login Items row"
fi

echo
echo "==> Done. Turn on 'Stop apps updating on hotspots' in NetworkMonitor settings."
