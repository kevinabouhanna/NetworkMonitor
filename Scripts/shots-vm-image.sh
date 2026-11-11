#!/bin/bash
#
# Makes the VM image the website's pictures are taken in (#561): claude-image-networkmonitor,
# a clone of mac-vm's golden image with NetworkMonitor installed and what it needs allowed
# once. Run it again after a macOS update of the golden image (with --fresh), or when a new
# version's filter or helper asks to be allowed again.
#
#   Scripts/shots-vm-image.sh [--fresh] [APP]     APP: /Applications/NetworkMonitor.app
#
# It installs the app, opens its welcome window, and waits up to 30 minutes while the
# approvals are given over `mac-vm look` / `mac-vm vnc claude-image-networkmonitor …`
# (the VM's user is lume, password lume):
#   1. Welcome › See which websites your apps visit › Turn On… › Open System Settings:
#      switch on NetworkMonitor, the password, then Allow when macOS asks to filter.
#   2. Welcome › Know your Wi-Fi networks by name › Turn On…: switch on Location Services,
#      the password, then NetworkMonitor's switch.
#   3. Allow when "sshd-keygen-wrapper" asks to control System Events: Scripts/shots-vm-setup.sh
#      switches light and dark through it.
# Then `mac-vm ssh claude-image-networkmonitor touch /tmp/image-done`. It opens the app again
# with this Mac's settings, so it registers its helper, and System Settings' Login Items:
#   4. Background App Activity: switch NetworkMonitor on, the password.
# Then `touch /tmp/image-done` again, and the image is shut down with all of that kept. It also
# gives the VM's user passwordless sudo, which Scripts/shots-vm-setup.sh uses.
set -euo pipefail
fresh=""
[ "${1:-}" = --fresh ] && { fresh=--fresh; shift; }
app="${1:-/Applications/NetworkMonitor.app}"
[ -d "$app" ] || { echo "no app at $app" >&2; exit 1; }
dir="$(mktemp -d "${TMPDIR:-/tmp}/nm-image.XXXXXX")"
trap 'rm -rf "$dir"' EXIT
ditto -c -k --keepParent "$app" "$dir/app.zip"
ditto "$HOME/Library/Preferences/com.kevinabouhanna.NetworkMonitor.plist" "$dir/settings.plist"
cat >"$dir/inside.sh" <<'INSIDE'
#!/bin/bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
wait_done() { # up to 30 minutes for /tmp/image-done, then takes it away
  for _ in $(seq 360); do [ -f /tmp/image-done ] && break; sleep 5; done
  [ -f /tmp/image-done ] || { echo "gave up after 30 minutes" >&2; exit 1; }
  unlink /tmp/image-done
}
echo lume | sudo -S sh -c 'echo "lume ALL=(ALL) NOPASSWD: ALL" >/etc/sudoers.d/lume && chmod 440 /etc/sudoers.d/lume' 2>/dev/null
osascript -e 'quit app id "com.kevinabouhanna.NetworkMonitor"' 2>/dev/null
t=$(mktemp -d); ditto -x -k "$here/app.zip" "$t"
sudo -n rm -rf /Applications/NetworkMonitor.app; mv "$t/NetworkMonitor.app" /Applications/
open -a /Applications/NetworkMonitor.app --args -open welcome
# Asks once to control System Events, for light and dark (step 3).
osascript -e 'tell application "System Events" to tell appearance preferences to get dark mode' >/dev/null 2>&1 &
echo "==> Steps 1-3 in claude-image-networkmonitor, then touch /tmp/image-done"
wait_done
osascript -e 'quit app "System Settings"' -e 'quit app id "com.kevinabouhanna.NetworkMonitor"'
sleep 2
ditto "$here/settings.plist" "$HOME/Library/Preferences/com.kevinabouhanna.NetworkMonitor.plist"
killall cfprefsd
open -g -a /Applications/NetworkMonitor.app
sleep 10
open "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
echo "==> Step 4, then touch /tmp/image-done"
wait_done
systemextensionsctl list | grep NetworkMonitor
osascript -e 'quit app "System Settings"' -e 'quit app id "com.kevinabouhanna.NetworkMonitor"'
sleep 3
INSIDE
mac-vm image networkmonitor $fresh
MAC_VM_TIMEOUT=4000 mac-vm provision --image networkmonitor --display 3200x2000 "$dir/inside.sh"
