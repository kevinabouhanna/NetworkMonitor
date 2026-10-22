#!/bin/bash
#
# Installs or removes NetworkMonitor's privileged helper. Runs as root.
#
# Shipped inside the app, in Contents/Resources, beside the helper binary it
# installs. The app runs it through macOS's own administrator dialog — the one
# password prompt hotspot metering ever shows — so nobody has to open Terminal.
# Scripts/install-helper.sh runs the same file with sudo for anyone building
# from source, so there is one installer, not two that can drift apart.
#
# What gets installed:
#
#   /Library/PrivilegedHelperTools/com.kevinabouhanna.NetworkMonitor.helper
#       root:wheel 755. Seven verbs, no arguments, no shell. The hostnames it
#       blocks, the preference keys it writes and the two interface flags it
#       raises for Low Data Mode are compiled into it and cannot be supplied by
#       a caller.
#
#   /etc/sudoers.d/networkmonitor
#       NOPASSWD for exactly five invocations of that binary, for one user.
#       Validated with `visudo -c` before it is allowed into sudoers.d.
#
#   /Library/LaunchDaemons/com.kevinabouhanna.NetworkMonitor.helper.plist
#       Runs `self-heal` at boot and hourly: if the app has been dragged to the
#       Trash, the helper puts back everything it changed and removes itself.
#       For an app installed from a disk image, dragging it to the Trash is the
#       uninstall most people will use, so a fresh install includes it. It costs
#       one row in Login Items; --no-daemon leaves it out, and an update keeps
#       whichever arrangement is already there.
#
# Usage (as root):
#   helper-setup.sh install <helper-binary> <user> [--daemon | --no-daemon]
#   helper-setup.sh uninstall

set -euo pipefail

HELPER_NAME="com.kevinabouhanna.NetworkMonitor.helper"
HELPER_DEST="/Library/PrivilegedHelperTools/${HELPER_NAME}"
SUDOERS_DEST="/etc/sudoers.d/networkmonitor"
DAEMON_LABEL="${HELPER_NAME}"
DAEMON_DEST="/Library/LaunchDaemons/${DAEMON_LABEL}.plist"
STATE_DIR="/Library/Application Support/NetworkMonitor"
STATE_FILE="${STATE_DIR}/system-suppression.json"
LOW_DATA_FILE="${STATE_DIR}/low-data-mode.json"

fail() { echo "helper-setup: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "must run as root"

# ------------------------------------------------------------------ install

install_helper() {
  local source="$1" user="$2" daemon_mode="${3:-auto}"

  # The user name becomes part of a sudoers rule, so it is checked against the
  # characters a macOS short name can contain and against the accounts that
  # exist, rather than trusted.
  [[ "$user" =~ ^[A-Za-z0-9._-]+$ ]] || fail "not a valid user name: ${user}"
  id -u "$user" >/dev/null 2>&1 || fail "no such user: ${user}"
  [ -f "$source" ] && [ -x "$source" ] || fail "helper binary not found at ${source}"

  local with_daemon
  case "$daemon_mode" in
    --daemon)    with_daemon=1 ;;
    --no-daemon) with_daemon=0 ;;
    auto)
      # An update keeps the arrangement it finds; a first install gets the
      # safety net.
      if [ -x "$HELPER_DEST" ] && [ ! -e "$DAEMON_DEST" ]; then
        with_daemon=0
      else
        with_daemon=1
      fi ;;
    *) fail "unknown option: ${daemon_mode}" ;;
  esac

  # Copied beside the destination and renamed over it, so the binary the sudoers
  # rule points at is never half-written. The new binary reads the old one's
  # state files, so anything held down right now stays recorded.
  mkdir -p /Library/PrivilegedHelperTools
  install -m 755 -o root -g wheel "$source" "${HELPER_DEST}.new"
  mv -f "${HELPER_DEST}.new" "$HELPER_DEST"

  # Ownership is the security boundary, not a formality. A NOPASSWD rule
  # pointing at a binary the user could rewrite is a one-line root escalation.
  local perms
  perms=$(stat -f "%Sp %Su:%Sg" "$HELPER_DEST")
  [ "$perms" = "-rwxr-xr-x root:wheel" ] \
    || fail "helper is ${perms}, expected -rwxr-xr-x root:wheel"

  # Validated before it goes anywhere near /etc/sudoers.d: a malformed file
  # there can break sudo for the whole machine.
  local sudoers
  sudoers=$(mktemp)
  cat > "$sudoers" <<EOF
# Installed by NetworkMonitor for hotspot metering.
# Grants exactly five invocations of one root-owned binary, no arguments.
# Remove with NetworkMonitor's own "Uninstall NetworkMonitor…" menu item.
${user} ALL=(root) NOPASSWD: ${HELPER_DEST} status
${user} ALL=(root) NOPASSWD: ${HELPER_DEST} suppress
${user} ALL=(root) NOPASSWD: ${HELPER_DEST} restore
${user} ALL=(root) NOPASSWD: ${HELPER_DEST} constrain
${user} ALL=(root) NOPASSWD: ${HELPER_DEST} unconstrain
EOF
  if ! visudo -c -f "$sudoers" >/dev/null 2>&1; then
    rm -f "$sudoers"
    fail "the generated sudoers rule did not validate"
  fi
  install -m 440 -o root -g wheel "$sudoers" "$SUDOERS_DEST"
  rm -f "$sudoers"

  if [ "$with_daemon" -eq 1 ]; then
    local plist
    plist=$(mktemp)
    cat > "$plist" <<EOF
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
    install -m 644 -o root -g wheel "$plist" "$DAEMON_DEST"
    rm -f "$plist"
    launchctl bootout "system/${DAEMON_LABEL}" 2>/dev/null || true
    launchctl bootstrap system "$DAEMON_DEST"
  elif [ -e "$DAEMON_DEST" ]; then
    launchctl bootout "system/${DAEMON_LABEL}" 2>/dev/null || true
    rm -f "$DAEMON_DEST"
  fi

  "$HELPER_DEST" status >/dev/null || fail "the installed helper does not run"
  echo "installed"
}

# ---------------------------------------------------------------- uninstall

uninstall_helper() {
  # The helper undoes its own work first — system update settings, managed
  # policies, /etc/hosts, Low Data Mode — and that ordering is the whole point.
  # If it fails, nothing is deleted: its state files and its binary are the
  # only things left that can still put those settings back.
  if [ -x "$HELPER_DEST" ]; then
    "$HELPER_DEST" uninstall || fail "the helper could not restore what it changed; nothing was removed"
  fi
  launchctl bootout "system/${DAEMON_LABEL}" 2>/dev/null || true
  rm -f "$DAEMON_DEST" "$SUDOERS_DEST" "$HELPER_DEST"
  rm -f "$STATE_FILE" "$LOW_DATA_FILE" "${STATE_DIR}/.helper.lock"
  rmdir "$STATE_DIR" 2>/dev/null || true
  echo "uninstalled"
}

case "${1:-}" in
  install)
    [ $# -ge 3 ] || fail "usage: $0 install <helper-binary> <user> [--daemon|--no-daemon]"
    install_helper "$2" "$3" "${4:-auto}" ;;
  uninstall)
    uninstall_helper ;;
  *)
    fail "usage: $0 install <helper-binary> <user> [--daemon|--no-daemon] | uninstall" ;;
esac
