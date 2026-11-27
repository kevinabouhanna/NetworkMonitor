#!/bin/bash
#
# Installs a published release on this Mac at once, rather than when Sparkle
# next checks (once a day) (#826):
#
#   Scripts/install-release.sh [tag]     the newest release or beta if no tag
#
# The signing keys aren't on this Mac, so `make install` can't make a notarized
# copy, and an ad-hoc one over the notarized app breaks the helper (#238). This
# takes the release's own NetworkMonitor.dmg, checks it's Developer ID
# GRQKG7M8CL and notarized, and in the `networkmonitor` Mac lane quits the
# installed copy, replaces it and opens it again (in the background).
set -euo pipefail

REPO=kevinabouhanna/NetworkMonitor
TEAM=GRQKG7M8CL
APP=/Applications/NetworkMonitor.app
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

tag="${1:-}"
if [ -z "$tag" ]; then
  tag=$(gh -R "$REPO" release list --limit 1 --exclude-drafts --json tagName --jq '.[0].tagName')
fi
[ -n "$tag" ] || { echo "install-release: no release found" >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/install-release.XXXXXX")
mounted=""
cleanup() {
  [ -n "$mounted" ] && hdiutil detach "$work/mnt" -quiet -force 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

echo "==> $tag: downloading NetworkMonitor.dmg"
timeout 600 gh -R "$REPO" release download "$tag" -p NetworkMonitor.dmg -D "$work"
hdiutil attach -nobrowse -readonly -mountpoint "$work/mnt" "$work/NetworkMonitor.dmg" -quiet
mounted=1
new="$work/mnt/NetworkMonitor.app"

team=$(codesign -dv "$new" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[ "$team" = "$TEAM" ] || { echo "install-release: $tag's app is signed by team '$team', not $TEAM: not installed" >&2; exit 1; }
spctl -a -t exec "$new" 2>/dev/null || { echo "install-release: $tag's app isn't accepted by Gatekeeper (notarized): not installed" >&2; exit 1; }
version=$(defaults read "$new/Contents/Info.plist" CFBundleShortVersionString)
installed=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo none)
if [ "$installed" = "$version" ]; then
  echo "==> $version is already installed"
  exit 0
fi

echo "==> installing $version over $installed"
rm -rf "$APP.new"
ditto "$new" "$APP.new"
trap 'rm -rf "$APP.new"; cleanup' EXIT

# From here on this uses the installed app, so it waits its turn (#342).
. "$ROOT/Scripts/mac-lane.sh"
MAC_LANE=networkmonitor MAC_LANE_WHAT="install-release.sh $tag" mac_lane_enter
. "$ROOT/Scripts/quit-and-open.sh"
nm_quit
rm -rf "$APP"
mv "$APP.new" "$APP"
nm_open "$APP"
echo "==> installed $(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString), running"
