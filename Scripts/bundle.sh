#!/bin/bash
#
# Assembles NetworkMonitor.app from the SwiftPM build product.
#
# A hand-assembled bundle rather than an Xcode project: only Command Line Tools
# are installed, and LSUIElement only takes effect from a real Contents/Info.plist,
# so the binary must live inside a bundle even for local use.
#
# Usage:
#   ./Scripts/bundle.sh                 # native arch
#   ./Scripts/bundle.sh --universal     # arm64 + x86_64 (for distribution)
#
# Signed with NetworkMonitor's own certificate when it's available (#86): the
# .p12 in SIGNING_P12, its password in SIGNING_P12_PASSWORD, or by default the
# two files in ~/.config/networkmonitor-signing/. Without it, ad-hoc.
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
SIGNING_DIR="${HOME}/.config/networkmonitor-signing"
SIGNING_P12="${SIGNING_P12:-${SIGNING_DIR}/signing.p12}"
if [ -z "${SIGNING_P12_PASSWORD:-}" ] && [ -f "${SIGNING_DIR}/password" ]; then
  SIGNING_P12_PASSWORD="$(cat "${SIGNING_DIR}/password")"
fi
SIGNING_P12_PASSWORD="${SIGNING_P12_PASSWORD:-}"

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
elif [ -f "$SIGNING_P12" ] && [ -n "$SIGNING_P12_PASSWORD" ]; then
  # NetworkMonitor's own self-signed certificate (#86). Not a Developer ID, so
  # Gatekeeper still asks for Open Anyway, but every build signed with it is
  # the same app to macOS: the designated requirement is the identifier and
  # this certificate, where an ad-hoc one is the build's own hash. That is what
  # lets Location, asked for Wi-Fi names (#85), survive an update.
  #
  # A throwaway keychain, so the key never sits in the login keychain and
  # nothing prompts: its password is made up here, which is what lets the
  # partition list be set without the user's. The certificate isn't trusted,
  # and needn't be: codesign signs with it by hash, and the signature verifies.
  #
  # On the search list while signing. `--keychain` alone was enough on macOS 27
  # but not on the GitHub runner, where codesign answered "no identity found"
  # for an identity `security find-identity` had just listed (#86). The list
  # is put back, and the keychain deleted, however this exits.
  KEYCHAIN="$(mktemp -d)/signing.keychain-db"
  KEYCHAIN_PASSWORD="$(uuidgen)"
  SEARCH_LIST=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line#\"}"; line="${line%\"}"
    [ -n "$line" ] && SEARCH_LIST+=("$line")
  done < <(security list-keychains -d user)
  restore_keychains() {
    security list-keychains -d user -s "${SEARCH_LIST[@]}" 2>/dev/null || true
    security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  }
  trap restore_keychains EXIT
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
  security list-keychains -d user -s "$KEYCHAIN" "${SEARCH_LIST[@]}"
  security set-keychain-settings "$KEYCHAIN"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
  security import "$SIGNING_P12" -k "$KEYCHAIN" -P "$SIGNING_P12_PASSWORD" \
           -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
           -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
  IDENTITY="$(security find-identity -p codesigning "$KEYCHAIN" \
              | awk '/^ *1\)/ { print $2; exit }')"
  codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY" \
           --identifier "$HELPER_NAME" "$HELPER_PATH"
  codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY" "$APP"
  echo "    signed with NetworkMonitor's certificate (${IDENTITY:0:8}…)"
else
  # Ad-hoc signature. Enough to run locally; a downloaded copy needs "Open
  # Anyway" in System Settings › Privacy & Security the first time. Every
  # build is a new app to macOS, so permissions don't carry over.
  codesign --force --sign - --identifier "$HELPER_NAME" "$HELPER_PATH"
  codesign --force --sign - "$APP"
  echo "    ad-hoc signed: no certificate found (see the top of this script)."
fi

codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo
echo "==> Done: ${APP} — ${MARKETING_VERSION} (build ${BUILD_NUMBER})"
echo "    Run:      open ${APP}"
echo "    Install:  cp -R ${APP} /Applications/"
