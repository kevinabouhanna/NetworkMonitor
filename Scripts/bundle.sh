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
# Signed with the Developer ID when it's available (#119), with the hardened
# runtime and a timestamp, ready for Scripts/notarize.sh. Otherwise with
# NetworkMonitor's own certificate (#86), or ad-hoc. Scripts/signing.sh says
# where each comes from.

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="NetworkMonitor"
HELPER_PRODUCT="NetworkMonitorHelper"
HELPER_NAME="com.kevinabouhanna.NetworkMonitor.helper"
FILTER_PRODUCT="NetworkMonitorFilter"
FILTER_NAME="com.kevinabouhanna.NetworkMonitor.Filter"
BUILD_DIR=".build/release"
APP="build/${APP_NAME}.app"
PLIST_SRC="Resources/Info.plist"
UNIVERSAL=0
ENTITLEMENTS="Resources/NetworkMonitor.entitlements"

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
  # Only version tags: the data refresh's `geodata` release (#121) has a tag
  # too, and the nearest tag of any kind made a build call itself "geodata".
  if in_git_repo && tag=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null); then
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
  for product in "$APP_NAME" "$HELPER_PRODUCT" "$FILTER_PRODUCT"; do
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
  ./Scripts/swiftpm.sh build -c release --product "$FILTER_PRODUCT"
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
# Country and network-owner data for Connections, with DB-IP's licence notice,
# which CC BY 4.0 asks to travel with the data. Committed too: see
# Scripts/geodata.sh for why it can't be downloaded at build time.
cp -R Resources/Geo "${APP}/Contents/Resources/Geo"
# The ad, tracker and malware lists (#176), until a newer week is downloaded.
cp -R Resources/Blocklists "${APP}/Contents/Resources/Blocklists"
printf 'APPL????' > "${APP}/Contents/PkgInfo"

# Sparkle (#132), which the app links, so every build carries it. Its two XPC
# services are only for sandboxed apps, which this isn't, so they're left out,
# leaving less to sign. Universal as downloaded, from the exact release in
# Package.swift.
# The universal build resolves into each architecture's scratch path, the
# others into .build itself.
SPARKLE_FRAMEWORK=""
for scratch in .build .build/arm64 .build/x86_64; do
  candidate="${scratch}/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
  if [ -d "$candidate" ]; then SPARKLE_FRAMEWORK="$candidate"; break; fi
done
[ -n "$SPARKLE_FRAMEWORK" ] || { echo "error: Sparkle.framework not found; run swift package resolve" >&2; exit 1; }
mkdir -p "${APP}/Contents/Frameworks"
ditto "$SPARKLE_FRAMEWORK" "${APP}/Contents/Frameworks/Sparkle.framework"
rm -rf "${APP}/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
       "${APP}/Contents/Frameworks/Sparkle.framework/XPCServices"
SPARKLE="${APP}/Contents/Frameworks/Sparkle.framework"

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
source Scripts/signing.sh

