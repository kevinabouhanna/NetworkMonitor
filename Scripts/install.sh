#!/bin/bash
#
# Builds NetworkMonitor, installs it to /Applications, and optionally sets it to
# start at login.
#
# No Apple Developer account, no Developer ID and no notarization are required.
# The app is signed ad-hoc, which is enough for macOS to run it locally, and the
# login item is a plain LaunchAgent that needs no signature at all.
#
# Usage:
#   ./Scripts/install.sh                # install + enable launch at login
#   ./Scripts/install.sh --no-login     # install only
#   ./Scripts/install.sh --uninstall    # remove everything

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="NetworkMonitor"
BUNDLE_ID="com.kevinabouhanna.NetworkMonitor"
DEST="/Applications/${APP_NAME}.app"
AGENT="${HOME}/Library/LaunchAgents/${BUNDLE_ID}.plist"
EXECUTABLE="${DEST}/Contents/MacOS/${APP_NAME}"
ENABLE_LOGIN=1

for arg in "$@"; do
  case "$arg" in
    --no-login)  ENABLE_LOGIN=0 ;;
    --uninstall) exec "$(dirname "$0")/uninstall.sh" ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

echo "==> Stopping any running copy"
# bootout first so launchd does not immediately restart it mid-install.
launchctl bootout "gui/$(id -u)/${BUNDLE_ID}" 2>/dev/null || true
pkill -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
sleep 1

echo "==> Building"
./Scripts/bundle.sh >/dev/null

echo "==> Installing to ${DEST}"
if [ ! -w /Applications ]; then
  echo "    /Applications is not writable; using sudo"
  sudo rm -rf "$DEST"
  sudo cp -R "build/${APP_NAME}.app" /Applications/
else
  rm -rf "$DEST"
  cp -R "build/${APP_NAME}.app" /Applications/
fi

# A locally built app is never quarantined, but a copy that has been zipped and
# shared will be, and Gatekeeper would then refuse to open it.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

if [ "$ENABLE_LOGIN" -eq 1 ]; then
  echo "==> Enabling launch at login"
  mkdir -p "$(dirname "$AGENT")"
  cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${BUNDLE_ID}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${EXECUTABLE}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<!-- GUI sessions only: there is no menu bar to attach to otherwise. -->
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>ProcessType</key>
	<string>Interactive</string>
	<!-- No KeepAlive on purpose: with it, Quit would relaunch immediately. -->
</dict>
</plist>
PLIST
  plutil -lint "$AGENT" >/dev/null
  launchctl bootstrap "gui/$(id -u)" "$AGENT"
  echo "    launch agent loaded: ${AGENT}"
else
  echo "==> Skipping launch at login (--no-login)"
  open "$DEST"
fi

echo
echo "==> Done."
echo "    Look for  ↓ 0 B/s  ↑ 0 B/s  in your menu bar."
echo "    Right-click the menu bar item for settings and Quit."
echo
echo "    Uninstall with: ./Scripts/uninstall.sh"
