#!/bin/bash
#
# Packages build/NetworkMonitor.app as a drag-to-Applications disk image:
# build/NetworkMonitor.dmg.
#
# `make dmg` builds the universal app first and then runs this; run it on its
# own only to repackage an app that is already built.
#
# The file name carries no version on purpose. Uploaded to a release under the
# same name every time, it is always reachable at
#   https://github.com/kevinabouhanna/NetworkMonitor/releases/latest/download/NetworkMonitor.dmg
# which is the link the website's Download buttons use.
#
# The layout is written by dmgbuild (Python), installed into a virtualenv under
# .build/ on first use so nothing is added to the system Python.
#
# Signed with the Developer ID when bundle.sh signed the app with it (#119).
# With NOTARIZE=1, as the release workflow sets it, the app is notarized and
# stapled before it's packaged, and the disk image after: either one then
# opens without a warning, even offline.

set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/NetworkMonitor.app"
OUT="build/NetworkMonitor.dmg"
VENV=".build/dmgbuild-venv"
DMGBUILD_VERSION="1.6.7"

if [ ! -d "$APP" ]; then
  echo "error: ${APP} not found — run 'make dmg' (or 'make universal' first)" >&2
  exit 1
fi

if ! "$VENV/bin/dmgbuild" --help >/dev/null 2>&1; then
  echo "==> Installing dmgbuild ${DMGBUILD_VERSION} into ${VENV}"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --disable-pip-version-check "dmgbuild==${DMGBUILD_VERSION}"
fi

source Scripts/signing.sh
if [ "${NOTARIZE:-0}" = 1 ]; then
  [ "$SIGN_KIND" = developer-id ] || { echo "error: NOTARIZE=1 needs the Developer ID" >&2; exit 1; }
  ./Scripts/notarize.sh "$APP"
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP}/Contents/Info.plist")
ARCHS=$(lipo -archs "${APP}/Contents/MacOS/NetworkMonitor")

echo "==> Packaging ${APP} (${VERSION}, ${ARCHS})"
rm -f "$OUT"
"$VENV/bin/dmgbuild" -s Scripts/dmg-settings.py -D app="$APP" "NetworkMonitor" "$OUT" >/dev/null
hdiutil verify -quiet "$OUT"

if [ "$SIGN_KIND" = developer-id ]; then
  codesign --force --timestamp ${SIGN_KEYCHAIN_ARGS[@]+"${SIGN_KEYCHAIN_ARGS[@]}"} \
           --sign "$SIGN_IDENTITY" "$OUT"
  if [ "${NOTARIZE:-0}" = 1 ]; then ./Scripts/notarize.sh "$OUT"; fi
fi

echo "==> Done: ${OUT} — $(du -h "$OUT" | cut -f1 | tr -d ' ')"