# Sparkle's pieces, inside out, with whatever this build is signed with:
# re-signed even when they came signed, since notarization wants every piece
# under the Developer ID, with the hardened runtime and a timestamp.
sign_sparkle() {
  for piece in "${SPARKLE}/Versions/B/Autoupdate" "${SPARKLE}/Versions/B/Updater.app" "$SPARKLE"; do
    "$@" "$piece"
  done
}
case "$SIGN_KIND" in
  developer-id)
    # The content filter (#128) goes in only with its profiles: the
    # entitlements that let it filter, and let the app install it, are
    # granted by them, and a build signed without them wouldn't launch.
    APP_PROFILE="Resources/Profiles/NetworkMonitor.provisionprofile"
    FILTER_PROFILE="Resources/Profiles/NetworkMonitorFilter.provisionprofile"
    if [ -f "$APP_PROFILE" ] && [ -f "$FILTER_PROFILE" ] && [ -f "${BUILD_DIR}/${FILTER_PRODUCT}" ]; then
      FILTER_BUNDLE="${APP}/Contents/Library/SystemExtensions/${FILTER_NAME}.systemextension"
      mkdir -p "${FILTER_BUNDLE}/Contents/MacOS"
      cp "${BUILD_DIR}/${FILTER_PRODUCT}" "${FILTER_BUNDLE}/Contents/MacOS/${FILTER_NAME}"
      cp Resources/Filter/Info.plist "${FILTER_BUNDLE}/Contents/Info.plist"
      # Each build's service name is its own (#142): one name for every
      # version could leave an updated filter with none.
      /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${MARKETING_VERSION}" \
                              -c "Set :CFBundleVersion ${BUILD_NUMBER}" \
                              -c "Set :NetworkExtension:NEMachServiceName GRQKG7M8CL.com.kevinabouhanna.NetworkMonitor.Filter.${BUILD_NUMBER}" \
                              "${FILTER_BUNDLE}/Contents/Info.plist"
      cp "$FILTER_PROFILE" "${FILTER_BUNDLE}/Contents/embedded.provisionprofile"
      # The filter looks up each connection's country and owner to apply the
      # rules (#114), so the data moves into it, and the app links to it
      # there: once in the bundle, not twice. The licence notice is in both.
      mkdir -p "${FILTER_BUNDLE}/Contents/Resources/Geo"
      cp Resources/Geo/README.md "${FILTER_BUNDLE}/Contents/Resources/Geo/README.md"
      # And which month it is: without it the filter wouldn't use the tables
      # until a newer month was downloaded (#209).
      cp Resources/Geo/MONTH "${FILTER_BUNDLE}/Contents/Resources/Geo/MONTH"
      for table in countries.bin owners.bin; do
        mv "${APP}/Contents/Resources/Geo/${table}" "${FILTER_BUNDLE}/Contents/Resources/Geo/${table}"
        ln -s "../../Library/SystemExtensions/${FILTER_NAME}.systemextension/Contents/Resources/Geo/${table}" \
              "${APP}/Contents/Resources/Geo/${table}"
      done
      cp "$APP_PROFILE" "${APP}/Contents/embedded.provisionprofile"
      sign_developer_id --entitlements Resources/Filter/NetworkMonitorFilter.entitlements "$FILTER_BUNDLE"
      ENTITLEMENTS="Resources/NetworkMonitor+Filter.entitlements"
      echo "    with the content filter"
    fi
    # The helper as a launch daemon the app registers itself (#131): its plist
    # goes in only with the Developer ID, since the daemon checks callers by
    # team. Builds without one install the helper with helper-setup.sh.
    mkdir -p "${APP}/Contents/Library/LaunchDaemons"
    cp Resources/LaunchDaemons/com.kevinabouhanna.NetworkMonitor.daemon.plist "${APP}/Contents/Library/LaunchDaemons/"
    # Updating itself (#132): the feed, the newest release's appcast, and the
    # public half of the key each update is signed with. Only here: a build
    # from source isn't replaced by a release. Checks daily, without asking
    # first; Settings › About switches it off.
    /usr/libexec/PlistBuddy \
      -c "Add :SUFeedURL string https://github.com/kevinabouhanna/NetworkMonitor/releases/latest/download/appcast.xml" \
      -c "Add :SUPublicEDKey string Aepvgea9syp9AsDuIzvxAVpldAhbPvAgi1mExn9it5Y=" \
      -c "Add :SUEnableAutomaticChecks bool true" \
      -c "Add :SUScheduledCheckInterval integer 86400" \
      "${APP}/Contents/Info.plist"
    sign_sparkle sign_developer_id
    # The hardened runtime is on for all of them. Spawning /usr/bin/nettop
    # needs no exception: it's a separate signed process, not injected code.
    sign_developer_id --identifier "$HELPER_NAME" "$HELPER_PATH"
    sign_developer_id --entitlements "$ENTITLEMENTS" "$APP"
    echo "    signed with the Developer ID: notarize with Scripts/notarize.sh"
    ;;
  own)
    # Not a Developer ID, so Gatekeeper still asks for Open Anyway, but every
    # build signed with it is the same app to macOS: the designated requirement
    # is the identifier and this certificate, where an ad-hoc one is the build's
    # own hash. That is what lets Location, asked for Wi-Fi names (#85),
    # survive an update.
    sign_sparkle codesign --force ${SIGN_KEYCHAIN_ARGS[@]+"${SIGN_KEYCHAIN_ARGS[@]}"} --sign "$SIGN_IDENTITY"
    codesign --force ${SIGN_KEYCHAIN_ARGS[@]+"${SIGN_KEYCHAIN_ARGS[@]}"} --sign "$SIGN_IDENTITY" \
             --identifier "$HELPER_NAME" "$HELPER_PATH"
    codesign --force ${SIGN_KEYCHAIN_ARGS[@]+"${SIGN_KEYCHAIN_ARGS[@]}"} --sign "$SIGN_IDENTITY" "$APP"
    echo "    signed with NetworkMonitor's own certificate (${SIGN_IDENTITY:0:8}…)"
    ;;
  ad-hoc)
    # Enough to run locally; a downloaded copy needs "Open Anyway" in System
    # Settings › Privacy & Security the first time. Every build is a new app to
    # macOS, so permissions don't carry over.
    sign_sparkle codesign --force --sign -
    codesign --force --sign - --identifier "$HELPER_NAME" "$HELPER_PATH"
    codesign --force --sign - "$APP"
    echo "    ad-hoc signed: no certificate found (see Scripts/signing.sh)."
    ;;
esac

codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo
echo "==> Done: ${APP} — ${MARKETING_VERSION} (build ${BUILD_NUMBER})"
echo "    Run:      open ${APP}"
echo "    Install:  cp -R ${APP} /Applications/"
