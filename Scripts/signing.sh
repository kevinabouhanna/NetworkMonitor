#!/bin/bash
#
# Sourced by bundle.sh and make-dmg.sh: chooses what to sign with, and for a
# .p12, a throwaway keychain to sign from. The first of these that's there:
#
#   1. SIGN_IDENTITY, an identity already in a keychain, such as
#      "Developer ID Application: Kevin Abou Hanna (GRQKG7M8CL)".
#   2. The Developer ID (#119): the .p12 in DEVID_P12, its password in
#      DEVID_P12_PASSWORD, or by default developer-id.p12 and
#      developer-id.password in ~/.config/networkmonitor-signing/. The release
#      workflow passes its copy from the repository secrets.
#   3. NetworkMonitor's own certificate (#86): SIGNING_P12 and
#      SIGNING_P12_PASSWORD, or signing.p12 and password in the same folder.
#      Gatekeeper doesn't know it, but every build signed with it is the same
#      app to macOS, so permissions survive an update.
#   4. Ad-hoc, for anyone building without either.
#
# Sets SIGN_KIND (developer-id, own or ad-hoc), SIGN_IDENTITY, and
# SIGN_KEYCHAIN_ARGS, the --keychain option codesign needs for a .p12.

SIGNING_DIR="${HOME}/.config/networkmonitor-signing"
SIGN_KEYCHAIN_ARGS=()

# A throwaway keychain, so the key never sits in the login keychain and nothing
# prompts: its password is made up here, which is what lets the partition list
# be set without the user's.
#
# On the search list while signing. `--keychain` alone was enough on macOS 27
# but not on the GitHub runner, where codesign answered "no identity found" for
# an identity `security find-identity` had just listed (#86). The list is put
# back, and the keychain deleted, however the script exits.
signing_use_p12() {
  local p12="$1" password="$2"
  SIGNING_KEYCHAIN="$(mktemp -d)/signing.keychain-db"
  local keychain_password
  keychain_password="$(uuidgen)"
  SIGNING_SEARCH_LIST=()
  local line
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line#\"}"; line="${line%\"}"
    [ -n "$line" ] && SIGNING_SEARCH_LIST+=("$line")
  done < <(security list-keychains -d user)
  trap signing_cleanup EXIT
  security create-keychain -p "$keychain_password" "$SIGNING_KEYCHAIN"
  security list-keychains -d user -s "$SIGNING_KEYCHAIN" "${SIGNING_SEARCH_LIST[@]}"
  security set-keychain-settings "$SIGNING_KEYCHAIN"
  security unlock-keychain -p "$keychain_password" "$SIGNING_KEYCHAIN"
  security import "$p12" -k "$SIGNING_KEYCHAIN" -P "$password" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
           -k "$keychain_password" "$SIGNING_KEYCHAIN" >/dev/null
  # By hash: the certificate needn't be trusted for codesign to sign with it.
  SIGN_IDENTITY="$(security find-identity -p codesigning "$SIGNING_KEYCHAIN" \
                   | awk '/^ *1\)/ { print $2; exit }')"
  SIGN_KEYCHAIN_ARGS=(--keychain "$SIGNING_KEYCHAIN")
}

signing_cleanup() {
  [ -n "${SIGNING_KEYCHAIN:-}" ] || return 0
  security list-keychains -d user -s "${SIGNING_SEARCH_LIST[@]}" 2>/dev/null || true
  security delete-keychain "$SIGNING_KEYCHAIN" 2>/dev/null || true
}

DEVID_P12="${DEVID_P12:-${SIGNING_DIR}/developer-id.p12}"
if [ -z "${DEVID_P12_PASSWORD:-}" ] && [ -f "${SIGNING_DIR}/developer-id.password" ]; then
  DEVID_P12_PASSWORD="$(cat "${SIGNING_DIR}/developer-id.password")"
fi
SIGNING_P12="${SIGNING_P12:-${SIGNING_DIR}/signing.p12}"
if [ -z "${SIGNING_P12_PASSWORD:-}" ] && [ -f "${SIGNING_DIR}/password" ]; then
  SIGNING_P12_PASSWORD="$(cat "${SIGNING_DIR}/password")"
fi

if [ -n "${SIGN_IDENTITY:-}" ]; then
  case "$SIGN_IDENTITY" in
    "Developer ID Application"*) SIGN_KIND="developer-id" ;;
    *)                           SIGN_KIND="own" ;;
  esac
elif [ -f "$DEVID_P12" ] && [ -n "${DEVID_P12_PASSWORD:-}" ]; then
  SIGN_KIND="developer-id"
  signing_use_p12 "$DEVID_P12" "$DEVID_P12_PASSWORD"
elif [ -f "$SIGNING_P12" ] && [ -n "${SIGNING_P12_PASSWORD:-}" ]; then
  SIGN_KIND="own"
  signing_use_p12 "$SIGNING_P12" "$SIGNING_P12_PASSWORD"
else
  SIGN_KIND="ad-hoc"
  SIGN_IDENTITY="-"
fi

# Signs with the Developer ID: the hardened runtime, which notarization
# requires, and a secure timestamp from Apple. Offline, the timestamp can't be
# had; the build is then signed without one, which runs fine here but can't be
# notarized, and says so.
sign_developer_id() {
  if ! codesign --force --options runtime --timestamp ${SIGN_KEYCHAIN_ARGS[@]+"${SIGN_KEYCHAIN_ARGS[@]}"} \
                --sign "$SIGN_IDENTITY" "$@" 2>/dev/null; then
    echo "    warning: no timestamp from Apple (offline?): signed without one, so this build can't be notarized" >&2
    codesign --force --options runtime --timestamp=none ${SIGN_KEYCHAIN_ARGS[@]+"${SIGN_KEYCHAIN_ARGS[@]}"} \
             --sign "$SIGN_IDENTITY" "$@"
  fi
}
