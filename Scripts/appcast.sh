#!/bin/bash
#
# Writes the appcast Sparkle reads (#132): one item, this release, its disk
# image signed with the key in SPARKLE_ED_KEY. Published as an asset of the
# release, so the app's feed, releases/latest/download/appcast.xml, is always
# the newest release's.
#
# The update window shows What's new from ReleaseNotes/ (#152), carried in the
# appcast so there's nothing to fetch: every recent version's, as HTML that
# Sparkle trims to the versions newer than the one installed (#163). See
# Scripts/release-notes.swift. The release's own notes take this version's
# file alone.
#
# Each language with a folder in ReleaseNotes/ (zh-Hans/) has its copy too
# (#640): one <description> per language, each with its xml:lang, and Sparkle
# shows the one in the app's language (the Mac's, or the one chosen in
# Settings). The English one says en, as Sparkle asks when there are several.
#
# A beta, X.Y.Z-beta.N (#585), shows X.Y.Z's What's new, written before its
# first beta, and its item carries the beta channel: Sparkle offers it only to
# a copy with Get beta versions on, whichever feed it's found in.
#
# Usage: SPARKLE_ED_KEY=… Scripts/appcast.sh <NetworkMonitor.dmg> <NetworkMonitor.app> <version>

set -euo pipefail
cd "$(dirname "$0")/.."

DMG="${1:?usage: $0 <dmg> <app> <version>}"
APP="${2:?usage: $0 <dmg> <app> <version>}"
VERSION="${3:?usage: $0 <dmg> <app> <version>}"

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "${APP}/Contents/Info.plist"; }

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$ ]]; then
  echo "error: ${VERSION} is neither a release (X.Y.Z) nor a beta (X.Y.Z-beta.N)" >&2
  exit 1
fi
# The version whose What's new it shows: a beta's is its release's.
NOTES_VERSION="${VERSION%-beta.*}"
CHANNEL=""
if [ "$NOTES_VERSION" != "$VERSION" ]; then
  CHANNEL="
      <sparkle:channel>beta</sparkle:channel>"
fi

NOTES="ReleaseNotes/${NOTES_VERSION}.md"
if [ ! -s "$NOTES" ]; then
  echo "error: ${NOTES} is missing: write the version's What's new before tagging" >&2
  exit 1
fi
LANGUAGES=""
for folder in ReleaseNotes/*/; do
  [ -d "$folder" ] || continue
  code="$(basename "$folder")"
  if [ ! -s "ReleaseNotes/${code}/${NOTES_VERSION}.md" ]; then
    echo "error: ReleaseNotes/${code}/${NOTES_VERSION}.md is missing: write the What's new in ${code} too (product-kit notes --check ${NOTES_VERSION})" >&2
    exit 1
  fi
  LANGUAGES="${LANGUAGES} ${code}"
done

# The key that signs must be the one the app trusts, or every update is
# refused: checked before anything is published.
expected="$(plist SUPublicEDKey)"
actual="$(swift Scripts/ed25519-sign.swift --public)"
if [ "$expected" != "$actual" ]; then
  echo "error: SPARKLE_ED_KEY's public half is ${actual}, but the app trusts ${expected}" >&2
  exit 1
fi

BUILD="$(plist CFBundleVersion)"
MINIMUM="$(plist LSMinimumSystemVersion)"
# One language's <description>: en, or a folder's name.
description() {
  local html
  if [ "$1" = en ]; then html="$(swift Scripts/release-notes.swift "$NOTES_VERSION" "$BUILD")" || return 1
  else html="$(swift Scripts/release-notes.swift "$NOTES_VERSION" "$BUILD" "$1")" || return 1; fi
  if [[ "$html" == *']]>'* ]]; then
    echo "error: the release notes ($1) can't contain ]]>, which would end the appcast's CDATA" >&2
    return 1
  fi
  printf '      <description xml:lang="%s"><![CDATA[\n%s\n]]></description>\n' "$1" "$html"
}
DESCRIPTIONS="$(description en)" || exit 1
for code in $LANGUAGES; do
  DESCRIPTIONS="${DESCRIPTIONS}"$'\n'"$(description "$code")" || exit 1
done
LENGTH="$(stat -f %z "$DMG")"
SIGNATURE="$(swift Scripts/ed25519-sign.swift "$DMG")"
DATE="$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")"
REPO="https://github.com/kevinabouhanna/NetworkMonitor"

cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>NetworkMonitor</title>
    <link>https://kevinabouhanna.github.io/NetworkMonitor/</link>
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${DATE}</pubDate>${CHANNEL}
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MINIMUM}</sparkle:minimumSystemVersion>
${DESCRIPTIONS}
      <sparkle:fullReleaseNotesLink>${REPO}/releases</sparkle:fullReleaseNotesLink>
      <enclosure url="${REPO}/releases/download/v${VERSION}/NetworkMonitor.dmg"
                 length="${LENGTH}" type="application/octet-stream"
                 sparkle:edSignature="${SIGNATURE}"/>
    </item>
  </channel>
</rss>
XML
