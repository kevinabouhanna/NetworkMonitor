#!/bin/bash
#
# Assembles NetworkMonitor.app from the SwiftPM build product.
#
# A hand-assembled bundle rather than an Xcode project: only Command Line Tools
# are installed, and LSUIElement only takes effect from a real Contents/Info.plist,
# so the binary must live inside a bundle even for local use.
#
# Usage:
#   ./Scripts/bundle.sh                 # native arch, ad-hoc signed
#   ./Scripts/bundle.sh --universal     # arm64 + x86_64 (for distribution)
#
# To sign with a Developer ID later, set:
#   export SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
# The bundle layout and hardened-runtime flag are already notarization-ready.

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="NetworkMonitor"
BUILD_DIR=".build/release"
APP="build/${APP_NAME}.app"
PLIST_SRC="Resources/Info.plist"
UNIVERSAL=0

for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# Version numbers are stamped in at build time rather than committed, so a
# release is cut by tagging and nothing has to be edited by hand.
#
#   CFBundleShortVersionString — what a human reads. The latest git tag.
#   CFBundleVersion            — what software compares. The commit count,
#                                because it only ever increases. An updater
#                                decides "is there something newer" from this
#                                number, so a repeated value means no update is
#                                ever offered.
#
# Both are overridable so a release workflow can pin them to the tag it is
# building, and both fall back to the committed plist outside a git checkout.
plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST_SRC"; }
in_git_repo() { git rev-parse --git-dir >/dev/null 2>&1; }

if [ -z "${MARKETING_VERSION:-}" ]; then
  if in_git_repo && tag=$(git describe --tags --abbrev=0 2>/dev/null); then
    MARKETING_VERSION="${tag#v}"
  else
    MARKETING_VERSION="$(plist_value CFBundleShortVersionString)"
  fi
fi

if [ -z "${BUILD_NUMBER:-}" ]; then
  if in_git_repo; then
    BUILD_NUMBER="$(git rev-list --count HEAD)"
  else
    BUILD_NUMBER="$(plist_value CFBundleVersion)"
  fi
fi

echo "==> Version ${MARKETING_VERSION} (build ${BUILD_NUMBER})"

echo "==> Building (release)"
if [ "$UNIVERSAL" -eq 1 ]; then
  swift build -c release --arch arm64 --arch x86_64
  BUILD_DIR=".build/apple/Products/Release"
else
  swift build -c release
fi

BINARY="${BUILD_DIR}/${APP_NAME}"
if [ ! -f "$BINARY" ]; then
  echo "error: expected binary at ${BINARY}" >&2
  exit 1
fi

echo "==> Assembling ${APP}"
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "$BINARY" "${APP}/Contents/MacOS/${APP_NAME}"
cp "$PLIST_SRC" "${APP}/Contents/Info.plist"
# Stamped before signing: editing the plist afterwards would invalidate the
# signature and Gatekeeper would reject the bundle.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${MARKETING_VERSION}" \
                        "${APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" \
                        "${APP}/Contents/Info.plist"
# Committed, not generated at build time — regenerate with Scripts/make-icon.swift.
cp Resources/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "${APP}/Contents/PkgInfo"

echo "==> Signing"
if [ -n "${SIGN_IDENTITY:-}" ]; then
  # --options runtime enables the hardened runtime, required for notarization.
  # Spawning /usr/bin/nettop is allowed under the hardened runtime without an
  # exception; it is a separate signed process, not injected code.
  codesign --force --deep --options runtime --timestamp \
           --sign "$SIGN_IDENTITY" "$APP"
  echo "    signed with Developer ID — ready for: xcrun notarytool submit"
else
  # Ad-hoc signature. Enough to run locally; Gatekeeper will ask for a
  # right-click > Open the first time.
  codesign --force --deep --sign - "$APP"
  echo "    ad-hoc signed (local use). Set SIGN_IDENTITY for distribution."
fi

codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo
echo "==> Done: ${APP} — ${MARKETING_VERSION} (build ${BUILD_NUMBER})"
echo "    Run:      open ${APP}"
echo "    Install:  cp -R ${APP} /Applications/"
