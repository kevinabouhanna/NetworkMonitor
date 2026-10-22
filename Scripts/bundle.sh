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
HELPER_PRODUCT="NetworkMonitorHelper"
HELPER_NAME="com.kevinabouhanna.NetworkMonitor.helper"
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
  # One build per architecture, then lipo. `--arch arm64 --arch x86_64` would
  # do it in one step, but only through Xcode's build system, which Command
  # Line Tools do not have. This way works under both.
  #
  # Each architecture gets its own scratch directory. SwiftPM keeps one build
  # description per directory and does not always notice that the triple has
  # changed since the last build, which fails as "No target named
  # 'NetworkMonitor-arm64-apple-macosx13.0-release.exe' in build description".
  BUILD_DIR=".build/universal"
  mkdir -p "$BUILD_DIR"
  # The app and the privileged helper it carries, each made universal: the
  # helper is installed from inside the bundle, on whatever Mac runs it.
  for product in "$APP_NAME" "$HELPER_PRODUCT"; do
    slices=()
    for arch in arm64 x86_64; do
      flags=(-c release --product "$product" --triple "${arch}-apple-macosx13.0"
             --scratch-path ".build/${arch}")
      ./Scripts/swiftpm.sh build "${flags[@]}"
      slices+=("$(./Scripts/swiftpm.sh build "${flags[@]}" --show-bin-path 2>/dev/null)/${product}")
    done
    lipo -create -output "${BUILD_DIR}/${product}" "${slices[@]}"
  done
else
  ./Scripts/swiftpm.sh build -c release --product "$APP_NAME"
  ./Scripts/swiftpm.sh build -c release --product "$HELPER_PRODUCT"
fi

BINARY="${BUILD_DIR}/${APP_NAME}"
HELPER_BINARY="${BUILD_DIR}/${HELPER_PRODUCT}"
for built in "$BINARY" "$HELPER_BINARY"; do
  if [ ! -f "$built" ]; then
    echo "error: expected binary at ${built}" >&2
    exit 1
  fi
done

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

# The privileged helper and the script that installs it, carried inside the app
# so that Settings can install, update and remove them with one administrator
# prompt — no Terminal. Contents/Library/LaunchServices is where macOS expects a
# bundled helper tool to live.
mkdir -p "${APP}/Contents/Library/LaunchServices"
cp "$HELPER_BINARY" "${APP}/Contents/Library/LaunchServices/${HELPER_NAME}"
cp Scripts/helper-setup.sh "${APP}/Contents/Resources/helper-setup.sh"
chmod 755 "${APP}/Contents/Resources/helper-setup.sh"

echo "==> Signing"
# Inside out, without `--deep`: the nested helper first, under its own
# identifier, then the app, whose signature seals it. `--deep` re-signed the
# helper with an identifier guessed from its file name — the name minus what
# looked like an extension, `.helper` — which is the app's own.
HELPER_PATH="${APP}/Contents/Library/LaunchServices/${HELPER_NAME}"
if [ -n "${SIGN_IDENTITY:-}" ]; then
  # --options runtime enables the hardened runtime, required for notarization.
  # Spawning /usr/bin/nettop is allowed under the hardened runtime without an
  # exception; it is a separate signed process, not injected code.
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
           --identifier "$HELPER_NAME" "$HELPER_PATH"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
  echo "    signed with Developer ID — ready for: xcrun notarytool submit"
else
  # Ad-hoc signature. Enough to run locally; a downloaded copy needs "Open
  # Anyway" in System Settings › Privacy & Security the first time.
  codesign --force --sign - --identifier "$HELPER_NAME" "$HELPER_PATH"
  codesign --force --sign - "$APP"
  echo "    ad-hoc signed (local use). Set SIGN_IDENTITY for distribution."
fi

codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo
echo "==> Done: ${APP} — ${MARKETING_VERSION} (build ${BUILD_NUMBER})"
echo "    Run:      open ${APP}"
echo "    Install:  cp -R ${APP} /Applications/"
