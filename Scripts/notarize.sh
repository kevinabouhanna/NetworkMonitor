#!/bin/bash
#
# Notarizes one Developer ID-signed .app or .dmg with Apple, waits for the
# verdict, and staples the ticket to it, so Gatekeeper accepts it even offline
# (#119).
#
# Credentials: the App Store Connect API key in NOTARY_KEY (a .p8 path),
# NOTARY_KEY_ID and NOTARY_ISSUER, as the release workflow sets them; otherwise
# the keychain profile `networkmonitor`, saved once with
#   xcrun notarytool store-credentials networkmonitor \
#     --key <AuthKey.p8> --key-id <key ID> --issuer <issuer ID>
#
# Usage:
#   ./Scripts/notarize.sh build/NetworkMonitor.app
#   ./Scripts/notarize.sh build/NetworkMonitor.dmg

set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:?usage: $0 <path to .app or .dmg>}"
[ -e "$TARGET" ] || { echo "error: $TARGET not found" >&2; exit 1; }

if [ -n "${NOTARY_KEY:-}" ]; then
  AUTH=(--key "$NOTARY_KEY" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER:?}")
else
  AUTH=(--keychain-profile "${NOTARY_PROFILE:-networkmonitor}")
fi

# Apple takes an app as a zip; a disk image goes as it is.
SUBMIT="$TARGET"
if [ -d "$TARGET" ]; then
  SUBMIT="$(mktemp -d)/$(basename "$TARGET").zip"
  ditto -c -k --keepParent "$TARGET" "$SUBMIT"
fi

echo "==> Notarizing $(basename "$TARGET")"
RESULT="$(xcrun notarytool submit "$SUBMIT" "${AUTH[@]}" --wait --output-format json)"
STATUS="$(plutil -extract status raw -o - - <<<"$RESULT")"
ID="$(plutil -extract id raw -o - - <<<"$RESULT")"
echo "    ${STATUS} (${ID})"
if [ "$STATUS" != "Accepted" ]; then
  # Apple's log names each file and the reason it was refused.
  xcrun notarytool log "$ID" "${AUTH[@]}" >&2 || true
  exit 1
fi

xcrun stapler staple "$TARGET" >/dev/null
xcrun stapler validate "$TARGET" >/dev/null
echo "    stapled"
