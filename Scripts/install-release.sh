#!/bin/bash
#
# Installs a published release on this Mac at once, rather than when Sparkle
# next checks (once a day) (#826):
#
#   Scripts/install-release.sh [--force] [tag]
#
# With no tag, the newest release or beta (vX.Y.Z or vX.Y.Z-beta.N). An older
# build than the installed one is refused unless --force.
#
# The signing keys aren't on this Mac, so `make install` can't make a notarized
# copy, and an ad-hoc one over the notarized app breaks the helper (#238). This
# takes the release's own NetworkMonitor.dmg, checks it's Developer ID
# GRQKG7M8CL and notarized, and in the `networkmonitor` Mac lane quits the
# installed copy, swaps the new one in and opens it again (in the background).
# The old copy is moved aside first and put back if the swap fails.
set -euo pipefail

REPO=kevinabouhanna/NetworkMonitor
TEAM=GRQKG7M8CL
APP=/Applications/NetworkMonitor.app
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

force=""
[ "${1:-}" = "--force" ] && { force=1; shift; }
tag="${1:-}"
if [ -z "$tag" ]; then
  tag=$(gh -R "$REPO" release list --limit 20 --exclude-drafts --json tagName \
    --jq '[.[] | select(.tagName | test("^v[0-9]+\\.[0-9]+\\.[0-9]+(-beta\\.[0-9]+)?$"))][0].tagName')
fi
[ -n "$tag" ] || { echo "install-release: no release found" >&2; exit 1; }

plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }

# Everything this run makes has its own name, so two runs never touch each
# other's files; the trap removes whatever is left.
work=$(mktemp -d "${TMPDIR:-/tmp}/install-release.XXXXXX")
staged="/Applications/.NetworkMonitor.install.$$.app"
aside="/Applications/.NetworkMonitor.previous.$$.app"
mounted=""
cleanup() {
  [ -n "$mounted" ] && hdiutil detach "$work/mnt" -quiet -force 2>/dev/null || true
  rm -rf "$work" "$staged"
}
trap cleanup EXIT

[ -w /Applications ] || { echo "install-release: /Applications isn't writable: not installed" >&2; exit 1; }
if [ -e "$APP" ] && [ -n "$(find "$APP" ! -user "$(id -u)" -print -quit)" ]; then
  echo "install-release: $APP has files owned by another user (an old sudo install): not installed" >&2
  exit 1
fi

echo "==> $tag: downloading NetworkMonitor.dmg"
timeout 600 gh -R "$REPO" release download "$tag" -p NetworkMonitor.dmg -D "$work"
hdiutil attach -nobrowse -readonly -mountpoint "$work/mnt" "$work/NetworkMonitor.dmg" -quiet
mounted=1
new="$work/mnt/NetworkMonitor.app"

team=$(codesign -dv "$new" 2>&1 | sed -n 's/^TeamIdentifier=//p' || true)
[ "$team" = "$TEAM" ] || { echo "install-release: $tag's app is signed by team '${team:-none}', not $TEAM: not installed" >&2; exit 1; }
spctl -a -t exec "$new" 2>/dev/null || { echo "install-release: Gatekeeper doesn't accept $tag's app as notarized: not installed" >&2; exit 1; }
version=$(plist "$new" CFBundleShortVersionString)
build=$(plist "$new" CFBundleVersion)

# Same or newer than what's installed, by build number (Sparkle's order).
check_installed() {
  local have
  have=$(plist "$APP" CFBundleVersion || true)
  [ -n "$have" ] || return 0
  if [ "$have" = "$build" ]; then
    echo "==> $version ($build) is already installed"
    exit 0
  fi
  if [ -z "$force" ] && [ "$(printf '%s\n%s\n' "$have" "$build" | sort -V | tail -1)" = "$have" ]; then
    echo "install-release: build $have is installed, newer than $tag's $build: not installed (--force to go back)" >&2
    exit 1
  fi
}
check_installed

echo "==> staging $version ($build)"
ditto "$new" "$staged"

# From here on this uses the installed app, so it waits its turn (#342).
. "$ROOT/Scripts/mac-lane.sh"
MAC_LANE=networkmonitor MAC_LANE_WHAT="install-release.sh $tag" mac_lane_enter
check_installed   # another run may have installed it while this one waited

. "$ROOT/Scripts/quit-and-open.sh"
nm_quit
[ -e "$APP" ] && mv "$APP" "$aside"
if ! mv "$staged" "$APP"; then
  [ -e "$aside" ] && mv "$aside" "$APP"
  echo "install-release: couldn't move $version into place; the previous copy is back" >&2
  nm_open "$APP" || true
  exit 1
fi
rm -rf "$aside"
nm_open "$APP"
echo "==> installed $(plist "$APP" CFBundleShortVersionString), running"
